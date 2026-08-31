#!/usr/bin/env bash
# Wrapper around the Power BI executeQueries REST API for running DAX against a
# published semantic model. Reads the workspace and default model from the repo's
# .env and authenticates with the Azure CLI token, running `az login` for you if
# the cached session cannot mint one (see "Azure CLI login preflight" below).
#
# WHY THIS AND NOT XMLA. XMLA is the full-fidelity path (MDX, DMVs, TMSL, no row
# caps), but clients never speak to it directly — they go through the MSOLAP /
# ADOMD client libraries, so a shell wrapper would need a .NET stack. DAX Studio
# and Tabular Editor already own that niche. executeQueries is plain HTTP against
# the same audience report-png.sh already uses, which is what makes this a
# curl+jq script like kql.sh instead of a second toolchain. The other rejected
# option, semantic link / SemPy (`fabric.evaluate_dax`), is documented as
# supported ONLY inside Microsoft Fabric notebooks — it is not a local tool.
#
# WHAT THIS IS FOR. Reading the model's own data while authoring it: checking a
# measure's actual value, a column's real scale and units, cardinality, blank
# behaviour. sql.sh / lake.sh / kql.sh read the SOURCE; this reads the model
# AFTER relationships, filters, calculated columns and measure logic have been
# applied, which is the number a report will actually show.
#
# .env keys:
#   PBI_WORKSPACE_ID      workspace (group) GUID — from the workspace URL:
#                         app.powerbi.com/groups/<GUID>/...  (shared with
#                         report-png.sh; define it once)
#   PBI_SEMANTIC_MODEL    optional — default model, display name or GUID.
#                         -m overrides it; with neither set, -l lists them.
#   AZURE_TENANT_ID       optional — passed to `az login` when set
#
# Multi-environment repos prefix the keys with an environment name (alnum, no
# underscore) and pick the environment per run with -E, the FAB_ENV variable,
# or ENV_DEFAULT in .env. Lookup is <ENV>_<KEY> first, bare <KEY> as fallback —
# deployment pipelines keep item display names identical across stages, so
# typically only the workspace GUID is prefixed and the model name stays bare:
#
#   SANDBOX_PBI_WORKSPACE_ID=<workspace-guid>
#   PROD_PBI_WORKSPACE_ID=<workspace-guid>
#   PBI_SEMANTIC_MODEL=<SemanticModelName>
#   ENV_DEFAULT=SANDBOX
#
# Usage:
#   scripts/data/dax.sh -q "EVALUATE TOPN ( 5, 'Sales' )"
#   scripts/data/dax.sh -i path/to/query.dax
#   echo "EVALUATE ROW ( \"Total\", [Total Sales] )" | scripts/data/dax.sh
#
#   # -m picks the model, -E the environment, -w another workspace:
#   scripts/data/dax.sh -m "Sales Model" -q "EVALUATE INFO.VIEW.TABLES()"
#   scripts/data/dax.sh -E prod -q "EVALUATE ROW ( \"n\", COUNTROWS ( 'Sales' ) )"
#   scripts/data/dax.sh -l                      # list models in the workspace
#
#   # -s runs a canned model-metadata query (see "Schema shortcuts" below):
#   scripts/data/dax.sh -s columns | grep -i amount
#   scripts/data/dax.sh -s measures
#
#   # -u impersonates a user so RLS can be tested while authoring roles:
#   scripts/data/dax.sh -u analyst@contoso.com -q "EVALUATE ROW ( \"n\", [Sales] )"
#
#   # -r emits the raw JSON response instead of a table, for piping to jq:
#   scripts/data/dax.sh -r -q "EVALUATE ROW ( \"n\", 1 )" | jq '.results[0].tables[0].rows'
#
# API limits worth knowing before a query surprises you (all documented on
# https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group):
#   - One query per call and ONE result table per query. `DEFINE MEASURE ...
#     EVALUATE ...` is fine; two EVALUATE statements are not.
#   - 100,000 rows OR 1,000,000 values, whichever is hit first, and 15 MB.
#     Exceeding these truncates and reports the error in a 200 response, which
#     is why the payload is inspected below and not just the status code.
#   - 120 requests per minute per user, across all models.
#   - Requires the tenant setting "Dataset Execute Queries REST API" (Integration
#     settings) plus Build permission on the model.
#   - Not supported for models hosted in, or live-connected to, Azure AS.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/dax.sh
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

# executeQueries lives on the Power BI REST surface, not the Fabric one — the
# audience below is NOT api.fabric.microsoft.com (using that yields a 401). It
# is the same audience report-png.sh uses, so one login covers both.
RESOURCE="https://analysis.windows.net/powerbi/api"
API="https://api.powerbi.com/v1.0/myorg"

