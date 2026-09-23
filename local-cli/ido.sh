#!/usr/bin/env bash
# Read-only probe against an Infor CloudSuite Industrial (Syteline) IDO through the ION
# REST API — the read half of a metadata-driven ingest notebook, runnable from a shell.
#
# It exists because an ingestion notebook's read side has no interactive equivalent: every
# question about what the ERP actually returns ("does this IDO expose that property", "what
# shape is that date", "does the filter match anything") otherwise costs an edit, a run, and
# a log read. This asks the source directly, in seconds, and changes nothing — the only
# verbs are OAuth token and IDO load.
#
# THE REQUEST IS THE REGISTRATION'S, BY DEFAULT. With no -p/-f/-o, the properties, filter
# and orderBy come from the entity's row in `ingest.Control` — the same control table
# integration/nb_syteline_ingest.ipynb reads, queried live rather than from a copy. So a
# bare `ido.sh <Entity>` is the production read request with a small recordCap, and a
# registration that has drifted from the live IDO fails here the way it would fail the run.
# Being live, it answers "what will a run in this environment send", not "what does the
# source-controlled registration say" — a stage whose row predates the latest registration
# edit shows the old request, which is the drift a live read is for.
# Overriding any of the three is for exploring, not for reproducing.
#
# The properties are derived from the FieldMap's SOURCES, not its field list: the set asked
# of the IDO is the sorted, deduplicated `Name` across every `P(Name)`, so a field built
# only from literals adds a column and asks the ERP for nothing. A malformed source is
# silently a literal — `P(Item` or a bare `Item` is an error nowhere, and the column then
# carries that text on every row while the property is never requested. `-r` is how you see
# what actually came back.
#
# A REJECTED LOAD ANSWERS HTTP 200. Mongoose reports a bad property, a malformed filter and
# an unknown IDO alike as 200 with Items null and the reason in Message. Asking for a
# property the IDO does not expose is the usual trigger. This script treats that as an
# error and prints the ERP's own Message; -c then finds which property did it, by adding
# them back one at a time until the load flips.
#
# THE RESPONSE CARRIES MORE THAN IT WAS ASKED FOR. Rows can come back with properties that
# appear in no FieldMap — an `_ItemId` is the common one. The table below shows the
# requested columns only; -r shows what actually arrived. A notebook reading the P(...)
# sources and nothing else never notices, but it surprises anyone diffing a raw response
# against a registration.
#
# NO CREDENTIAL GOES ON A COMMAND LINE. Argv is world-readable — on Windows an unelevated
# `Get-CimInstance Win32_Process` returns the full command line of a process it did not
# spawn, bearer and all; `ps` is the same story elsewhere. So every secret reaches its child
# on stdin: the token body via `--data @-`, the ION bearer via a `--config -` block, and
# urlencode feeds jq on stdin rather than through --arg. None of them touches a temp file,
# and the token variables are unset as soon as they are spent.
#
# EVERY CALL IS PINNED TO HTTPS. `--proto '=https'` on both requests, and -L is deliberately
# absent: a mistyped ION_TOKEN_URL must fail rather than put four secrets on the wire in
# cleartext, and a redirect must not be able to replay the bearer to another host.
#
# WATERMARKS ARE SERVER-LOCAL. Syteline stamps its change timestamps in the ERP server's own
# timezone, not UTC, so -w converts before it builds the filter clause — without that the
# window sits hours away from the data and matches nothing. SYTELINE_TIMEZONE is REQUIRED
# and has no default: a wrong guess produces a filter that looks right and is silently
# hours off, which is worse than a missing-key error. The conversion runs in Python, not
# `date`: a Windows box has no IANA tzdata, so `TZ=America/... date` silently returns GMT
# and would produce exactly that wrong-but-plausible filter. Only -w pays that cost; every
# other path is curl and jq.
#
# WHAT -E SELECTS, AND WHAT IT DOES NOT. -E/-e pick which SQL endpoint the REGISTRATION is
# read from, nothing more. There is typically one ION tenant behind every Fabric stage, so
# the rows this returns come from the same ERP whichever environment is active — -E changes
# where the request is looked up, never which system is asked. Registrations should be
# identical across stages anyway (LastWatermark is the only per-stage column, and this
# script does not read it), so the flag usually only matters when one stage is mid-rollout.
#
# .env keys:
#   ION_API_BASE            .ionapi "iu" — https://mingle-ionapi.inforcloudsuite.com
#   ION_TENANT              .ionapi "ti" — the ION tenant id
#   ION_TOKEN_URL           .ionapi "pu" + "ot". Optional: derived from ION_SSO_BASE
#                           (default https://mingle-sso.inforcloudsuite.com) plus
#                           ION_TENANT when unset.
#   ION_IDO_SUITE           suite segment of the IDO URL. Optional, defaults to CSI.
#   ION_MONGOOSE_CONFIG     sent as X-Infor-MongooseConfig on every call. Mongoose
#                           rejects the request without it.
#   KEY_VAULT_URI           vault holding the four ION secrets (names fixed below —
#                           they are the .ionapi field names, and the notebook reads
#                           the same four)
#   SYTELINE_TIMEZONE       REQUIRED for -w. IANA zone the ERP stamps change timestamps
#                           in, e.g. America/Chicago. No default on purpose — see above.
#   IDO_CONTROL_ENDPOINT    which SQL_ENDPOINT_<NAME> holds ingest.Control. Optional,
#                           falls back to SQL_ENDPOINT_DEFAULT. -e overrides both.
#   IDO_CONTROL_SYSTEM      SourceSystemName to match in ingest.Control. Optional,
#                           defaults to Syteline-ION (the notebook's SOURCE_SYSTEM).
#   IDO_PYTHON              python interpreter for the -w timezone conversion. Optional,
#                           defaults to whichever of python3, python actually runs. On
#                           Windows use "uv run --no-project --with tzdata python":
#                           Windows has no IANA data, so plain "uv run python" raises
#                           ZoneInfoNotFoundError without the tzdata package.
#   AZURE_TENANT_ID         optional — passed to `az login` when set
#
# Plus the SQL_ENDPOINT_<NAME> / ENV_DEFAULT entries sql.sh already documents: the control
# lookup shells out to sql.sh so there is one reader of that convention, not two.
#
# Usage (<Entity> is the SourceObjectName / IDO name, e.g. the value -l prints):
#   scripts/data/ido.sh <Entity>                       # the registration's request, 5 rows
#   scripts/data/ido.sh -n 50 <Entity>                 # 50 rows
#   scripts/data/ido.sh -w 7 <Entity>                  # rows changed in the last 7 days
#   scripts/data/ido.sh -p <PropA>,<PropB> <Entity>    # explicit properties
#   scripts/data/ido.sh -f "<Prop> = '<Value>'" <Entity>   # explicit filter
#   scripts/data/ido.sh -c <Entity>                    # which property is the IDO rejecting?
#   scripts/data/ido.sh -r <Entity> | jq '.Items[0]'   # raw response, for piping
#   scripts/data/ido.sh -l                             # list registered entities
#   scripts/data/ido.sh -E prod <Entity>               # read the registration from prod
#
# An entity needs no registration when every part is given: -p is the only required one, so
# an IDO that is not registered yet is probed with
#   scripts/data/ido.sh -p RowPointer,RecordDate <NewIdoName>
#
# Deployment assumption: this script lives at <repo>/scripts/data/ido.sh so
# SCRIPT_DIR/../.. resolves to the repo root holding .env, and sql.sh sits beside it.

