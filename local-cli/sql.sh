#!/usr/bin/env bash
# Wrapper around modern `sqlcmd` for any AAD-authenticated T-SQL endpoint —
# Fabric Warehouse, Fabric Lakehouse SQL analytics endpoint, Fabric SQL
# Database, Azure SQL Database / Managed Instance, Synapse dedicated pool.
# Authenticates with the Azure CLI token, and runs `az login` for you if the
# cached session cannot mint one (see "Azure CLI login preflight" below).
#
# ONE SCRIPT, NOT ONE PER ENDPOINT TYPE. A Fabric workspace exposes a single
# SQL host, and the "database" is just the item display name — the same host
# serves the Warehouse and the Lakehouse SQL endpoint. So a separate warehouse
# script would be this file with a different -d, and you would still want a
# third one the day you query the lakehouse endpoint. lake.sh and kql.sh are
# separate because they drive genuinely different tools (duckdb, curl+jq);
# everything reachable by sqlcmd belongs here.
#
# .env configuration — one entry per endpoint, name it whatever you like:
#
#   SQL_ENDPOINT_<NAME>=<host>[/<database>]        # bare host, Fabric style
#   SQL_ENDPOINT_<NAME>=<ADO.NET connection string> # Server=...;Initial Catalog=...;
#   SQL_ENDPOINT_DEFAULT=<NAME>                     # which one -e defaults to
#
# Both value shapes are accepted because the portal hands out both: Fabric
# Warehouse gives a bare host with no database (the database is the item name,
# which the portal never puts in the string), while Fabric SQL Database and
# Azure SQL give a full ADO.NET string. Normalising by hand is exactly the step
# that gets skipped, so the script does it.
#
#   SQL_ENDPOINT_WAREHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<WarehouseName>
#   SQL_ENDPOINT_LAKEHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<LakehouseName>
#   SQL_ENDPOINT_DATABASE=Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;
#   SQL_ENDPOINT_DEFAULT=WAREHOUSE
#
# Multi-environment repos prefix any key with an environment name (alnum, no
# underscore) and pick the environment per run with -E, the FAB_ENV variable,
# or ENV_DEFAULT in .env. Lookup is <ENV>_<KEY> first, bare <KEY> as fallback,
# so keys whose value is the same in every environment stay unprefixed:
#
#   SANDBOX_SQL_ENDPOINT_WAREHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<WarehouseName>
#   PROD_SQL_ENDPOINT_WAREHOUSE=<yyy>.datawarehouse.fabric.microsoft.com/<WarehouseName>
#   ENV_DEFAULT=SANDBOX                     # environment when -E isn't passed
#
# Optional .env key:
#   AZURE_TENANT_ID=<tenant-id-or-domain>   # passed to `az login` when set
#
# Usage:
#   scripts/data/sql.sh -Q "SELECT TOP 5 * FROM <schema>.<Table>"   # default endpoint
#   scripts/data/sql.sh -e database -Q "SELECT 1"                   # named endpoint
#   scripts/data/sql.sh -E prod -Q "SELECT 1"                       # pick environment
#   scripts/data/sql.sh -d <LakehouseName> -Q "SELECT 1"            # same host, other item
#   scripts/data/sql.sh -i path/to/script.sql
#   echo "SELECT 1" | scripts/data/sql.sh
#   scripts/data/sql.sh -l                                          # list configured endpoints
#
# -e/-E/-d/-l are consumed here; every other flag passes straight to sqlcmd. -d
# keeps sqlcmd's own meaning (database), so there is nothing new to remember.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/sql.sh
# so SCRIPT_DIR/../.. resolves to the repo root containing .env.

set -euo pipefail

if ! command -v sqlcmd >/dev/null 2>&1; then
    echo "error: sqlcmd not found on PATH" >&2
    echo "hint: winget install Microsoft.Sqlcmd" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: .env not found at $ENV_FILE" >&2
    exit 1
fi

# Read values without sourcing — .env may hold entries bash would choke on.
# The `|| true` is required, not defensive: under `set -o pipefail` a grep that
# matches nothing fails the whole pipeline, so a simple "is this key absent?"
# lookup would abort the script under `set -e` before it could report anything.
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