# --- Schema shortcuts ---------------------------------------------------------
# Canned INFO.VIEW queries, projected down to the columns that matter when you
# are writing a measure and need to know what exists and how it is typed. The
# full INFO.VIEW.* tables carry 13-24 columns each, which is unreadable in a
# terminal — write your own DAX (or use -r) when you want the rest.
#
# DOC-VS-REALITY: the executeQueries reference states that INFO functions are
# not supported through this endpoint. That is stale — INFO.VIEW.* queries are
# accepted and return normally (verified against a Direct Lake model on a Fabric
# capacity). Do not "fix" -s back to a getDefinition/TMDL round trip on the
# strength of that sentence in the docs; test it first.
#
# The one real caveat: INFO functions require semantic model admin permissions,
# and INFO.VIEW.* blanks [Expression] for users without write permission on the
# model. A measures listing with empty formulas means read-only access, not an
# empty model.
schema_query() {
    case "${1,,}" in
        tables)
            cat <<'DAXEOF'
EVALUATE
SELECTCOLUMNS (
    INFO.VIEW.TABLES (),
    "Table", [Name],
    "Storage", [StorageMode],
    "Hidden", [IsHidden],
    "Category", [DataCategory],
    "Calc table DAX", [Expression],
    "Description", [Description]
)
ORDER BY [Table]
DAXEOF
            ;;
        columns)
            cat <<'DAXEOF'
EVALUATE
SELECTCOLUMNS (
    FILTER ( INFO.VIEW.COLUMNS (), [DataCategory] <> "RowNumber" ),
    "Table", [Table],
    "Column", [Name],
    "DataType", [DataType],
    "SummarizeBy", [SummarizeBy],
    "Hidden", [IsHidden],
    "FormatString", [FormatString],
    "Calc column DAX", [Expression],
    "Description", [Description]
)
ORDER BY [Table], [Column]
DAXEOF
            ;;
        measures)
            cat <<'DAXEOF'
EVALUATE
SELECTCOLUMNS (
    INFO.VIEW.MEASURES (),
    "Home table", [Table],
    "Measure", [Name],
    "DataType", [DataType],
    "FormatString", [FormatString],
    "Folder", [DisplayFolder],
    "Hidden", [IsHidden],
    "State", [State],
    "DAX", [Expression],
    "Description", [Description]
)
ORDER BY [Home table], [Measure]
DAXEOF
            ;;
        relationships)
            cat <<'DAXEOF'
EVALUATE
SELECTCOLUMNS (
    INFO.VIEW.RELATIONSHIPS (),
    "Relationship", [Relationship],
    "Active", [IsActive],
    "CrossFilter", [CrossFilteringBehavior],
    "SecurityFilter", [SecurityFilteringBehavior],
    "State", [State]
)
ORDER BY [Relationship]
DAXEOF
            ;;
        *)
            echo "error: unknown -s value '$1' (expected tables, columns, measures, or relationships)" >&2
            exit 1
            ;;
    esac
}

QUERY=""
MODEL=""
WORKSPACE=""
ENVNAME=""
IMPERSONATE=""
SCHEMA=""
RAW=0
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
        -m) MODEL="$2"; shift 2 ;;
        -w) WORKSPACE="$2"; shift 2 ;;
        -E) ENVNAME="$2"; shift 2 ;;
        -u) IMPERSONATE="$2"; shift 2 ;;
        -s) SCHEMA="$2"; shift 2 ;;
        -r) RAW=1; shift ;;
        -l) LIST=1; shift ;;
        -h|--help) shift ;;   # already handled above, before the .env check
        *) echo "error: unknown argument '$1' (expected -q, -i, -m, -w, -E, -u, -s, -r, -l, or stdin)" >&2; exit 1 ;;
    esac
done

# Active environment: -E flag, then FAB_ENV, then ENV_DEFAULT in .env. Optional —
# with none of the three set, only bare keys are read (single-environment mode).
if [[ -z "$ENVNAME" ]]; then ENVNAME="${FAB_ENV:-}"; fi
if [[ -z "$ENVNAME" ]]; then ENVNAME=$(env_value ENV_DEFAULT); fi
ENVNAME="${ENVNAME^^}"

if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE=$(cfg_value PBI_WORKSPACE_ID)
fi
if [[ -z "${WORKSPACE:-}" ]]; then
    echo "error: no workspace — set PBI_WORKSPACE_ID in $ENV_FILE or pass -w <guid>" >&2
    exit 1
fi

ensure_az_login "$RESOURCE"
TOKEN=$(az account get-access-token --resource "$RESOURCE" --query accessToken -o tsv)

# Every GET funnels through here so HTTP failures surface the API's own error
# payload (which names the real cause: capacity, tenant setting, permissions)
# instead of curl's silence.
pbi_get() {
    local url="$1" out http
    out=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
    http="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$http" != 2* ]]; then
        echo "error: GET $url returned HTTP $http" >&2
        jq -r '.error.message // .message // empty' <<<"$out" >&2 || true
        exit 1
    fi
    printf '%s' "$out"
}

GUID_RE='^[0-9a-fA-F-]{36}$'
BASE_WS="$API/groups/$WORKSPACE"

# The REST surface still calls semantic models "datasets"; the portal calls them
# semantic models. Same objects, and the path segment cannot be renamed.
if [[ "$LIST" -eq 1 ]]; then
    pbi_get "$BASE_WS/datasets" | jq -r '.value[] | [.id, .name] | @tsv' | column -t -s $'\t'
    exit 0
fi