set -euo pipefail

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
SQL_SH="$SCRIPT_DIR/sql.sh"

DEFAULT_SSO_BASE="https://mingle-sso.inforcloudsuite.com"
DEFAULT_SUITE="CSI"
DEFAULT_CONTROL_SYSTEM="Syteline-ION"
CONTROL_TABLE="ingest.Control"
# Secret names in the vault. Fixed rather than configurable: they are the .ionapi field
# names, and the ingest notebook hardcodes the same four.
SECRET_CLIENT_ID="ion-client-id"
SECRET_CLIENT_SECRET="ion-client-secret"
SECRET_SAAK="ion-saak"
SECRET_SASK="ion-sask"

# The .env check deliberately waits until after argument parsing, below: -h is most often
# reached in a clone that has no .env yet, and help that refuses to print because
# configuration is missing is help you cannot use.

# Extract values without sourcing (.env may contain entries bash would choke on).
# `|| true` is load-bearing: under `set -o pipefail` a grep that matches nothing fails the
# pipeline, so a missing key would abort before the explicit check could report it.
env_value() {
    { grep -E "^$1=" "$ENV_FILE" || true; } | head -n 1 | cut -d '=' -f 2- | tr -d '\r'
}

# Resolve a key through the active environment first (<ENV>_<KEY>), then bare — the same
# precedence sql.sh uses, so one .env serves both scripts.
cfg_value() {
    if [[ -n "${ENVNAME:-}" ]]; then
        local v
        v=$(env_value "${ENVNAME}_$1")
        if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    fi
    env_value "$1"
}

