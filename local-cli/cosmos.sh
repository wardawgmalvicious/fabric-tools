#!/usr/bin/env bash
# Read-only wrapper around the Cosmos DB REST API for Cosmos DB in Microsoft Fabric:
# queries, point reads and container listings against the live database. Finds the
# item's endpoint from its display name through the Fabric REST API and authenticates
# with the Azure CLI token, running `az login` for you if the cached session cannot
# mint one (see "Azure CLI tokens" below).
#
# THE kql.sh SHAPE. Cosmos DB in Fabric has no sqlcmd-style client and needs none:
# Fabric serves Gateway mode only, and Gateway mode is the documented Cosmos DB REST
# API over HTTPS, the calls an SDK makes for you. So this is curl + jq against REST, as
# kql.sh is against Kusto. What differs from the other curl wrappers:
#   - two audiences: https://cosmos.azure.com for the data, and
#     https://api.fabric.microsoft.com for the endpoint lookup;
#   - the token goes in Cosmos's own Authorization form, type=aad&ver=1.0&sig=<token>
#     URL-encoded, not Bearer (Fabric's Cosmos DB has no keys, so aad is the only type);
#   - every request carries x-ms-date and x-ms-version;
#   - errors are real HTTP statuses, unlike Kusto's 200 with an error body.
#
# THE GATEWAY RULE. The gateway will not run TOP, ORDER BY, OFFSET LIMIT, an aggregate,
# DISTINCT or GROUP BY across partitions. It answers 400 "The provided cross partition
# query can not be directly served by the gateway", on a container with a single
# partition key range too, so being small exempts nothing. An SDK gets round it by
# fetching a query plan, running it per range and merging client side. This script
# never merges: TOP per range concatenates past its limit, and an AVG or a GROUP BY does
# not add up, so a merge prints plausible wrong output. On that exact 400 it reads the
# container's partition key ranges instead. With exactly one, that range is the whole
# container and the answer is exact, so it re-runs the query there and says so on
# stderr. With more it fails and names the ways out: -p to scope the query to one
# partition key value, or the item's SQL analytics endpoint through sql.sh. The ranges
# are re-read on every such run, so a container that splits makes this fail loudly
# rather than go quietly wrong. Azure Cosmos DB starts a container on one physical
# partition, which is one range, per 10,000 RU/s of maximum throughput (not checked
# against Fabric): a portal-created container (5,000 RU/s) has one, and one created at
# Fabric's 50,000 RU/s ceiling would have five.
#
# WHAT IT IS FOR. The live container, by key, at request-unit cost: every run prints
# its RU total on stderr. Aggregates, joins and GROUP BY over a whole container belong
# on sql.sh. The item's OneLake copy has a SQL analytics endpoint on the workspace's
# usual SQL host, with the item's display name as the database and
# [<item>].[<container>] as the table (there is no dbo); it trails the container by a
# lag nobody has measured.
#
# READ-ONLY BY CONSTRUCTION, like ido.sh: the only verbs are GET and the query POST. A
# caller with Write could create and delete items through the same API with the same
# token; this script never issues those verbs.
#
# THE ENDPOINT IS LOOKED UP BY NAME, the way dax.sh resolves a model. The host carries
# the item's GUID, so it is stage-specific: kept in .env it would need an <ENV>_ line
# per stage, and a stale one would quietly read the previous stage's database. A display
# name survives promotion and fails loudly when wrong. The lookup costs a second token,
# one Fabric call per run and a Viewer role on the workspace; -H skips all three, for a
# caller with only the item's Read permission or a database in another workspace. The
# live serverFqdn is a URL (https://<item-id>.z<xy>.sql.cosmos.fabric.microsoft.com)
# although the REST reference shows a bare host, so both shapes are accepted, from
# Fabric and from -H.
#
# OUTPUT. Items are nested JSON, not rows, so each prints as one compact line, which
# pipes into jq and grep. Pages print as they arrive and are never combined. A request
# that fails with a transient status is retried, up to four attempts in all (see
# COSMOS_RETRY_STATUS); a run that still fails part-way has printed some pages, and says
# so on stderr. -t makes a table, which suits only a flat projection; -r prints the raw
# response pages.
#
# .env keys:
#   COSMOS_DATABASE_<NAME>    one entry per Cosmos DB item, named whatever you like.
#                             Value is the item's display name, which is also its
#                             database name: set from it at creation, read-only, and
#                             Fabric does not rename the item. Written once, bare.
#   COSMOS_DATABASE_DEFAULT   which entry runs when -e is omitted. Optional with
#                             exactly one entry defined.
#   COSMOS_WORKSPACE_ID       the workspace holding the items. Optional: falls back to
#                             PBI_WORKSPACE_ID, which dax.sh and report-png.sh read and
#                             which is the same GUID when the items sit beside the
#                             reports. Stage-specific, so <ENV>_-prefixed.
#   AZURE_TENANT_ID           optional — passed to `az login` when set
#
#   SANDBOX_PBI_WORKSPACE_ID=<workspace-guid>
#   PROD_PBI_WORKSPACE_ID=<workspace-guid>
#   COSMOS_DATABASE_MAIN=<CosmosDbItemName>
#   COSMOS_DATABASE_DEFAULT=MAIN
#   ENV_DEFAULT=SANDBOX
#
# Multi-environment repos pick the environment per run with -E, the FAB_ENV variable,
# or ENV_DEFAULT in .env, as the other wrappers do: <ENV>_<KEY> first, bare <KEY> as
# fallback.
#
# Flags:
#   -q <query>, -i <file>, stdin    the query, in Cosmos DB's NoSQL dialect
#   -c <container>    the container; optional when the database has exactly one, at
#                     the price of a container listing, whose RU is in the total
#   -p <value>        partition key value, as a string; scopes the query to it
#   -P <json>         partition key as a JSON array, for a number, a boolean or a
#                     hierarchical key. Cosmos compares typed values, so -p 5 and
#                     -P '[5]' name different keys.
#   -k <id>           point read of one item, with -p or -P: the cheapest read there is
#   -n <max>          stop after this many items (default 100); 0 follows every page
#   -t                a table instead of JSON lines
#   -r                the raw response pages, one per line, for jq
#   -l                the configured entries, and the resolved database's containers
#                     with their partition key paths
#   -e <name>         a COSMOS_DATABASE_<NAME> entry
#   -E <env>          the environment
#   -d <database>     an item display name, bypassing the entries
#   -w <guid>         another workspace, bypassing COSMOS_WORKSPACE_ID
#   -H <host>         the item's endpoint, skipping the Fabric lookup; the database
#                     then comes from -d or the entry
#
# Usage:
#   scripts/data/cosmos.sh -l
#   scripts/data/cosmos.sh -c <container> -q "SELECT * FROM c WHERE c.status = 'open'"
#   scripts/data/cosmos.sh -c <container> -i path/to/query.sql
#   echo "SELECT VALUE c.id FROM c" | scripts/data/cosmos.sh -c <container> -n 0
#   scripts/data/cosmos.sh -c <container> -q "SELECT VALUE COUNT(1) FROM c"
#   scripts/data/cosmos.sh -c <container> -p <value> -q "SELECT TOP 5 * FROM c ORDER BY c._ts DESC"
#   scripts/data/cosmos.sh -c <container> -p <value> -k <id>
#   scripts/data/cosmos.sh -c <container> -t -q "SELECT c.id, c.status FROM c"
#   scripts/data/cosmos.sh -c <container> -q "SELECT * FROM c" | jq -r '.id'
#   scripts/data/cosmos.sh -E prod -e main -c <container> -q "SELECT VALUE COUNT(1) FROM c"
#   scripts/data/cosmos.sh -H <item-id>.z<xy>.sql.cosmos.fabric.microsoft.com -d <ItemName> -l
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/cosmos.sh, so
# the directory two above it is the repo root containing .env.