if [[ -n "$SCHEMA" ]]; then
    if [[ -n "$QUERY" ]]; then
        echo "error: -s and -q/-i are mutually exclusive" >&2
        exit 1
    fi
    QUERY=$(schema_query "$SCHEMA")
fi

# No -q/-i/-s: read the query from stdin, so `echo ... | dax.sh` and heredocs work.
if [[ -z "$QUERY" ]]; then
    if [[ -t 0 ]]; then
        echo "error: no query given (use -q, -i, -s, or pipe one in on stdin)" >&2
        exit 1
    fi
    QUERY=$(cat)
fi

if [[ -z "$MODEL" ]]; then
    MODEL=$(cfg_value PBI_SEMANTIC_MODEL)
fi
if [[ -z "${MODEL:-}" ]]; then
    echo "error: no semantic model — set PBI_SEMANTIC_MODEL in $ENV_FILE or pass -m <name-or-guid>" >&2
    echo "hint: run with -l to list the models in workspace $WORKSPACE" >&2
    exit 1
fi

# Resolve a model display name to its GUID; a GUID passes through untouched.
if [[ "$MODEL" =~ $GUID_RE ]]; then
    MODEL_ID="$MODEL"
else
    MODEL_ID=$(pbi_get "$BASE_WS/datasets" \
        | jq -r --arg n "$MODEL" '.value[] | select(.name == $n) | .id' | head -n 1)
    if [[ -z "$MODEL_ID" ]]; then
        echo "error: semantic model '$MODEL' not found in workspace $WORKSPACE (try -l)" >&2
        exit 1
    fi
fi

# includeNulls is true regardless of -r. The API omits null-valued keys from a
# row object when it is false, so rows in one result would carry different key
# sets and the table below would silently misalign its columns. Nulls are
# rendered as empty cells instead.
BODY=$(jq -n --arg dax "$QUERY" --arg upn "$IMPERSONATE" '
    { queries: [ { query: $dax } ], serializerSettings: { includeNulls: true } }
    + ( if $upn == "" then {} else { impersonatedUserName: $upn } end )
')

RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST "$BASE_WS/datasets/$MODEL_ID/executeQueries" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY")
HTTP="${RESPONSE##*$'\n'}"
RESPONSE="${RESPONSE%$'\n'*}"

# Two failure channels, unlike kql.sh's one. A malformed or rejected DAX query is
# a real HTTP 400; a query that ran but blew a service limit ("More than one
# result table in a query", the 100k-row cap) comes back 200 with the error in
# the body. Both are checked.
dax_hints() {
    if [[ "$QUERY" != *EVALUATE* && "$QUERY" != *DEFINE* ]]; then
        echo "hint: a DAX query must start with EVALUATE (or DEFINE ... EVALUATE) — a bare" >&2
        echo "      table or measure reference is not a query" >&2
    fi
    if [[ "$QUERY" == *INFO.* ]]; then
        echo "hint: INFO functions work on this endpoint despite the reference saying" >&2
        echo "      otherwise, but they need semantic model admin permissions — so a" >&2
        echo "      failure here is far more likely permissions than support. Read model" >&2
        echo "      metadata via the Fabric getDefinition API (TMDL) if that is the case." >&2
    fi
    echo "hint: needs the tenant setting 'Dataset Execute Queries REST API' (Integration" >&2
    echo "      settings) and Build permission on the model" >&2
}

if [[ "$HTTP" != 2* ]]; then
    echo "error: executeQueries returned HTTP $HTTP" >&2
    jq -r '.error.message // .error["pbi.error"].code // .error.code // .message // empty' \
        <<<"$RESPONSE" >&2 || true
    dax_hints
    exit 1
fi

ERR=$(jq -r '
    ( .error // .results[0].error // .results[0].tables[0].error )
    | if . == null then empty else ( .message // .code // tostring ) end
' <<<"$RESPONSE" 2>/dev/null || true)
if [[ -n "$ERR" ]]; then
    echo "dax error: $ERR" >&2
    dax_hints
    exit 1
fi

if [[ "$RAW" -eq 1 ]]; then
    printf '%s\n' "$RESPONSE"
    exit 0
fi

# Response shape: .results[0].tables[0].rows is an array of objects keyed by
# fully-qualified column name ("Sales[Amount]"), not the parallel columns/rows
# arrays Kusto returns. The header is therefore derived from the row keys —
# keys_unsorted preserves the API's column order, and the reduce keeps first-seen
# order across rows rather than sorting them alphabetically like `unique` would.
jq -r '
    ( .results[0].tables[0].rows // [] ) as $rows
    | if ( $rows | length ) == 0 then "(0 rows)"
      else
        ( reduce ( $rows[] | keys_unsorted[] ) as $k
            ( []; if index( $k ) then . else . + [ $k ] end ) ) as $cols
        | ( $cols | @tsv ),
          ( $cols | map( "-" * ( length + 2 ) ) | @tsv ),
          ( $rows[] | . as $r
            | $cols | map( $r[.] | if . == null then "" else tostring end ) | @tsv )
      end
' <<<"$RESPONSE" | column -t -s $'\t'