# The value arrives on stdin rather than through --arg: every caller below passes a vault
# secret, and an argument would put it in this machine's process list for the life of the
# call. -R reads it raw, -s slurps the whole stream as one string so a value containing a
# newline still encodes as a single value, and the output is byte-identical to --arg's.
urlencode() { printf '%s' "$1" | jq -Rrs '@uri'; }

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

# --- Azure CLI login preflight ------------------------------------------------
# Same shape as sql.sh, but the audience is Key Vault: this script's own calls go to ION
# with an ION bearer, and Azure auth is only how the ION credentials are fetched. (The
# control lookup needs a TDS token too, but sql.sh does its own preflight for that.)
#
# Escape hatch: SKIP_AZ_LOGIN=1 suppresses the prompt (CI, or when the underlying tool's
# own error is what you want to see).
ensure_az_login() {
    local resource="$1"
    local scope="${resource%/}/.default"

    if ! command -v az >/dev/null 2>&1; then
        echo "error: az not found on PATH" >&2
        echo "hint: winget install Microsoft.AzureCLI" >&2
        exit 1
    fi

    # Probe the exact audience rather than calling `az account show`: under Conditional
    # Access the session can be valid while still unable to mint a token for this
    # resource, and only the former would be caught.
    if az account get-access-token --resource "$resource" -o none 2>/dev/null; then
        return 0
    fi

    if [[ "${SKIP_AZ_LOGIN:-0}" == "1" ]]; then
        echo "warning: no Azure CLI token for $resource, and SKIP_AZ_LOGIN=1" >&2
        return 0
    fi

    local tenant="${AZURE_TENANT_ID:-}"
    if [[ -z "$tenant" ]]; then
        tenant=$(env_value AZURE_TENANT_ID)
    fi
    local tenant_args=()
    if [[ -n "$tenant" ]]; then
        tenant_args=(--tenant "$tenant")
    fi

    echo "note: no Azure CLI token for $resource — starting interactive login" >&2
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

get_secret() {
    local name="$1" value
    value=$(az keyvault secret show --id "${KEY_VAULT_URI%/}/secrets/$name" \
                --query value -o tsv 2>/dev/null) || true
    if [[ -z "$value" ]]; then
        echo "error: could not read secret '$name' from $KEY_VAULT_URI" >&2
        echo "       check the vault URI, the secret name, and your access policy" >&2
        exit 1
    fi
    printf '%s' "$value"
}

# --- Argument parsing ---------------------------------------------------------
ENTITY=""
ENDPOINT=""
ENVNAME=""
PROPERTIES=""
FILTER=""
ORDER_BY=""
RECORD_CAP=5
WINDOW_DAYS=""
RAW=0
LIST=0
BISECT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -e) ENDPOINT="$2"; shift 2 ;;
        -E) ENVNAME="$2"; shift 2 ;;
        -p) PROPERTIES="$2"; shift 2 ;;
        -f) FILTER="$2"; shift 2 ;;
        -o) ORDER_BY="$2"; shift 2 ;;
        -n) RECORD_CAP="$2"; shift 2 ;;
        -w) WINDOW_DAYS="$2"; shift 2 ;;
        -r) RAW=1; shift ;;
        -l) LIST=1; shift ;;
        -c) BISECT=1; shift ;;
        -*) echo "error: unknown flag '$1' (try -h)" >&2; exit 1 ;;
        *)  ENTITY="$1"; shift ;;
    esac
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: .env not found at $ENV_FILE" >&2
    echo "       this script expects to live at <repo>/scripts/data/ido.sh, so" >&2
    echo "       SCRIPT_DIR/../.. resolves to the repo root holding .env" >&2
    exit 1