list_endpoints() {
    # $1 = key prefix: "" for bare entries, "<ENV>_" for one environment's.
    grep -oE "^${1}SQL_ENDPOINT_[A-Za-z0-9_]+" "$ENV_FILE" 2>/dev/null \
        | sed "s/^${1}SQL_ENDPOINT_//" | grep -v '^DEFAULT$' || true
}

# Environment names are the alnum prefixes in front of SQL_ENDPOINT_ keys
# (SANDBOX_SQL_ENDPOINT_WAREHOUSE → SANDBOX). Underscores are not allowed in
# an environment name — the parse would be ambiguous.
list_env_prefixes() {
    grep -oE '^[A-Za-z0-9]+_SQL_ENDPOINT_[A-Za-z0-9_]+' "$ENV_FILE" 2>/dev/null \
        | sed -E 's/_SQL_ENDPOINT_.*$//' | sort -u || true
}

# --- Azure CLI login preflight ------------------------------------------------
# sqlcmd's ActiveDirectoryAzCli method shells out to the cached `az` session and
# reports a missing or expired one as a generic login failure, which is a dead
# end when the script is driven by a tool rather than typed by hand. Probing for
# the token first turns that into an actual login prompt.
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

ENDPOINT=""
DATABASE_OVERRIDE=""
ENVNAME=""
LIST=0
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e) ENDPOINT="$2"; shift 2 ;;
        -E) ENVNAME="$2"; shift 2 ;;
        -d) DATABASE_OVERRIDE="$2"; shift 2 ;;
        -l) LIST=1; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

# Active environment: -E flag, then FAB_ENV, then ENV_DEFAULT in .env. Optional —
# with none of the three set, only bare keys are read (single-environment mode).
if [[ -z "$ENVNAME" ]]; then ENVNAME="${FAB_ENV:-}"; fi
if [[ -z "$ENVNAME" ]]; then ENVNAME=$(env_value ENV_DEFAULT); fi
ENVNAME="${ENVNAME^^}"

