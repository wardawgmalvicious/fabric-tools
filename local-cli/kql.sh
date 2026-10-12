#!/usr/bin/env bash
# Wrapper around the Kusto query REST API for any AAD-authenticated KQL endpoint —
# Fabric Eventhouse / KQL database, Azure Data Explorer, Log Analytics ADX proxy.
# Reads the cluster URI and database from the repo's .env and authenticates with
# the Azure CLI token, running `az login` for you if the cached session cannot
# mint one (see "Azure CLI login preflight" below).
#
# There is no `sqlcmd` equivalent for Kusto, so this posts to the cluster's
# /v1/rest/query endpoint directly with curl and formats the response with jq.
# Both are required, and on Windows jq must be 1.7 or later (see the request
# body below).
#
# NAMED DATABASE ENTRIES, LIKE sql.sh. One Eventhouse exposes ONE query URI, and
# every KQL database under it shares that URI — so a second database is not a
# second endpoint, it is another name against the same host. That is the shape
# sql.sh already solves with SQL_ENDPOINT_<NAME>, so the same mechanism is used
# here rather than a second one: name the entries in .env, pick one per run with
# -e, list them with -l. The wrapper ships the mechanism; the client repo picks
# the names (NAME_1, NAME_2, whatever fits), so nothing project-specific is
# baked in and the script still works out of the box on a single database.
#
# .env keys:
#   KUSTO_CLUSTER_URI       https://<cluster>.<region>.kusto.fabric.microsoft.com
#                           (Fabric portal: KQL database → Query URI)
#   KUSTO_DATABASE_<NAME>   one entry per database, named whatever you like.
#                           Value is the KQL database display name; the item
#                           GUID also works.
#   KUSTO_DATABASE_DEFAULT  which entry runs when -e is omitted. Optional with
#                           exactly one entry defined.
#   KUSTO_DATABASE          the original single-slot key. Still read, and still
#                           preferred over an auto-picked sole named entry, so
#                           an existing .env keeps behaving exactly as it did.
#   AZURE_TENANT_ID         optional — passed to `az login` when set
#
#   KUSTO_CLUSTER_URI=https://<cluster>.<region>.kusto.fabric.microsoft.com
#   KUSTO_DATABASE_NAME_1=<KqlDatabaseName>
#   KUSTO_DATABASE_NAME_2=<KqlDatabaseName>
#   KUSTO_DATABASE_DEFAULT=NAME_1
#
# Multi-environment repos prefix the keys with an environment name (alnum, no
# underscore) and pick the environment per run with -E, the FAB_ENV variable,
# or ENV_DEFAULT in .env. Lookup is <ENV>_<KEY> first, bare <KEY> as fallback —
# deployment pipelines keep item display names identical across stages, so a
# name-valued entry is written once, bare, while the cluster URI (which moves
# with the stage) is prefixed. Prefer display names over item GUIDs for exactly
# that reason: a GUID is stage-specific, so it forces one prefixed line per
# environment, and a stale one queries the previous target silently where a
# stale name fails loudly.
#
#   SANDBOX_KUSTO_CLUSTER_URI=https://<cluster-s>.<region>.kusto.fabric.microsoft.com
#   PROD_KUSTO_CLUSTER_URI=https://<cluster-p>.<region>.kusto.fabric.microsoft.com
#   KUSTO_DATABASE_NAME_1=<KqlDatabaseName>
#   KUSTO_DATABASE_NAME_2=<KqlDatabaseName>
#   KUSTO_DATABASE_DEFAULT=NAME_1
#   ENV_DEFAULT=SANDBOX
#
# Auth note: the token audience is the cluster host itself, not a fixed resource
# string. Under Conditional Access a plain `az login` may not cover it, so the
# preflight below probes for a token against that exact audience rather than
# just checking that a session exists, and re-logs in with the right scope.
#
# Usage:
#   scripts/data/kql.sh -q "<Table> | count"
#   scripts/data/kql.sh -i path/to/query.kql
#   echo "<Table> | take 5" | scripts/data/kql.sh
#
#   # -e picks a named database entry, -E the environment:
#   scripts/data/kql.sh -e name_2 -q "<Table> | count"
#   scripts/data/kql.sh -E prod -q "<Table> | count"
#   scripts/data/kql.sh -l                      # list configured databases
#
#   # -d passes a database name/GUID straight through, bypassing .env entirely —
#   # unchanged from before, for a one-off database that has no entry:
#   scripts/data/kql.sh -d <OtherKqlDatabase> -q "<Table> | count"
#
#   # Management commands (leading dot) go to /v1/rest/mgmt automatically:
#   scripts/data/kql.sh -q ".show tables"
#
#   # -r emits the raw Kusto JSON response instead of a table, for piping to jq:
#   scripts/data/kql.sh -r -q "<Table> | take 1" | jq '.Tables[0].Rows'
#
# Exit status: 0 for a clean result, 3 when Kusto returned a result but flagged
# it as incomplete or possibly wrong, and anything else when there is no result:
# 1 when Kusto refused the query or answered without a result, or a login, .env
# entry or query is missing, otherwise the code of the step that failed, such
# as curl's when the request never completed. A flagged result is still
# printed, with each flag on stderr; the checks after the request say why.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/kql.sh
# so SCRIPT_DIR/../.. resolves to the repo root containing .env.