fi

if [[ -z "$ENVNAME" ]]; then ENVNAME="${FAB_ENV:-}"; fi
if [[ -z "$ENVNAME" ]]; then ENVNAME=$(env_value ENV_DEFAULT); fi
ENVNAME="${ENVNAME^^}"

ION_API_BASE=$(cfg_value ION_API_BASE)
ION_TENANT=$(cfg_value ION_TENANT)
ION_TOKEN_URL=$(cfg_value ION_TOKEN_URL)
ION_IDO_SUITE=$(cfg_value ION_IDO_SUITE)
ION_MONGOOSE_CONFIG=$(cfg_value ION_MONGOOSE_CONFIG)
KEY_VAULT_URI=$(cfg_value KEY_VAULT_URI)
CONTROL_SYSTEM=$(cfg_value IDO_CONTROL_SYSTEM)
[[ -n "$ION_IDO_SUITE" ]]  || ION_IDO_SUITE="$DEFAULT_SUITE"
[[ -n "$CONTROL_SYSTEM" ]] || CONTROL_SYSTEM="$DEFAULT_CONTROL_SYSTEM"
if [[ -z "$ION_TOKEN_URL" ]]; then
    _sso=$(cfg_value ION_SSO_BASE)
    [[ -n "$_sso" ]] || _sso="$DEFAULT_SSO_BASE"
    ION_TOKEN_URL="${_sso%/}/$ION_TENANT/as/token.oauth2"
fi

for required in ION_API_BASE ION_TENANT ION_MONGOOSE_CONFIG KEY_VAULT_URI; do
    if [[ -z "${!required}" ]]; then
        echo "error: $required is not set in $ENV_FILE" >&2
        exit 1
    fi
done

# --- Control-table lookup -----------------------------------------------------
# Shells out to sql.sh so the SQL_ENDPOINT_<NAME> convention has exactly one reader.
#
# The registration comes back as one JSON_OBJECT scalar per row, not FOR JSON: Fabric
# Warehouse refuses FOR XML outright and FOR JSON anywhere but the outermost operator, and
# a top-level FOR JSON arrives split into chunks. JSON escapes every control character, so
# each row is exactly one line. The flags each close a silent failure, all measured
# against a Fabric Warehouse with go-sqlcmd:
#   -y 0  sqlcmd otherwise truncates (max) columns to 256 characters, without warning.
#   -r1   Fabric sends a "Statement ID: ... | Query hash: ..." info message with every
#         query touching a table; without -r1 it lands on stdout, mixed into the data.
#   -b    without it a SQL error exits 0 with the message on stdout, where it reads as
#         data. With it the query exits 1, stdout stays empty, and the message is on
#         stderr.
# -w 65535 is the line width; a row longer than that would wrap, which no FieldMap
# approaches.
control_query() {
    local sql="$1" endpoint_args=()
    if [[ ! -x "$SQL_SH" ]]; then
        echo "error: $SQL_SH not found or not executable" >&2
        echo "       ido.sh reads the registration through sql.sh; copy both, or pass" >&2
        echo "       -p/-f/-o to skip the control lookup entirely." >&2
        exit 1
    fi
    local name="$ENDPOINT"
    [[ -n "$name" ]] || name=$(cfg_value IDO_CONTROL_ENDPOINT)
    [[ -z "$name" ]] || endpoint_args=(-e "$name")
    [[ -z "$ENVNAME" ]] || endpoint_args+=(-E "$ENVNAME")
    "$SQL_SH" ${endpoint_args+"${endpoint_args[@]}"} \
        -h -1 -W -w 65535 -y 0 -r1 -b -Q "SET NOCOUNT ON; $sql"
}