set -euo pipefail

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

COSMOS_RESOURCE="https://cosmos.azure.com"
FABRIC_RESOURCE="https://api.fabric.microsoft.com"
FABRIC_API="$FABRIC_RESOURCE/v1"
# The REST API version every Cosmos request names; the probe that shaped this script
# ran on it (2026-10-01).
COSMOS_API_VERSION="2018-12-31"
DEFAULT_MAX_ITEMS=100
# x-ms-max-item-count accepts 1 to 1000.
PAGE_MAX=1000
GUID_RE='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
GATEWAY_REFUSAL="can not be directly served by the gateway"
CROSS_LINE='header = "x-ms-documentdb-query-enablecrosspartition: True"'
# Statuses worth another attempt. 408, 410, 429 and 503 are the ones Microsoft's Cosmos DB
# guidance says to retry, and 502 and 504 complete the Azure SDKs' default retry set, for
# whatever sits between here and the database. 500 that guidance says not to retry, but
# one cleared on the very next request when it hit page 132 of a long read (seen live
# 2026-10-01). This script only reads, so a repeat is always safe, and a continuation
# token is a stateless resume point, so a retried page asks for the same one. Deliberately
# absent: 400 (the query, or the gateway rule), 401 and 403 (the token), 404 (a name),
# and 449, which only writes get.
COSMOS_RETRY_STATUS="408 410 429 500 502 503 504"
# Four attempts in all. Before each retry it waits for a 429's x-ms-retry-after-ms when
# Cosmos sends one, otherwise for a second doubling per attempt, plus up to a second of
# jitter, and never longer than 30 seconds. A request that keeps failing without a
# retry-after gives up after 7 to 10 seconds of waiting, short enough for a command line.
COSMOS_ATTEMPTS=4
COSMOS_RETRY_BASE_MS=1000
COSMOS_RETRY_MAX_MS=30000

# -b is for Windows, where native jq reads stdin in text mode and writes CRLF: a query
# would lose its CRs and stop at a 0x1A byte, and every line printed here would end in
# \r. -b (jq 1.7+) reads and writes bytes as they are. Elsewhere there is no text mode
# to switch off, and jq 1.6 rejects the flag. Git Bash reports OSTYPE=cygwin, hence
# both patterns.
JQ=(jq)
case "$OSTYPE" in msys* | cygwin*) JQ=(jq -b) ;; esac

fail() {
    echo "error: $*" >&2
    exit 1
}

# --- Arguments ----------------------------------------------------------------
QUERY=""
QUERY_GIVEN=0
CONTAINER=""
PK_MODE=""
PK_VALUE=""
ITEM_ID=""
POINT_READ=0
MAX_ITEMS=""
TABLE=0
RAW=0
LIST=0
ENTRY=""
ENVNAME=""
DATABASE_OVERRIDE=""
WORKSPACE=""
HOST_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUERY="$2"; QUERY_GIVEN=1; shift 2 ;;
        -i)
            if [[ ! -f "$2" ]]; then
                fail "query file not found: $2"
            fi
            # read -d '' takes the whole file without the fork $(cat) would cost.
            IFS= read -r -d '' QUERY < "$2" || true
            QUERY_GIVEN=1; shift 2 ;;
        -c) CONTAINER="$2"; shift 2 ;;
        -p) PK_MODE+="p"; PK_VALUE="$2"; shift 2 ;;
        -P) PK_MODE+="P"; PK_VALUE="$2"; shift 2 ;;
        -k) ITEM_ID="$2"; POINT_READ=1; shift 2 ;;
        -n) MAX_ITEMS="$2"; shift 2 ;;
        -t) TABLE=1; shift ;;
        -r) RAW=1; shift ;;
        -l) LIST=1; shift ;;
        -e) ENTRY="$2"; shift 2 ;;
        -E) ENVNAME="$2"; shift 2 ;;
        -d) DATABASE_OVERRIDE="$2"; shift 2 ;;
        -w) WORKSPACE="$2"; shift 2 ;;
        -H) HOST_OVERRIDE="$2"; shift 2 ;;
        # Print the header block: line 2 through the first blank line. A fixed line
        # range silently drifts out of date every time the header is edited.
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) fail "unknown argument '$1' (expected -q, -i, -c, -p, -P, -k, -n, -t, -r, -l, -e, -E, -d, -w, -H, or stdin)" ;;
    esac
done