set -euo pipefail

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

# Resolve repo root (script lives in <repo>/scripts/data/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# -h is answered before the .env check so the usage text is readable from a
# checkout that has not been configured yet — which is when it is most wanted.
# Print the header block: line 2 through the first blank line. A fixed line
# range silently drifts out of date every time the header is edited.
for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: .env not found at $ENV_FILE" >&2
    exit 1
fi

# Extract values without sourcing (.env may contain entries bash would choke on).
# `|| true` is load-bearing: under `set -o pipefail` a grep that matches nothing
# fails the pipeline, so a missing key would abort the script under `set -e`
# before the explicit check below could print a useful message.
env_value() {
    { grep -E "^$1=" "$ENV_FILE" || true; } | head -n 1 | cut -d '=' -f 2- | tr -d '\r'
}

# Resolve a key through the active environment first (<ENV>_<KEY>), then bare.
# Env-invariant keys (an item name identical in every workspace) are written
# once, unprefixed, and still resolve when an environment is active.
cfg_value() {
    if [[ -n "${ENVNAME:-}" ]]; then
        local v
        v=$(env_value "${ENVNAME}_$1")
        if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    fi
    env_value "$1"
}

# Named database entries, mirroring sql.sh's list_endpoints. The bare
# KUSTO_DATABASE key has no trailing _<NAME> so it never appears here — it is
# the unnamed single slot, resolved separately below.
list_databases() {
    # $1 = key prefix: "" for bare entries, "<ENV>_" for one environment's.
    grep -oE "^${1}KUSTO_DATABASE_[A-Za-z0-9_]+" "$ENV_FILE" 2>/dev/null \
        | sed "s/^${1}KUSTO_DATABASE_//" | grep -v '^DEFAULT$' || true
}

# Environment names are the alnum prefixes in front of any KUSTO_ key
# (SANDBOX_KUSTO_CLUSTER_URI → SANDBOX). Derived from every KUSTO_ key, not just
# the database ones, so an environment that only overrides the cluster URI is
# still listed. Underscores are not allowed in an environment name — the key
# parse would be ambiguous.
list_env_prefixes() {
    grep -oE '^[A-Za-z0-9]+_KUSTO_' "$ENV_FILE" 2>/dev/null \
        | sed -E 's/_KUSTO_$//' | sort -u || true
}