sql_string() { printf "'%s'" "${1//\'/\'\'}"; }

# A failed query and a missing row are told apart by exit status, not by output: -b makes
# the first exit non-zero, and the second exits 0 with no JSON line.
load_registration() {
    local entity="$1" out row
    out=$(control_query "
        SELECT TOP 1 JSON_OBJECT(
              'SourceWatermark': SourceWatermark
            , 'SourceOrderBy': SourceOrderBy
            , 'SourceFilter': SourceFilter
            , 'FieldMap': FieldMap)
        FROM $CONTROL_TABLE
        WHERE SourceSystemName = $(sql_string "$CONTROL_SYSTEM")
          AND SourceObjectName = $(sql_string "$entity");") || {
        echo "error: the control-table lookup failed (the cause is printed above)" >&2
        exit 1
    }
    row=$({ grep -m1 '^{' <<<"$out" || true; } | tr -d '\r')
    if [[ -z "$row" ]]; then
        echo "error: no row in $CONTROL_TABLE for SourceObjectName '$entity'" >&2
        echo "       (SourceSystemName '$CONTROL_SYSTEM'). Register it, pick another" >&2
        echo "       endpoint with -e, or pass -p to probe an unregistered IDO." >&2
        exit 1
    fi
    printf '%s' "$row"
}