# Flags that cannot apply are refused rather than ignored: a partition key or a cap
# that silently did nothing would read as an answer.
if [[ ${#PK_MODE} -gt 1 ]]; then
    fail "give one partition key, with -p or -P"
fi
if [[ "$TABLE" -eq 1 && "$RAW" -eq 1 ]]; then
    fail "-t and -r are mutually exclusive"
fi
if [[ -n "$MAX_ITEMS" && ! "$MAX_ITEMS" =~ ^[0-9]+$ ]]; then
    fail "-n takes a whole number of items (0 for every page), got '$MAX_ITEMS'"
fi
if [[ "$POINT_READ" -eq 1 ]]; then
    if [[ -z "$ITEM_ID" ]]; then
        fail "-k needs an item id"
    fi
    if [[ -z "$PK_MODE" ]]; then
        fail "-k reads an item by id AND partition key: add -p <value>, or -P <json> for a typed or hierarchical key"
    fi
    if [[ "$QUERY_GIVEN" -eq 1 || -n "$MAX_ITEMS" ]]; then
        fail "-k reads one item by id, so -q, -i and -n do not apply"
    fi
fi
MAX_ITEMS=$(( 10#${MAX_ITEMS:-$DEFAULT_MAX_ITEMS} ))

# --- .env ---------------------------------------------------------------------
# Read without sourcing (.env may contain entries bash would choke on), and tolerated
# when absent: -H with -d needs nothing from it.
#
# Every $( ) is a fork, and on Git Bash a fork or a spawn costs about half a second
# (20 command substitutions took 9.6 s, measured 2026-10-01). So .env is read into
# memory once, helpers hand results back in REPLY rather than on stdout, and jq runs
# only where nothing in bash will do.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
ENV_LINES=()
if [[ -f "$ENV_FILE" ]]; then
    mapfile -t ENV_LINES < "$ENV_FILE"
fi

# REPLY <- the value of the first KEY= line, carriage returns removed: what the other
# wrappers' grep | head | cut | tr reads, without its four spawns per key.
env_value() {
    local line
    REPLY=""
    for line in ${ENV_LINES[@]+"${ENV_LINES[@]}"}; do
        if [[ "$line" == "$1="* ]]; then
            REPLY="${line#*=}"
            REPLY="${REPLY//$'\r'/}"
            return 0
        fi
    done
    return 0
}

# Resolve a key through the active environment first (<ENV>_<KEY>), then bare. Keys
# whose value is the same in every stage (an item name) are written once, unprefixed,
# and still resolve when an environment is active.
cfg_value() {
    if [[ -n "${ENVNAME:-}" ]]; then
        env_value "${ENVNAME}_$1"
        if [[ -n "$REPLY" ]]; then return 0; fi
    fi
    env_value "$1"
}

# ENTRIES <- the <NAME>s of the COSMOS_DATABASE_<NAME> keys carrying prefix $1 ("" for
# bare entries, "<ENV>_" for one environment's).
list_entries() {
    local line
    ENTRIES=()
    for line in ${ENV_LINES[@]+"${ENV_LINES[@]}"}; do
        [[ "$line" =~ ^${1}COSMOS_DATABASE_([A-Za-z0-9_]+)= ]] || continue
        [[ "${BASH_REMATCH[1]}" == DEFAULT ]] || ENTRIES+=("${BASH_REMATCH[1]}")
    done
}

# PREFIXES <- the environment names in front of any COSMOS_ key, in file order.
# Underscores are not allowed in an environment name — the key parse would be
# ambiguous.
list_env_prefixes() {
    local line seen=" "
    PREFIXES=()
    for line in ${ENV_LINES[@]+"${ENV_LINES[@]}"}; do
        [[ "$line" =~ ^([A-Za-z0-9]+)_COSMOS_ ]] || continue
        if [[ "$seen" != *" ${BASH_REMATCH[1]} "* ]]; then
            seen+="${BASH_REMATCH[1]} "
            PREFIXES+=("${BASH_REMATCH[1]}")
        fi
    done
}

# Active environment: -E flag, then FAB_ENV, then ENV_DEFAULT in .env. Optional — with
# none of the three set, only bare keys are read (single-environment mode).
if [[ -z "$ENVNAME" ]]; then ENVNAME="${FAB_ENV:-}"; fi
if [[ -z "$ENVNAME" ]]; then env_value ENV_DEFAULT; ENVNAME="$REPLY"; fi
ENVNAME="${ENVNAME^^}"

# --- Which database -----------------------------------------------------------
# In precedence order, as kql.sh resolves its KQL databases. Nothing here is fatal on
# its own: -l lists what is configured even when none of it resolves, so the empty case
# is reported after the listing.
DATABASE=""
DB_ENTRY=""
if [[ -n "$DATABASE_OVERRIDE" ]]; then
    DATABASE="$DATABASE_OVERRIDE"
elif [[ -n "$ENTRY" ]]; then
    DB_ENTRY="${ENTRY^^}"
    cfg_value "COSMOS_DATABASE_${DB_ENTRY}"
    DATABASE="$REPLY"
    if [[ -z "$DATABASE" ]]; then
        echo "error: no database entry '$ENTRY' in $ENV_FILE" >&2
        if [[ -n "$ENVNAME" ]]; then
            echo "       looked for ${ENVNAME}_COSMOS_DATABASE_${DB_ENTRY}, then COSMOS_DATABASE_${DB_ENTRY}" >&2
        else
            echo "       looked for COSMOS_DATABASE_${DB_ENTRY}" >&2
        fi
        echo "       run with -l to list what is defined" >&2
        exit 1
    fi
else
    cfg_value COSMOS_DATABASE_DEFAULT
    if [[ -n "$REPLY" ]]; then
        DB_ENTRY="${REPLY^^}"
        cfg_value "COSMOS_DATABASE_${DB_ENTRY}"
        DATABASE="$REPLY"
        if [[ -z "$DATABASE" ]]; then
            echo "error: COSMOS_DATABASE_DEFAULT names '$DB_ENTRY', but no COSMOS_DATABASE_${DB_ENTRY} is set" >&2
            echo "       run with -l to list what is defined" >&2
            exit 1
        fi
    else
        # The sole entry, scoped to the active environment first, so a multi-env .env
        # with one database per environment needs no -e either.
        list_entries "${ENVNAME:+${ENVNAME}_}"
        if [[ ${#ENTRIES[@]} -eq 0 && -n "$ENVNAME" ]]; then
            list_entries ""
        fi
        if [[ ${#ENTRIES[@]} -eq 1 ]]; then
            DB_ENTRY="${ENTRIES[0]}"
            cfg_value "COSMOS_DATABASE_${DB_ENTRY}"
            DATABASE="$REPLY"
        fi
    fi
fi

# --- Azure CLI tokens ---------------------------------------------------------
# The other wrappers probe for a token and then mint it, two az calls per audience.
# This one needs two audiences, and each az call is a Python start-up (about 2.8 s,
# measured 2026-10-01), so it mints first and treats a failure as the probe: a run that
# needs no login costs one call per audience.
#
# --allow-no-subscriptions: a Fabric-only tenant has no Azure subscription attached, and
# without the flag `az login` fails with "No subscriptions found" before minting
# anything. The tokens wanted here are tenant-scoped, so the flag costs nothing.
#
# Escape hatches: SKIP_AZ_LOGIN=1 suppresses the login prompt (CI, or when az's own
# error is what you want to see). On a headless box with no browser, log in once by hand:
#   az login --use-device-code --allow-no-subscriptions --scope <resource>/.default
require_az() {
    if ! command -v az >/dev/null 2>&1; then
        echo "error: az not found on PATH" >&2
        echo "hint: winget install Microsoft.AzureCLI" >&2
        exit 1
    fi
}

# REPLY <- a token for resource $1. A trailing CR is dropped, in case az ever writes one:
# it would end up inside the Authorization header.
get_token() {
    local resource="$1" tenant tenant_args=()
    REPLY=$(az account get-access-token --resource "$resource" --query accessToken -o tsv 2>/dev/null) || REPLY=""
    REPLY="${REPLY%$'\r'}"
    if [[ -n "$REPLY" ]]; then return 0; fi

    if [[ "${SKIP_AZ_LOGIN:-0}" == "1" ]]; then
        echo "warning: no Azure CLI token for $resource, and SKIP_AZ_LOGIN=1" >&2
        az account get-access-token --resource "$resource" -o none >&2 || true
        exit 1
    fi

    # Environment wins over .env so a one-off tenant switch needs no file edit. Only
    # needed for an account that is a guest in several tenants, where an unqualified
    # login lands in the home tenant and mints a rejected token.
    tenant="${AZURE_TENANT_ID:-}"
    if [[ -z "$tenant" ]]; then env_value AZURE_TENANT_ID; tenant="$REPLY"; fi
    if [[ -n "$tenant" ]]; then tenant_args=(--tenant "$tenant"); fi

    echo "note: no Azure CLI token for $resource — starting interactive login" >&2
    # -o none plus the stderr redirect keep az's subscription dump out of this script's
    # stdout, which callers pipe into other tools.
    if ! az login --allow-no-subscriptions --scope "${resource%/}/.default" \
            ${tenant_args[@]+"${tenant_args[@]}"} -o none >&2; then
        fail "az login failed"
    fi
    REPLY=$(az account get-access-token --resource "$resource" --query accessToken -o tsv 2>/dev/null) || REPLY=""
    REPLY="${REPLY%$'\r'}"
    if [[ -z "$REPLY" ]]; then
        fail "az login succeeded but still no token for $resource"
    fi
}

# --- Fabric: the endpoint by name ---------------------------------------------
# WORKSPACE <- -w, else COSMOS_WORKSPACE_ID, else PBI_WORKSPACE_ID; may stay empty.
find_workspace() {
    if [[ -z "$WORKSPACE" ]]; then cfg_value COSMOS_WORKSPACE_ID; WORKSPACE="$REPLY"; fi
    if [[ -z "$WORKSPACE" ]]; then cfg_value PBI_WORKSPACE_ID; WORKSPACE="$REPLY"; fi
}

resolve_workspace() {
    find_workspace
    if [[ -z "$WORKSPACE" ]]; then
        echo "error: no workspace to look the item up in — set COSMOS_WORKSPACE_ID (or" >&2
        echo "       PBI_WORKSPACE_ID) in $ENV_FILE, pass -w <guid>, or skip the lookup" >&2
        echo "       with -H <host>" >&2
        exit 1
    fi
    if [[ ! "$WORKSPACE" =~ $GUID_RE ]]; then
        fail "workspace '$WORKSPACE' is not a GUID"
    fi
}

# One Fabric GET; RESP_BODY <- the body, and any non-2xx is fatal with Fabric's own
# errorCode and message. The bearer reaches curl in a config block on stdin, never as
# an argument: a command line is readable by other processes, and process-creation
# logging records it. --proto '=https' with no -L keeps the bearer off any other
# scheme and any redirect.
fabric_get() {
    local url="$1" what="$2" out
    out=$(printf 'header = "Authorization: Bearer %s"\n' "$FABRIC_TOKEN" \
        | curl -sS --proto '=https' --max-time 60 -w '\n%{http_code}' --config - "$url") \
        || fail "the $what request failed"
    RESP_STATUS="${out##*$'\n'}"
    RESP_BODY="${out%$'\n'*}"
    if [[ "$RESP_STATUS" == 2?? ]]; then return 0; fi
    echo "error: the $what answered HTTP $RESP_STATUS" >&2
    "${JQ[@]}" -r '"\(.errorCode // "?"): \(.message // "")"' <<<"$RESP_BODY" >&2 2>/dev/null \
        || printf '%s\n' "${RESP_BODY:0:400}" >&2
    case "$RESP_STATUS" in
        401) echo "hint: an account that is a guest in several tenants needs AZURE_TENANT_ID, so az mints in the tenant that owns the workspace" >&2 ;;
        403|404) echo "hint: listing a workspace's items needs a Viewer role on it; -H <host> skips the lookup for a caller with only the item's Read permission" >&2 ;;
    esac
    exit 1
}

# REPLY <- the host in $1, which may be a bare host or an https URL with a path. Any
# other scheme, or anything that is not a host, is refused before a token is sent to it.
normalize_host() {
    local h="${1#[Hh][Tt][Tt][Pp][Ss]://}"
    h="${h%%/*}"
    if [[ ! "$h" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
        fail "$2 '$1' is not an https host"
    fi
    REPLY="$h"
}

# Pages through the workspace's Cosmos DB items until one is named $1. ITEM_DB and
# ITEM_FQDN <- its databaseName and serverFqdn, or empty; ITEM_NAMES <- the other items
# seen, for the error that follows a miss. The field that can be empty goes last: read
# with a tab IFS collapses an empty field in the middle.
fetch_items() {
    local url="$FABRIC_API/workspaces/$WORKSPACE/cosmosDbDatabases" kind a b
    ITEM_DB="" ITEM_FQDN="" ITEM_NAMES=()
    while [[ -n "$url" ]]; do
        fabric_get "$url" "Cosmos DB item list"
        url=""
        while IFS=$'\t' read -r kind a b; do
            case "$kind" in
                next) url="$a" ;;
                match) ITEM_DB="$a"; ITEM_FQDN="$b" ;;
                name) ITEM_NAMES+=("$a") ;;
            esac
        done < <("${JQ[@]}" -r --arg name "$1" '
            ["next", .continuationUri // ""],
            ((.value // [])[]
             | if .displayName == $name
               then ["match", .properties.databaseName // .displayName,
                     .properties.serverFqdn // ""]
               else ["name", .displayName] end)
            | @tsv' <<<"$RESP_BODY")
        if [[ -n "$ITEM_DB" ]]; then return 0; fi
        # The next page's URI comes from the response, so it is checked before the
        # bearer follows it anywhere.
        if [[ -n "$url" && "$url" != "$FABRIC_API/"* ]]; then
            fail "the item list's continuationUri points outside $FABRIC_API: $url"
        fi
    done
}

# HOST, DB_NAME and COSMOS_TOKEN, from -H or from the Fabric lookup.
resolve_database() {
    local prefetch
    require_az
    if [[ -n "$HOST_OVERRIDE" ]]; then
        normalize_host "$HOST_OVERRIDE" "-H"
        HOST="$REPLY"
        DB_NAME="$DATABASE"
        get_token "$COSMOS_RESOURCE"
        COSMOS_TOKEN="$REPLY"
        return 0
    fi

    resolve_workspace
    # The Cosmos token is minted in the background while the lookup runs, since az's
    # start-up dominates a run and the two calls are independent. It comes back through
    # a pipe, never a file. Empty (no session, or a login the lookup's own mint then
    # ran) means it is minted again below, with the login path.
    exec {prefetch}< <(az account get-access-token --resource "$COSMOS_RESOURCE" \
        --query accessToken -o tsv 2>/dev/null)
    get_token "$FABRIC_RESOURCE"
    FABRIC_TOKEN="$REPLY"
    fetch_items "$DATABASE"

    if [[ -z "$ITEM_DB" ]]; then
        echo "error: no Cosmos DB item named '$DATABASE' in workspace $WORKSPACE${ENVNAME:+ (environment $ENVNAME)}" >&2
        if [[ ${#ITEM_NAMES[@]} -gt 0 ]]; then
            echo "       the Cosmos DB items there:" >&2
            printf '         %s\n' "${ITEM_NAMES[@]}" >&2
        else
            echo "       the workspace has no Cosmos DB items" >&2
        fi
        echo "hint: an entry holds the item's display name, exactly as the workspace shows it" >&2
        exit 1
    fi
    if [[ -z "$ITEM_FQDN" ]]; then
        fail "item '$DATABASE' has no serverFqdn yet; if it was just created, retry in a minute"
    fi
    normalize_host "$ITEM_FQDN" "the item's serverFqdn"
    HOST="$REPLY"
    DB_NAME="$ITEM_DB"

    IFS= read -r COSMOS_TOKEN <&"$prefetch" || COSMOS_TOKEN=""
    exec {prefetch}<&-
    COSMOS_TOKEN="${COSMOS_TOKEN%$'\r'}"
    if [[ -z "$COSMOS_TOKEN" ]]; then
        get_token "$COSMOS_RESOURCE"
        COSMOS_TOKEN="$REPLY"
    fi
}

# --- Cosmos DB requests -------------------------------------------------------
# REPLY <- $1 as a URL path segment. A name made only of unreserved characters passes
# through, which covers nearly every name; anything else goes through jq's @uri, which
# encodes UTF-8 bytes. LC_ALL=C keeps the ranges to ASCII.
url_segment() {
    local LC_ALL=C
    if [[ "$1" =~ ^[A-Za-z0-9._~-]+$ ]]; then
        REPLY="$1"
    else
        REPLY=$("${JQ[@]}" -rn --arg s "$1" '$s | @uri')
    fi
}

# REPLY <- $1 quoted for a curl config file, whose parser undoes \\, \", \t, \n and \r
# inside a double-quoted value. Backslash goes first, or the others would be doubled.
config_quote() {
    local v="${1//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\t'/\\t}"
    v="${v//$'\n'/\\n}"
    REPLY="${v//$'\r'/\\r}"
}

# One request: cosmos_send METHOD PATH EXTRA_CONFIG [CURL_ARG...]. EXTRA_CONFIG is more
# curl config lines (a header, the body), and goes on stdin with the Authorization line,
# like everything that is not a fixed flag: the token, because argv is readable by other
# processes, and the body and the partition key, because Git Bash's curl decodes its
# arguments through the ANSI code page (measured with its curl 8.21: an é went out as
# the lone byte E9). Sets RESP_STATUS, RESP_HEADERS, RESP_BODY and, from the headers,
# RESP_CHARGE, RESP_CONT, RESP_COUNT and RESP_RETRY.
#
# x-ms-date is formatted by bash's own printf, so no `date` spawn: TZ=UTC0 needs no
# zone data, which Git Bash lacks, and LC_ALL=C keeps the day and month names English
# whatever the locale (measured 2026-10-01 under de_DE: "Do, 01 Okt" without it).
cosmos_send() {
    local method="$1" path="$2" extra="$3" date out rest line name value
    shift 3
    TZ=UTC0 LC_ALL=C printf -v date '%(%a, %d %b %Y %H:%M:%S GMT)T' -1
    out=$(printf 'header = "Authorization: type%%3Daad%%26ver%%3D1.0%%26sig%%3D%s"\nheader = "x-ms-date: %s"\n%s\n' \
            "$COSMOS_TOKEN" "$date" "$extra" \
        | curl -sS --proto '=https' --max-time 120 -D - -w '\n%{http_code}' -X "$method" \
            -H "x-ms-version: $COSMOS_API_VERSION" -H 'Accept: application/json' \
            ${1+"$@"} --config - "https://$HOST/$path") \
        || fail "$method https://$HOST/$path failed"

    # -D - puts the headers ahead of the body on stdout, and -w the status after it. A
    # proxy's CONNECT reply or a 100 Continue adds a header block of its own, so blocks
    # are stripped while the text still starts like one; a JSON body never does.
    RESP_STATUS="${out##*$'\n'}"
    rest="${out%$'\n'*}"
    RESP_HEADERS=""
    while [[ "$rest" == HTTP/* && "$rest" == *$'\r\n\r\n'* ]]; do
        RESP_HEADERS="${rest%%$'\r\n\r\n'*}"
        rest="${rest#*$'\r\n\r\n'}"
    done
    RESP_BODY="$rest"
    RESP_CHARGE="" RESP_CONT="" RESP_COUNT="" RESP_RETRY=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        name="${line%%:*}"
        value="${line#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        # HTTP/2 lowercases header names; HTTP/1.1 need not.
        case "${name,,}" in
            x-ms-request-charge) RESP_CHARGE="$value" ;;
            x-ms-continuation) RESP_CONT="$value" ;;
            x-ms-item-count) RESP_COUNT="$value" ;;
            x-ms-retry-after-ms) RESP_RETRY="$value" ;;
        esac
    done <<<"$RESP_HEADERS"
}

# cosmos_send, repeated while the answer is a status in COSMOS_RETRY_STATUS, up to
# COSMOS_ATTEMPTS in all, with a note on stderr before each retry. Takes the same
# arguments and sets the same results, plus RESP_ATTEMPTS, the number of requests made.
# Each attempt gets a fresh x-ms-date.
cosmos_call() {
    local method="$1" path="$2" extra="$3" wait_ms wait_s
    shift 3
    RESP_ATTEMPTS=1
    while :; do
        cosmos_send "$method" "$path" "$extra" ${1+"$@"}
        if [[ " $COSMOS_RETRY_STATUS " != *" $RESP_STATUS "* || "$RESP_ATTEMPTS" -ge "$COSMOS_ATTEMPTS" ]]; then
            return 0
        fi
        # A failed attempt reports its own charge, and the run's total is what it spent,
        # so that charge counts before the next attempt overwrites it.
        add_charge "$RESP_CHARGE"
        # Nine digits at most, so a nonsense header cannot overflow the arithmetic.
        if [[ "$RESP_RETRY" =~ ^[0-9]{1,9}$ ]]; then
            wait_ms=$(( 10#$RESP_RETRY ))
        else
            wait_ms=$(( COSMOS_RETRY_BASE_MS << (RESP_ATTEMPTS - 1) ))
        fi
        wait_ms=$(( wait_ms + RANDOM % 1000 ))
        if [[ "$wait_ms" -gt "$COSMOS_RETRY_MAX_MS" ]]; then wait_ms=$COSMOS_RETRY_MAX_MS; fi
        RESP_ATTEMPTS=$(( RESP_ATTEMPTS + 1 ))
        echo "note: $method /$path answered HTTP $RESP_STATUS; attempt $RESP_ATTEMPTS of $COSMOS_ATTEMPTS in $wait_ms ms" >&2
        printf -v wait_s '%d.%03d' $(( wait_ms / 1000 )) $(( wait_ms % 1000 ))
        sleep "$wait_s"
    done
}

# Any non-2xx: the status, then the first line of Cosmos's message — the rest is an
# ActivityId and a trace. Some messages wrap a JSON list of errors, which is unwrapped.
# Fabric's gateway adds two shapes (seen live 2026-10-01). A query's 404 carries the
# backend's whole error, JSON-encoded, as its message, so a message that is itself an
# error object is unwrapped in turn. A point read's 404 is one line of about 5,000
# characters, the message followed by a diagnostics object from ', {"Summary":' on,
# which is cut. Whatever still runs past 400 characters is cut there.
cosmos_error() {
    local tries=""
    if [[ "${RESP_ATTEMPTS:-1}" -gt 1 ]]; then tries=" (attempt $RESP_ATTEMPTS of $COSMOS_ATTEMPTS)"; fi
    echo "error: $1 answered HTTP $RESP_STATUS$tries" >&2
    "${JQ[@]}" -r '
        def text:
            (split("\n")[0] | rtrimstr("\r")) as $m
            | ($m | try fromjson catch null) as $j
            | if ($j | type) == "object" and ($j.message | type) == "string" then
                $j.message | text
              else
                ($m | ltrimstr("Message: ")
                 | try (fromjson | [.errors[]?.message, .Errors[]?] | map(strings) | join("; "))
                   catch "") as $inner
                | if $inner == "" then $m | split(", {\"Summary\":")[0] else $inner end
              end;
        (.message // "" | text) as $t
        | "\(.code // "?"): \(if ($t | length) > 400 then ($t | .[:400]) + " ..." else $t end)"
    ' <<<"$RESP_BODY" >&2 2>/dev/null || printf '%s\n' "${RESP_BODY:0:400}" >&2
    case "$RESP_STATUS" in
        # Everything Fabric's gateway says about a query it cannot parse (seen live
        # 2026-10-01): no position and no reason.
        400)
            if [[ "$RESP_BODY" == *"One of the input values is invalid"* ]]; then
                echo "hint: for a query this usually means a syntax error, and the gateway does not say where" >&2
            fi ;;
        # The 401 itself cannot say which audience it wanted: its list of accepted
        # audiences comes back empty.
        401) echo "hint: Cosmos DB in Fabric takes only Entra tokens for $COSMOS_RESOURCE, which is what this sends; an account that is a guest in several tenants needs AZURE_TENANT_ID" >&2 ;;
        403) echo "hint: reading needs the item's Read permission, through a workspace role or a share; an expired token answers 403 too" >&2 ;;
        404) echo "hint: no such database, container or item — -l lists the containers" >&2 ;;
        429) echo "hint: the container's throughput is spent for the moment${RESP_RETRY:+ (Cosmos asks for ${RESP_RETRY} ms)}; retry shortly" >&2 ;;
    esac
}

# RU totals in thousandths, since bash has no floating point; charges come as decimals
# like 2.84 or 13.33.
RU_MILLI=0
add_charge() {
    [[ "$1" =~ ^([0-9]+)(\.([0-9]+))?$ ]] || return 0
    local frac="${BASH_REMATCH[3]}000"
    RU_MILLI=$(( RU_MILLI + 10#${BASH_REMATCH[1]} * 1000 + 10#${frac:0:3} ))
}

ru_total() {
    local hundredths=$(( (RU_MILLI + 5) / 10 ))
    printf -v REPLY '%d.%02d' $(( hundredths / 100 )) $(( hundredths % 100 ))
}

# CONTAINER_ROWS <- one "id<TAB>partition key paths<TAB>kind" line per container. A kind
# of MultiHash is a hierarchical key, which takes -P.
list_containers() {
    cosmos_call GET "dbs/$DB_PATH/colls" ""
    if [[ "$RESP_STATUS" != 2?? ]]; then
        cosmos_error "listing the containers of $DB_NAME"
        exit 1
    fi
    add_charge "$RESP_CHARGE"
    mapfile -t CONTAINER_ROWS < <("${JQ[@]}" -r '
        .DocumentCollections[]?
        | [.id, (.partitionKey.paths // [] | join(", ")), (.partitionKey.kind // "")]
        | @tsv' <<<"$RESP_BODY")
}

ITEMS=0
PAGES=0
CAPPED=0
TABLE_PAGES=()

# Prints a page as it arrives (JSON lines, or raw), or keeps it for -t, which needs
# every row to size its columns. An empty page, which a cross-partition query can
# return, costs no jq.
emit_page() {
    if [[ "$RAW" -eq 1 ]]; then
        printf '%s\n' "$1"
    elif [[ "$TABLE" -eq 1 ]]; then
        TABLE_PAGES+=("$1")
    elif [[ "$2" -gt 0 ]]; then
        "${JQ[@]}" -c '.Documents[]' <<<"$1"
    fi
}

# Pages through the query with the scope in $1 (config lines), printing as it goes.
# On the gateway's cross-partition refusal it sets REFUSED and returns, for the caller
# to decide; any other failure is fatal here.
run_query() {
    local scope="$1" cont="" size extra count tail
    REFUSED=0
    while :; do
        size=$PAGE_MAX
        if [[ "$MAX_ITEMS" -gt 0 && $(( MAX_ITEMS - ITEMS )) -lt $PAGE_MAX ]]; then
            size=$(( MAX_ITEMS - ITEMS ))
        fi
        extra="$BODY_LINE"$'\n'"$scope"
        if [[ -n "$cont" ]]; then
            config_quote "$cont"
            extra+=$'\n'"header = \"x-ms-continuation: $REPLY\""
        fi
        cosmos_call POST "dbs/$DB_PATH/colls/$CONTAINER_PATH/docs" "$extra" \
            -H 'Content-Type: application/query+json' \
            -H 'x-ms-documentdb-isquery: True' \
            -H "x-ms-max-item-count: $size"
        if [[ "$RESP_STATUS" != 2?? ]]; then
            if [[ "$PAGES" -eq 0 && "$RESP_STATUS" == 400 && "$RESP_BODY" == *"$GATEWAY_REFUSAL"* ]]; then
                REFUSED=1
                return 0
            fi
            cosmos_error "the query on $CONTAINER"
            # The pages before this one are already on stdout, where they would pass
            # for the whole answer (a transient 500 on page 132 of a long read, seen
            # live 2026-10-01). -t has printed nothing yet.
            if [[ "$PAGES" -gt 0 && "$TABLE" -eq 0 ]]; then
                echo "warning: the $ITEMS item(s) already printed are only part of the answer" >&2
            fi
            exit 1
        fi
        PAGES=$(( PAGES + 1 ))
        add_charge "$RESP_CHARGE"
        count="$RESP_COUNT"
        if [[ ! "$count" =~ ^[0-9]+$ ]]; then
            # No x-ms-item-count header: the body ends with "_count":N.
            count=0
            tail="$RESP_BODY"
            if [[ ${#tail} -gt 64 ]]; then tail="${tail: -64}"; fi
            if [[ "$tail" =~ \"_count\":([0-9]+) ]]; then count="${BASH_REMATCH[1]}"; fi
        fi
        ITEMS=$(( ITEMS + count ))
        emit_page "$RESP_BODY" "$count"
        cont="$RESP_CONT"
        if [[ -z "$cont" ]]; then return 0; fi
        if [[ "$MAX_ITEMS" -gt 0 && "$ITEMS" -ge "$MAX_ITEMS" ]]; then
            CAPPED=1
            return 0
        fi
    done
}

# --- -l -----------------------------------------------------------------------
if [[ "$LIST" -eq 1 ]]; then
    echo "Cosmos DB entries in $ENV_FILE (active environment: ${ENVNAME:-none}; * = used without -e):"
    found=0
    print_group() {
        local prefix="" label="  (no environment)" name marker
        if [[ -n "$1" ]]; then prefix="${1}_"; label="  environment $1:"; fi
        list_entries "$prefix"
        if [[ ${#ENTRIES[@]} -eq 0 ]]; then return 0; fi
        found=1
        echo "$label"
        # The * marks the row a no-flag run resolves to, matched on value as well as
        # name: in the common layout the entries are bare while an environment is
        # active, so the resolved entry sits in the "(no environment)" group.
        for name in "${ENTRIES[@]}"; do
            env_value "${prefix}COSMOS_DATABASE_$name"
            marker="    "
            if [[ "$name" == "$DB_ENTRY" && "$REPLY" == "$DATABASE" ]]; then marker="  * "; fi
            printf '%s%-14s %s\n' "$marker" "$name" "$REPLY"
        done
    }
    print_group ""
    list_env_prefixes
    for envp in ${PREFIXES[@]+"${PREFIXES[@]}"}; do
        print_group "$envp"
    done
    if [[ "$found" -eq 0 ]]; then
        echo "  (none — see the header of this script for the format)"
    fi

    # Nothing resolves: list what the workspace holds, the names an entry can take.
    if [[ -z "$DATABASE" ]]; then
        if [[ -n "$HOST_OVERRIDE" ]]; then exit 0; fi
        find_workspace
        if [[ -z "$WORKSPACE" ]]; then exit 0; fi
        resolve_workspace
        require_az
        get_token "$FABRIC_RESOURCE"
        FABRIC_TOKEN="$REPLY"
        fetch_items ""
        echo "Cosmos DB items in workspace $WORKSPACE:"
        if [[ ${#ITEM_NAMES[@]} -eq 0 ]]; then echo "  (none)"; fi
        for name in ${ITEM_NAMES[@]+"${ITEM_NAMES[@]}"}; do echo "  $name"; done
        exit 0
    fi

    resolve_database
    url_segment "$DB_NAME"
    DB_PATH="$REPLY"
    list_containers
    echo "containers in $DB_NAME ($HOST):"
    if [[ ${#CONTAINER_ROWS[@]} -eq 0 ]]; then
        echo "  (none)"
    else
        {
            printf '  %s\t%s\t%s\n' "container" "partition key" "kind"
            printf '  %s\n' "${CONTAINER_ROWS[@]}"
        } | column -t -s $'\t'
    fi
    ru_total
    echo "${#CONTAINER_ROWS[@]} container(s), $REPLY RU" >&2
    exit 0
fi

if [[ -z "$DATABASE" ]]; then
    echo "error: no Cosmos DB database resolves from $ENV_FILE" >&2
    if [[ ! -f "$ENV_FILE" ]]; then echo "       (there is no .env there)" >&2; fi
    list_entries "${ENVNAME:+${ENVNAME}_}"
    if [[ ${#ENTRIES[@]} -eq 0 && -n "$ENVNAME" ]]; then list_entries ""; fi
    if [[ ${#ENTRIES[@]} -gt 1 ]]; then
        echo "       ${#ENTRIES[@]} entries and no COSMOS_DATABASE_DEFAULT: pick one with -e <name>" >&2
    else
        echo "       expected COSMOS_DATABASE_<NAME>=<CosmosDbItemName>, picked with -e <name>" >&2
    fi
    echo "       -d <ItemName> names an item directly; -l lists what is defined" >&2
    exit 1
fi

# --- The request, before any token is spent -----------------------------------
# Input mistakes fail here, ahead of two az start-ups and a lookup.
if [[ "$POINT_READ" -eq 0 && "$QUERY_GIVEN" -eq 0 ]]; then
    if [[ -t 0 ]]; then
        fail "no query given (use -q, -i, or pipe one in on stdin; -k reads one item by id)"
    fi
    IFS= read -r -d '' QUERY || true
fi
if [[ "$POINT_READ" -eq 0 && "$QUERY" != *[![:space:]]* ]]; then
    fail "the query is empty"
fi

# The partition key header is a JSON array, ASCII only: a header carries UTF-8 badly,
# and a Cosmos SDK escapes the same way. jq -a writes non-ASCII as \uXXXX, and a -P
# that is not a non-empty JSON array is refused.
PK_LINE=""
PK_JSON=""
if [[ -n "$PK_MODE" ]]; then
    if [[ "$PK_MODE" == p ]]; then
        PK_JSON=$("${JQ[@]}" -nca --arg v "$PK_VALUE" '[$v]')
    else
        PK_JSON=$("${JQ[@]}" -nca --arg j "$PK_VALUE" '
            $j | try fromjson catch ("-P is not JSON: " + $j | halt_error(1))
            | if type == "array" and length > 0 then .
              else ("-P takes a non-empty JSON array, like [5] or [\"a\", \"b\"]: " + $j
                    | halt_error(1)) end' 2>&1) || fail "$PK_JSON"
    fi
    config_quote "$PK_JSON"
    PK_LINE="header = \"x-ms-documentdb-partitionkey: $REPLY\""
fi

# The query goes into jq on stdin, never as an argument, and the body jq builds is
# reused by every page. The first tojson makes the body and the second quotes it for
# the config block. Compact JSON holds no raw control character, so the only escapes
# the second can emit are \" and \\, and curl's config parser undoes exactly those.
BODY_LINE=""
if [[ "$POINT_READ" -eq 0 ]]; then
    BODY_LINE=$("${JQ[@]}" -Rrs '{query: rtrimstr("\n"), parameters: []}
        | "data-binary = \(tojson | tojson)"' <<<"$QUERY")
fi

# --- Resolve, then read -------------------------------------------------------
resolve_database
url_segment "$DB_NAME"
DB_PATH="$REPLY"

if [[ -z "$CONTAINER" ]]; then
    list_containers
    if [[ ${#CONTAINER_ROWS[@]} -eq 0 ]]; then
        fail "$DB_NAME has no containers"
    fi
    if [[ ${#CONTAINER_ROWS[@]} -gt 1 ]]; then
        echo "error: $DB_NAME has ${#CONTAINER_ROWS[@]} containers; pick one with -c:" >&2
        printf '         %s\n' "${CONTAINER_ROWS[@]%%$'\t'*}" >&2
        exit 1
    fi
    CONTAINER="${CONTAINER_ROWS[0]%%$'\t'*}"
fi
url_segment "$CONTAINER"
CONTAINER_PATH="$REPLY"

if [[ "$POINT_READ" -eq 1 ]]; then
    url_segment "$ITEM_ID"
    cosmos_call GET "dbs/$DB_PATH/colls/$CONTAINER_PATH/docs/$REPLY" "$PK_LINE"
    if [[ "$RESP_STATUS" != 2?? ]]; then
        cosmos_error "reading item '$ITEM_ID' with partition key $PK_JSON from $CONTAINER"
        if [[ "$RESP_STATUS" == 404 ]]; then
            echo "hint: -p sends the key as a string; a number, a boolean or a hierarchical key needs -P, and -l shows each container's key" >&2
        fi
        exit 1
    fi
    add_charge "$RESP_CHARGE"
    ITEMS=1
    PAGES=1
    if [[ "$RAW" -eq 1 ]]; then
        printf '%s\n' "$RESP_BODY"
    else
        emit_page "{\"Documents\":[$RESP_BODY]}" 1
    fi
elif [[ -n "$PK_LINE" ]]; then
    run_query "$PK_LINE"
    if [[ "$REFUSED" -eq 1 ]]; then
        # A full key is one partition, which the gateway always serves, so this is a
        # hierarchical key's prefix spanning several. A range would drop the key.
        echo "error: the gateway cannot serve this query even within partition key $PK_JSON," >&2
        echo "       which must be a prefix of a hierarchical key spanning several partitions" >&2
        echo "hint: give the full key with -P, or run it on the SQL analytics endpoint with sql.sh" >&2
        exit 1
    fi
else
    run_query "$CROSS_LINE"
    if [[ "$REFUSED" -eq 1 ]]; then
        cosmos_call GET "dbs/$DB_PATH/colls/$CONTAINER_PATH/pkranges" ""
        if [[ "$RESP_STATUS" != 2?? ]]; then
            cosmos_error "reading the partition key ranges of $CONTAINER"
            exit 1
        fi
        add_charge "$RESP_CHARGE"
        mapfile -t RANGES < <("${JQ[@]}" -r '.PartitionKeyRanges[]?.id' <<<"$RESP_BODY")
        if [[ ${#RANGES[@]} -ne 1 || -n "$RESP_CONT" ]]; then
            {
                echo "error: the gateway cannot serve this query across partitions (TOP, ORDER BY,"
                echo "       OFFSET LIMIT, aggregates, DISTINCT and GROUP BY need a client to merge"
                echo "       per-range results), and $CONTAINER has ${#RANGES[@]}${RESP_CONT:++} partition key ranges."
                echo "       This script does not merge them: TOP would overrun its limit, and an AVG"
                echo "       or a GROUP BY would not add up."
                echo "hint: scope the query to one partition key value with -p (or -P), or run it on"
                echo "      the item's SQL analytics endpoint with sql.sh: database $DB_NAME, table"
                echo "      [$DB_NAME].[$CONTAINER]"
            } >&2
            exit 1
        fi
        echo "note: the gateway cannot serve this query across partitions, but $CONTAINER has one partition key range, which is the whole container: running it on range ${RANGES[0]}" >&2
        config_quote "${RANGES[0]}"
        run_query "$CROSS_LINE"$'\n'"header = \"x-ms-documentdb-partitionkeyrangeid: $REPLY\""
        if [[ "$REFUSED" -eq 1 ]]; then
            fail "the gateway refused the query on range ${RANGES[0]} as well"
        fi
    fi
fi

# -t: the header row is every key in first-seen order across the rows, as dax.sh
# builds it; nested values print as compact JSON. A projection of bare values
# (SELECT VALUE ...) makes a single "value" column.
if [[ "$TABLE" -eq 1 && "$ITEMS" -gt 0 ]]; then
    printf '%s\n' "${TABLE_PAGES[@]}" | "${JQ[@]}" -rs '
        def cell: if . == null then "" elif type == "string" then . else tojson end;
        [.[].Documents[]] as $rows
        | if all($rows[]; type == "object") then
            (reduce ($rows[] | keys_unsorted[]) as $k
                ([]; if index($k) then . else . + [$k] end)) as $cols
            | ($cols | @tsv),
              ($cols | map("-" * (length + 2)) | @tsv),
              ($rows[] | . as $r | $cols | map($r[.] | cell) | @tsv)
          else
            "value", "-------", ($rows[] | cell)
          end
    ' | column -t -s $'\t'
fi

ru_total
SUMMARY="$ITEMS item(s)"
if [[ "$PAGES" -gt 1 ]]; then SUMMARY+=" in $PAGES pages"; fi
SUMMARY+=", $REPLY RU"
if [[ "$CAPPED" -eq 1 ]]; then
    SUMMARY+=" — stopped at -n $MAX_ITEMS; the query has more pages (-n 0 reads them all)"
fi
echo "$SUMMARY" >&2