# --- Azure CLI login preflight ------------------------------------------------
# `az account get-access-token` fails with a bare "Please run 'az login'" when
# there is no usable session, which is a dead end when the script is driven by a
# tool rather than typed by hand. Probing first turns that into a login prompt.
#
# --allow-no-subscriptions: a Fabric-only tenant has no Azure subscription
# attached, and without the flag `az login` fails with "No subscriptions found"
# before minting anything. The token wanted here is tenant-scoped, so the flag
# costs nothing and keeps subscription-less tenants working.
#
# Escape hatches: SKIP_AZ_LOGIN=1 suppresses the prompt (CI, or when the
# underlying tool's own error is what you want to see). On a headless box with
# no browser, log in once by hand:
#   az login --use-device-code --allow-no-subscriptions --scope <resource>/.default
ensure_az_login() {
    local resource="$1"
    local scope="${resource%/}/.default"

    if ! command -v az >/dev/null 2>&1; then
        echo "error: az not found on PATH" >&2
        echo "hint: winget install Microsoft.AzureCLI" >&2
        exit 1
    fi

    # Probe the exact audience rather than calling `az account show`: under
    # Conditional Access the session can be valid while still unable to mint a
    # token for this resource, and only the former would be caught.
    if az account get-access-token --resource "$resource" -o none 2>/dev/null; then
        return 0
    fi

    if [[ "${SKIP_AZ_LOGIN:-0}" == "1" ]]; then
        echo "warning: no Azure CLI token for $resource, and SKIP_AZ_LOGIN=1" >&2
        return 0
    fi

    # Environment wins over .env so a one-off tenant switch needs no file edit.
    local tenant="${AZURE_TENANT_ID:-}"
    if [[ -z "$tenant" ]]; then
        tenant=$(env_value AZURE_TENANT_ID)
    fi
    local tenant_args=()
    # Only needed for an account that is a guest in several tenants, where an
    # unqualified login lands in the home tenant and mints a rejected token.
    if [[ -n "$tenant" ]]; then
        tenant_args=(--tenant "$tenant")
    fi

    echo "note: no Azure CLI token for $resource — starting interactive login" >&2
    # -o none plus the stderr redirect keep az's subscription dump out of this
    # script's stdout, which callers pipe into other tools.
    if ! az login --allow-no-subscriptions --scope "$scope" \
            ${tenant_args+"${tenant_args[@]}"} -o none >&2; then
        echo "error: az login failed" >&2
        exit 1
    fi
    if ! az account get-access-token --resource "$resource" -o none 2>/dev/null; then
        echo "error: az login succeeded but still no token for $resource" >&2
        exit 1
    fi
}

QUERY=""
RAW=0
ENVNAME=""
DATABASE_OVERRIDE=""
ENTRY=""
LIST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUERY="$2"; shift 2 ;;
        -i)
            if [[ ! -f "$2" ]]; then
                echo "error: query file not found: $2" >&2
                exit 1
            fi
            QUERY=$(cat "$2"); shift 2 ;;
        -r) RAW=1; shift ;;
        -E) ENVNAME="$2"; shift 2 ;;
        -e) ENTRY="$2"; shift 2 ;;
        -d) DATABASE_OVERRIDE="$2"; shift 2 ;;
        -l) LIST=1; shift ;;
        -h|--help) shift ;;   # already handled above, before the .env check
        *) echo "error: unknown argument '$1' (expected -q, -i, -r, -E, -e, -d, -l, or stdin)" >&2; exit 1 ;;
    esac
done

# Active environment: -E flag, then FAB_ENV, then ENV_DEFAULT in .env. Optional —
# with none of the three set, only bare keys are read (single-environment mode).
if [[ -z "$ENVNAME" ]]; then ENVNAME="${FAB_ENV:-}"; fi
if [[ -z "$ENVNAME" ]]; then ENVNAME=$(env_value ENV_DEFAULT); fi
ENVNAME="${ENVNAME^^}"

CLUSTER=$(cfg_value KUSTO_CLUSTER_URI)

# Database resolution, in precedence order. Nothing here is fatal — -l needs to
# list what is configured even when none of it resolves, so the empty case is
# reported after the listing block below.
DATABASE=""
DB_SOURCE=""
DB_ENTRY=""
if [[ -n "$DATABASE_OVERRIDE" ]]; then
    # -d keeps its original meaning: the value goes to Kusto verbatim with no
    # .env lookup, so existing `-d <guid>` calls behave exactly as before.
    DATABASE="$DATABASE_OVERRIDE"
    DB_SOURCE="-d override"
elif [[ -n "$ENTRY" ]]; then
    DB_ENTRY="${ENTRY^^}"
    DATABASE=$(cfg_value "KUSTO_DATABASE_${DB_ENTRY}")
    if [[ -z "$DATABASE" ]]; then
        echo "error: no database entry '$ENTRY' in $ENV_FILE" >&2
        if [[ -n "$ENVNAME" ]]; then
            echo "       looked for ${ENVNAME}_KUSTO_DATABASE_${DB_ENTRY}, then KUSTO_DATABASE_${DB_ENTRY}" >&2
        else
            echo "       looked for KUSTO_DATABASE_${DB_ENTRY}" >&2
        fi
        echo "       run with -l to list what is defined" >&2
        exit 1
    fi
    DB_SOURCE="entry ${DB_ENTRY}"