if [[ "$LIST" -eq 1 ]]; then
    DEFAULT_NAME=$(cfg_value SQL_ENDPOINT_DEFAULT)
    echo "endpoints configured in $ENV_FILE (active environment: ${ENVNAME:-none}; * = default):"
    found=0
    print_group() {
        local prefix="" label="  (no environment)"
        if [[ -n "$1" ]]; then prefix="${1}_"; label="  environment $1:"; fi
        local names
        names=$(list_endpoints "$prefix")
        [[ -z "$names" ]] && return 0
        found=1
        echo "$label"
        while read -r name; do
            [[ -z "$name" ]] && continue
            marker="    "
            if [[ "${name^^}" == "${DEFAULT_NAME^^}" ]] \
                    && { [[ -z "$1" && -z "$ENVNAME" ]] || [[ "$1" == "$ENVNAME" ]]; }; then
                marker="  * "
            fi
            printf '%s%-14s %s\n' "$marker" "$name" "$(env_value "${prefix}SQL_ENDPOINT_$name")"
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

# Resolve which endpoint entry to use: -e, then SQL_ENDPOINT_DEFAULT, then the
# only one defined if there is exactly one (the common single-endpoint repo).
# The auto-pick scopes to the active environment so a multi-env .env with one
# endpoint per environment still needs no -e.
if [[ -z "$ENDPOINT" ]]; then
    ENDPOINT=$(cfg_value SQL_ENDPOINT_DEFAULT)
fi
if [[ -z "$ENDPOINT" ]]; then
    mapfile -t _names < <(list_endpoints "${ENVNAME:+${ENVNAME}_}")
    if [[ ${#_names[@]} -eq 0 && -n "$ENVNAME" ]]; then
        mapfile -t _names < <(list_endpoints "")
    fi
    if [[ ${#_names[@]} -eq 1 ]]; then
        ENDPOINT="${_names[0]}"
    fi
fi

CONN=""
if [[ -n "$ENDPOINT" ]]; then
    CONN=$(cfg_value "SQL_ENDPOINT_${ENDPOINT^^}")
    [[ -z "$CONN" ]] && CONN=$(cfg_value "SQL_ENDPOINT_${ENDPOINT}")
fi

# Legacy single-slot variable. Kept working so an existing .env is not a hard
# break, but it cannot name more than one endpoint — hence the nudge.
if [[ -z "$CONN" ]]; then
    CONN=$(env_value SQL_CONNECTION_STRING)
    if [[ -n "$CONN" ]]; then
        echo "note: using legacy SQL_CONNECTION_STRING. Rename it to" >&2
        echo "      SQL_ENDPOINT_<NAME> to configure more than one endpoint (-l lists them)." >&2
    fi
fi

if [[ -z "$CONN" ]]; then
    echo "error: no endpoint configured in $ENV_FILE" >&2
    if [[ -n "$ENDPOINT" ]]; then
        if [[ -n "$ENVNAME" ]]; then
            echo "       looked for ${ENVNAME}_SQL_ENDPOINT_${ENDPOINT^^}, then SQL_ENDPOINT_${ENDPOINT^^}" >&2
        else
            echo "       looked for SQL_ENDPOINT_${ENDPOINT^^}" >&2
        fi
    fi
    echo "       expected SQL_ENDPOINT_<NAME>=<host>[/<database>] or an ADO.NET string" >&2
    echo "       run with -l to list what is defined" >&2
    exit 1
fi

# Two accepted shapes. An ADO.NET string is detected by its Server= key rather
# than by guessing from punctuation — Fabric hosts contain dots and dashes and
# would defeat anything cleverer.
if grep -qiE '(^|;)[[:space:]]*Server[[:space:]]*=' <<<"$CONN"; then
    SERVER=$(grep -oiE '(^|;)[[:space:]]*Server[[:space:]]*=[^;]+' <<<"$CONN" | head -n1 | cut -d '=' -f2- | sed 's/^[[:space:]]*//')
    DATABASE=$(grep -oiE '(^|;)[[:space:]]*(Initial Catalog|Database)[[:space:]]*=[^;]+' <<<"$CONN" | head -n1 | cut -d '=' -f2- | sed 's/^[[:space:]]*//')
else
    SERVER="${CONN%%/*}"
    if [[ "$CONN" == */* ]]; then
        DATABASE="${CONN#*/}"
    else
        DATABASE=""
    fi
fi

[[ -n "$DATABASE_OVERRIDE" ]] && DATABASE="$DATABASE_OVERRIDE"

if [[ -z "$SERVER" ]]; then
    echo "error: could not determine a server from the endpoint value" >&2
    exit 1
fi
if [[ -z "$DATABASE" ]]; then
    # Fabric's Warehouse connection string genuinely omits this, and sqlcmd would
    # otherwise connect to master and fail on the first schema-qualified name.
    echo "error: no database for endpoint '${ENDPOINT:-<legacy>}'" >&2
    echo "       Fabric's copied connection string omits it — the database is the ITEM" >&2
    echo "       DISPLAY NAME (the Warehouse or Lakehouse name as shown in the workspace)." >&2
    echo "       Append it as <host>/<database> in .env, or pass -d <database>." >&2
    exit 1
fi

# Don't fight an explicit choice: only supply the default auth method if the
# caller has not passed one through. The chosen method is tracked separately
# because it decides whether the az preflight below applies at all — passing
# --authentication-method SqlPassword should not trigger an Azure login.
AUTH=(--authentication-method ActiveDirectoryAzCli)
AUTH_METHOD="ActiveDirectoryAzCli"
_want_method=0
for arg in ${ARGS+"${ARGS[@]}"}; do
    if [[ "$_want_method" -eq 1 ]]; then
        AUTH_METHOD="$arg"
        _want_method=0
        continue
    fi
    case "$arg" in
        --authentication-method=*) AUTH=(); AUTH_METHOD="${arg#*=}" ;;
        --authentication-method)   AUTH=(); _want_method=1 ;;
    esac
done

# Audience for TDS endpoints — Fabric Warehouse / SQL DB and Azure SQL all take
# the same one. See the token-audience table in the fabric-auth notes.
if [[ "${AUTH_METHOD,,}" == "activedirectoryazcli" ]]; then
    ensure_az_login "https://database.windows.net/"
fi

exec sqlcmd -S "$SERVER" -d "$DATABASE" ${AUTH+"${AUTH[@]}"} ${ARGS+"${ARGS[@]}"}