# The properties asked of the IDO are the sorted, deduplicated set of Name across every
# P(Name) in the FieldMap — the field list itself is not the request. A source that is not
# shaped P(...) is a literal and contributes no property.
properties_from_field_map() {
    jq -r '
        (.FieldMap | fromjson)
        | map(.Sources // [])
        | flatten
        | map(select(type == "string" and startswith("P(") and endswith(")")))
        | map(.[2:-1])
        | unique
        | join(",")
    '
}

if [[ "$LIST" -eq 1 ]]; then
    echo "entities registered in $CONTROL_TABLE (SourceSystemName '$CONTROL_SYSTEM'," \
         "environment ${ENVNAME:-none}):"
    control_query "
        SELECT SourceObjectName + '  ' + CASE WHEN IsActive = 1 THEN 'active' ELSE 'inactive' END
        FROM $CONTROL_TABLE
        WHERE SourceSystemName = $(sql_string "$CONTROL_SYSTEM")
        ORDER BY SourceObjectName;" \
        | sed '/^$/d; s/^/  /'
    exit 0
fi

if [[ -z "$ENTITY" ]]; then
    echo "error: no entity given (try -h)" >&2
    exit 1
fi

# --- Resolve the request ------------------------------------------------------
# The registration is read unless -p makes it unnecessary: -p alone fully specifies an
# unregistered IDO, so that is the one case with no control lookup at all. -w still forces
# the lookup even with -p, because the window clause needs the registered SourceWatermark.
# Whatever was passed explicitly wins over whatever comes back.
WATERMARK_PROPERTY=""
if [[ -z "$PROPERTIES" || -n "$WINDOW_DAYS" ]]; then
    REGISTRATION=$(load_registration "$ENTITY")
    [[ -n "$PROPERTIES" ]] || PROPERTIES=$(printf '%s' "$REGISTRATION" | properties_from_field_map)
    [[ -n "$FILTER" ]]     || FILTER=$(printf '%s' "$REGISTRATION" | jq -r '.SourceFilter // ""')
    [[ -n "$ORDER_BY" ]]   || ORDER_BY=$(printf '%s' "$REGISTRATION" | jq -r '.SourceOrderBy // ""')
    WATERMARK_PROPERTY=$(printf '%s' "$REGISTRATION" | jq -r '.SourceWatermark // ""')
fi

if [[ -z "$PROPERTIES" ]]; then
    echo "error: no properties resolved for '$ENTITY' — the registration's FieldMap has" >&2
    echo "       no P(...) sources, or -p was needed and not given" >&2
    exit 1
fi

# --- The -w window ------------------------------------------------------------
# Converted in Python because a Windows box has no IANA tzdata and `TZ=<zone> date` would
# silently answer in GMT — a filter that looks right and is hours wrong.
if [[ -n "$WINDOW_DAYS" ]]; then
    if [[ -z "$WATERMARK_PROPERTY" ]]; then
        echo "error: -w needs the registration's SourceWatermark, which was not resolved" >&2
        echo "       (an unregistered IDO takes an explicit -f instead)" >&2
        exit 1
    fi
    SYTELINE_TIMEZONE=$(cfg_value SYTELINE_TIMEZONE)
    if [[ -z "$SYTELINE_TIMEZONE" ]]; then
        echo "error: -w needs SYTELINE_TIMEZONE in $ENV_FILE — the IANA zone the ERP" >&2
        echo "       stamps its change timestamps in, e.g. America/Chicago." >&2
        echo "       There is deliberately no default: a wrong guess produces a filter" >&2
        echo "       that looks correct and silently matches the wrong window." >&2
        exit 1
    fi
    # `command -v` alone is not a test here: on Windows, python3 and python resolve to
    # Store alias stubs that exit 49 when given arguments. So a candidate has to run.
    PY=$(cfg_value IDO_PYTHON)
    if [[ -z "$PY" ]]; then
        for candidate in python3 python; do
            if "$candidate" -c '' >/dev/null 2>&1; then PY="$candidate"; break; fi
        done
    fi
    if [[ -z "$PY" ]]; then
        echo "error: -w needs a python interpreter for the timezone conversion." >&2
        echo "       Set IDO_PYTHON in $ENV_FILE, e.g." >&2
        echo "       IDO_PYTHON=uv run --no-project --with tzdata python" >&2
        exit 1
    fi
    WINDOW_START=$($PY -c '
import sys
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
days, zone = float(sys.argv[1]), sys.argv[2]
try:
    tz = ZoneInfo(zone)
except Exception:
    sys.exit(f"error: unknown timezone {zone!r} - no IANA tzdata? run python with the tzdata package")
cutoff = datetime.now(timezone.utc) - timedelta(days=days)
print(cutoff.astimezone(tz).strftime("%Y-%m-%d %H:%M:%S"))
' "$WINDOW_DAYS" "$SYTELINE_TIMEZONE") || exit 1
    WINDOW_CLAUSE="$WATERMARK_PROPERTY >= '$WINDOW_START'"
    if [[ -n "$FILTER" ]]; then
        FILTER="($WINDOW_CLAUSE) AND ($FILTER)"
    else
        FILTER="$WINDOW_CLAUSE"
    fi
fi

# --- ION token ----------------------------------------------------------------
ensure_az_login "https://vault.azure.net"

TOKEN_BODY="grant_type=password"
TOKEN_BODY+="&username=$(urlencode "$(get_secret "$SECRET_SAAK")")"
TOKEN_BODY+="&password=$(urlencode "$(get_secret "$SECRET_SASK")")"
TOKEN_BODY+="&client_id=$(urlencode "$(get_secret "$SECRET_CLIENT_ID")")"
TOKEN_BODY+="&client_secret=$(urlencode "$(get_secret "$SECRET_CLIENT_SECRET")")"

# --data @- keeps the four secrets off the command line. --proto '=https' and the absent
# -L keep them off the wire in cleartext if the URL is wrong.
TOKEN_RESPONSE=$(printf '%s' "$TOKEN_BODY" | curl -sS --proto '=https' \
    -X POST "$ION_TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data @-) || {
        echo "error: ION token request failed" >&2
        exit 1
    }
unset TOKEN_BODY

ION_TOKEN=$(printf '%s' "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$ION_TOKEN" ]]; then
    echo "error: ION token response carried no access_token:" >&2
    printf '%s\n' "$TOKEN_RESPONSE" | head -c 400 >&2
    echo >&2
    exit 1
fi
unset TOKEN_RESPONSE

# --- The IDO load -------------------------------------------------------------
IDO_URL="${ION_API_BASE%/}/$ION_TENANT/$ION_IDO_SUITE/IDORequestService/ido/load/$ENTITY"

# The bearer travels in a --config block on stdin, never in argv. curl reads `header =
# "..."` from the file it is told to read, and `-` is stdin.
ido_load() {
    local properties="$1" cap="$2" response url
    url="$IDO_URL?properties=$(urlencode "$properties")&recordCap=$cap&loadType=NEXT"
    [[ -z "$FILTER" ]]   || url+="&filter=$(urlencode "$FILTER")"
    [[ -z "$ORDER_BY" ]] || url+="&orderBy=$(urlencode "$ORDER_BY")"
    response=$(printf 'header = "Authorization: Bearer %s"\n' "$ION_TOKEN" \
        | curl -sS --proto '=https' --config - \
            -H "X-Infor-MongooseConfig: $ION_MONGOOSE_CONFIG" \
            -H 'Accept: application/json' \
            "$url") || return 1
    printf '%s' "$response"
}

# Mongoose answers 200 for a rejected load, with Items null and the reason in Message, so
# the status code cannot be the test. This is.
load_rejected() {
    [[ "$(printf '%s' "$1" | jq -r 'if (.Items == null) then "yes" else "no" end')" == "yes" ]]
}

if [[ "$BISECT" -eq 1 ]]; then
    # Grow the property list one at a time and stop at the first addition that flips the
    # load from accepted to rejected — that property is the offender. A linear scan rather
    # than a true bisection: the lists are a dozen or so properties, each probe is a
    # network round trip, and a scan reports the offender by name instead of a surviving
    # subset. Each probe is a real load with recordCap 1, the cheapest request that still
    # makes the ERP parse the property list.
    echo "narrowing ${ENTITY}'s property list to the rejected property..." >&2
    IFS=',' read -r -a ALL_PROPS <<< "$PROPERTIES"
    if ! load_rejected "$(ido_load "$PROPERTIES" 1)"; then
        echo "the full property list loads cleanly — nothing to narrow" >&2
        exit 0
    fi
    GOOD=()
    for prop in "${ALL_PROPS[@]}"; do
        if [[ ${#GOOD[@]} -eq 0 ]]; then
            CANDIDATE="$prop"
        else
            CANDIDATE="$(IFS=','; printf '%s' "${GOOD[*]}"),$prop"
        fi
        PROBE=$(ido_load "$CANDIDATE" 1)
        if load_rejected "$PROBE"; then
            echo >&2
            echo "rejected property: $prop" >&2
            printf '%s' "$PROBE" | jq -r '.Message // "(no Message)"' >&2
            exit 1
        fi
        GOOD+=("$prop")
        printf '.' >&2
    done
    echo >&2
    echo "no single property reproduces the rejection — the filter or orderBy is the" >&2
    echo "likelier cause. Re-run without -c to see the ERP's Message." >&2
    exit 1
fi

RESPONSE=$(ido_load "$PROPERTIES" "$RECORD_CAP") || {
    echo "error: IDO load request failed" >&2
    exit 1
}

if load_rejected "$RESPONSE"; then
    echo "error: the IDO rejected this load (HTTP 200, Items null):" >&2
    printf '%s' "$RESPONSE" | jq -r '.Message // "(no Message in the response)"' >&2
    echo >&2
    echo "hint: -c bisects the property list to find which property did it." >&2
    exit 1
fi

if [[ "$RAW" -eq 1 ]]; then
    printf '%s\n' "$RESPONSE"
    exit 0
fi

# Columns are the requested properties, in the order asked. The response can carry more
# keys than that (see the header); -r is how you see them.
printf '%s' "$RESPONSE" | jq -r --arg props "$PROPERTIES" '
    ($props | split(",")) as $cols
    | ($cols | @tsv),
      (.Items[]? | [ $cols[] as $c | (.[$c] // "") | tostring ] | @tsv)
' | column -t -s "$(printf '\t')"

ROW_COUNT=$(printf '%s' "$RESPONSE" | jq -r '.Items | length')
MORE=$(printf '%s' "$RESPONSE" | jq -r 'if .MoreRowsExist then " (more rows exist)" else "" end')
echo >&2
echo "$ROW_COUNT row(s)$MORE — recordCap $RECORD_CAP" >&2