else
    _default=$(cfg_value KUSTO_DATABASE_DEFAULT)
    if [[ -n "$_default" ]]; then
        DB_ENTRY="${_default^^}"
        DATABASE=$(cfg_value "KUSTO_DATABASE_${DB_ENTRY}")
        if [[ -z "$DATABASE" ]]; then
            echo "error: KUSTO_DATABASE_DEFAULT names '$_default', but no KUSTO_DATABASE_${DB_ENTRY} is set" >&2
            echo "       run with -l to list what is defined" >&2
            exit 1
        fi
        DB_SOURCE="entry ${DB_ENTRY} (KUSTO_DATABASE_DEFAULT)"
    fi
    # The original single-slot key, checked BEFORE auto-picking a sole named
    # entry. That order is load-bearing: an existing .env with KUSTO_DATABASE
    # plus one named extra (a logging database, say) must keep resolving to
    # KUSTO_DATABASE rather than silently switching to the extra.
    if [[ -z "$DATABASE" ]]; then
        DATABASE=$(cfg_value KUSTO_DATABASE)
        [[ -n "$DATABASE" ]] && DB_SOURCE="KUSTO_DATABASE (unnamed slot)"
    fi
    # Sole named entry, scoped to the active environment first, so a multi-env
    # .env with one database per environment needs no -e either.
    if [[ -z "$DATABASE" ]]; then
        mapfile -t _names < <(list_databases "${ENVNAME:+${ENVNAME}_}")
        if [[ ${#_names[@]} -eq 0 && -n "$ENVNAME" ]]; then
            mapfile -t _names < <(list_databases "")
        fi
        if [[ ${#_names[@]} -eq 1 ]]; then
            DB_ENTRY="${_names[0]}"
            DATABASE=$(cfg_value "KUSTO_DATABASE_${DB_ENTRY}")
            DB_SOURCE="entry ${DB_ENTRY} (only one defined)"
        fi
    fi
fi

if [[ "$LIST" -eq 1 ]]; then
    echo "KQL databases configured in $ENV_FILE (active environment: ${ENVNAME:-none}; * = used without -e):"
    found=0
    print_group() {
        local prefix="" label="  (no environment)"
        if [[ -n "$1" ]]; then prefix="${1}_"; label="  environment $1:"; fi
        local names unnamed
        names=$(list_databases "$prefix")
        unnamed=$(env_value "${prefix}KUSTO_DATABASE")
        [[ -z "$names" && -z "$unnamed" ]] && return 0
        found=1
        echo "$label"
        # The * marks the row a no-flag run actually resolves to, matched on
        # VALUE as well as name. Matching on the group alone would be wrong for
        # the common layout where only the cluster URI is environment-prefixed
        # and the database entries are bare: the resolved entry then lives in
        # the "(no environment)" group while an environment is active.
        local marker value
        if [[ -n "$unnamed" ]]; then
            marker="    "
            [[ "$DB_SOURCE" == "KUSTO_DATABASE"* && "$unnamed" == "$DATABASE" ]] && marker="  * "
            printf '%s%-14s %s\n' "$marker" "(unnamed)" "$unnamed"
        fi
        while read -r name; do
            [[ -z "$name" ]] && continue
            value=$(env_value "${prefix}KUSTO_DATABASE_$name")
            marker="    "
            [[ "$name" == "$DB_ENTRY" && "$value" == "$DATABASE" ]] && marker="  * "
            printf '%s%-14s %s\n' "$marker" "$name" "$value"
        done <<<"$names"
    }
    print_group ""
    while read -r envp; do
        [[ -z "$envp" ]] && continue
        print_group "$envp"
    done < <(list_env_prefixes)
    [[ "$found" -eq 0 ]] && echo "  (none — see the header of this script for the format)"
    exit 0
fi

if [[ -z "${CLUSTER:-}" || -z "${DATABASE:-}" ]]; then
    echo "error: KUSTO_CLUSTER_URI and a KQL database must both be resolvable from $ENV_FILE" >&2
    echo "       expected KUSTO_CLUSTER_URI plus one of:" >&2
    echo "         KUSTO_DATABASE_<NAME>=<KqlDatabaseName>   (pick with -e <name>)" >&2
    echo "         KUSTO_DATABASE=<KqlDatabaseName>          (the unnamed single slot)" >&2
    if [[ -n "$ENVNAME" ]]; then
        echo "       (environment $ENVNAME: <ENV>_<key> is checked first, bare <key> as fallback)" >&2
    fi
    echo "       -d <database> bypasses .env entirely; -l lists what is defined" >&2
    exit 1
fi
CLUSTER="${CLUSTER%/}"  # tolerate a trailing slash

# No -q/-i: read the query from stdin, so `echo ... | kql.sh` and heredocs work.
if [[ -z "$QUERY" ]]; then
    if [[ -t 0 ]]; then
        echo "error: no query given (use -q, -i, or pipe one in on stdin)" >&2
        exit 1
    fi
    QUERY=$(cat)
fi

# Kusto splits its surface across two endpoints: control commands (leading dot)
# must go to /rest/mgmt, everything else to /rest/query. Posting one to the other
# returns a parse error rather than a redirect, so route on the first character.
TRIMMED="${QUERY#"${QUERY%%[![:space:]]*}"}"
if [[ "$TRIMMED" == .* ]]; then
    ENDPOINT="$CLUSTER/v1/rest/mgmt"
else
    ENDPOINT="$CLUSTER/v1/rest/query"
fi

ensure_az_login "$CLUSTER"
TOKEN=$(az account get-access-token --resource "$CLUSTER" --query accessToken -o tsv)

# jq builds the JSON body so quotes, newlines, and backslashes in the query
# survive; string-concatenating it into the payload would not.
#
# The query goes into jq on stdin (-R raw, -s as one string) and the body into
# curl on stdin, never as an argument, for two reasons. Windows caps a whole
# command line at 32,767 characters, so a query past about 32 KB fails with
# "Argument list too long" before any request goes out. And Git Bash's own
# curl (/mingw64/bin, ahead of System32's on its PATH) decodes its arguments
# through the ANSI code page: measured with its curl 8.21, an é in an argument
# went out as the lone byte E9 and 日本 as "??", so non-ASCII text in a query
# was corrupted at any length.
#
# The bearer goes in on stdin as well: a command line is readable by other
# processes, and process-creation logging records it. curl has one stdin, so
# the two share a config block (--config -), the bearer as its header line and
# the body as its data-binary line, which jq writes. The first tojson builds
# the body and the second quotes it for the config file. Compact JSON holds no
# raw control character, so the only escapes the second can emit are \" and
# \\, and curl's config parser undoes exactly those.
#
# -b is for Windows, where native jq reads stdin in text mode: CRLF arrives as
# LF, and a 0x1A byte ends the input with no error, so the query would be cut
# short silently. -b (jq 1.7+) reads it byte for byte. It writes in text mode
# too, ending every line CRLF (measured with jq 1.8.2, 2026-10-12), so each jq
# below whose output is printed takes the flag as well. Elsewhere there is no
# text mode to switch off, and jq 1.6 rejects the flag.
JQ_BINARY_MODE=()
case "$OSTYPE" in msys* | cygwin*) JQ_BINARY_MODE=(-b) ;; esac
BODY_LINE=$(printf '%s' "$QUERY" \
    | jq ${JQ_BINARY_MODE+"${JQ_BINARY_MODE[@]}"} -Rrs --arg db "$DATABASE" \
        '{db: $db, csl: .} | "data-binary = \(tojson | tojson)"')

RESPONSE=$(printf 'header = "Authorization: Bearer %s"\n%s\n' "$TOKEN" "$BODY_LINE" \
    | curl -sS -w '\n%{http_code}' -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --config -)
HTTP="${RESPONSE##*$'\n'}"
RESPONSE="${RESPONSE%$'\n'*}"

# A refused query, such as a syntax error or a table that does not exist,
# answers HTTP 400 (Kusto.Data's exception reference gives the status of each),
# and every 4xx and 5xx but a 401 carries an error object in its body. The body
# is read first, whatever the status, because its message says what was wrong
# and the status alone does not.
if jq -e 'has("error")' >/dev/null 2>&1 <<<"$RESPONSE"; then
    jq ${JQ_BINARY_MODE+"${JQ_BINARY_MODE[@]}"} -r \
        '.error | "kusto error: \(.["@message"] // .message // tostring)"' <<<"$RESPONSE" >&2
    exit 1
fi

# Without an error object the answer must still be a result: a 2xx status, and
# the Tables array Kusto's response reference promises with one. Neither is a
# given. curl without --fail exits 0 on any status, and a 401's body need not be
# JSON, so without this check a 401 with an empty body would print nothing and
# exit 0, as though the query had matched no rows.
NO_RESULT=""
if [[ "$HTTP" != 2* ]]; then
    NO_RESULT="Kusto answered HTTP $HTTP"
elif ! jq -e '.Tables | type == "array"' >/dev/null 2>&1 <<<"$RESPONSE"; then
    NO_RESULT="Kusto answered HTTP $HTTP without a result"
fi
if [[ -n "$NO_RESULT" ]]; then
    echo "error: $NO_RESULT" >&2
    if [[ -n "$RESPONSE" ]]; then printf '%s\n' "${RESPONSE:0:400}" >&2; fi
    if [[ "$HTTP" == 401 ]]; then
        echo "hint: the token was refused; an account that is a guest in several tenants" >&2
        echo "      needs AZURE_TENANT_ID, so az mints in the tenant that owns the cluster" >&2
    fi
    exit 1
fi

# A query can also come back with rows and still be wrong. Kusto says so beside
# the result rather than in place of it, so the checks above see nothing, and it
# has two ways of saying it (both measured against a Fabric Eventhouse,
# 2026-10-01):
#
#   - A partial failure, such as a truncated result or a runaway query, ends a
#     result table with an {"Exceptions": [...]} object where a row belongs, and
#     the response stops there. Printed as one more row, it passed for data.
#   - A query that completes reports how in its QueryStatus table, which the
#     last table, the table of contents, points to. Kusto counts a Severity of 2
#     or less as a failure. 3 is a warning, and it is flagged too: the one that
#     prompted this check read "Results may be incorrect or incomplete
#     (E_INVALIDARG)", from a range whose 'from' was past its 'to', and its
#     result table had no row at all to show for it.
#
# Kusto's guidance is to ignore the whole result after a partial failure. What
# arrived is still printed, so that it can be looked at, but each flag goes to
# stderr and the exit status is 3, so no caller can take it for a clean result.
# A management command returns one table and no table of contents, so only a
# partial failure can flag one.
FLAGS=$(jq ${JQ_BINARY_MODE+"${JQ_BINARY_MODE[@]}"} -r '
    (.Tables // []) as $tables
    | ($tables[-1].Columns // [] | map(.ColumnName)) as $toc
    | ($toc | index("Kind")) as $kind
    | ($toc | index("Ordinal")) as $ordinal
    | ( $tables[].Rows[]? | objects
        | (.Exceptions // [tostring])[] | tostring | split("\r\n")[0] | split("\n")[0]
        | "kusto error: \(.)" ),
      ( if $kind == null or $ordinal == null then empty
        else $tables[-1].Rows[] | select(.[$kind] == "QueryStatus") | $tables[.[$ordinal]]
            | (.Columns | map(.ColumnName)) as $columns
            | ($columns | index("Severity")) as $severity
            | ($columns | index("SeverityName")) as $name
            | ($columns | index("StatusDescription")) as $description
            # No Severity column would be a format change: flag every row rather
            # than pass the result as clean.
            | .Rows[] | select((if $severity == null then 0 else .[$severity] end) <= 3)
            | (if $name == null then "status" else .[$name] | ascii_downcase end) as $level
            | (if $description == null then tostring else .[$description] end) as $text
            | "kusto \($level): \($text)"
        end )
' <<<"$RESPONSE" 2>/dev/null || true)

if [[ "$RAW" -eq 1 ]]; then
    printf '%s\n' "$RESPONSE"
else
    # v1 response shape: .Tables[0] carries the result set, .Columns[].ColumnName
    # the header, .Rows[] the values. Later tables are QueryProperties, QueryStatus
    # and the table of contents. A row that is an object is a partial failure,
    # which goes to stderr with the other flags rather than into the table.
    jq ${JQ_BINARY_MODE+"${JQ_BINARY_MODE[@]}"} -r '
        .Tables[0] as $t
        | ([$t.Columns[].ColumnName] | @tsv),
          ([$t.Columns[].ColumnName] | map("-" * (length + 2)) | @tsv),
          ($t.Rows[] | arrays | map(if . == null then "" else tostring end) | @tsv)
    ' <<<"$RESPONSE" | column -t -s $'\t'
fi

if [[ -n "$FLAGS" ]]; then
    printf '%s\n' "$FLAGS" >&2
    exit 3
fi
