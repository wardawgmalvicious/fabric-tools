#!/usr/bin/env bash
# Wrapper around the Kusto query REST API for any AAD-authenticated KQL endpoint —
# Fabric Eventhouse / KQL database, Azure Data Explorer, Log Analytics ADX proxy.
# Reads the cluster URI and database from the repo's .env and authenticates with
# the Azure CLI token, running `az login` for you if the cached session cannot
# mint one (see "Azure CLI login preflight" below).
#
# There is no `sqlcmd` equivalent for Kusto, so this posts to the cluster's
# /v1/rest/query endpoint directly with curl and formats the response with jq.
# Both are required.
#
# .env keys:
#   KUSTO_CLUSTER_URI   https://<cluster>.<region>.kusto.fabric.microsoft.com
#                       (Fabric portal: KQL database → Query URI)
#   KUSTO_DATABASE      KQL database name, e.g. <KqlDatabaseName>. The item
#                       GUID also works.
#   AZURE_TENANT_ID     optional — passed to `az login` when set
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
#   # Management commands (leading dot) go to /v1/rest/mgmt automatically:
#   scripts/data/kql.sh -q ".show tables"
#
#   # -r emits the raw Kusto JSON response instead of a table, for piping to jq:
#   scripts/data/kql.sh -r -q "<Table> | take 1" | jq '.Tables[0].Rows'
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

CLUSTER=$(env_value KUSTO_CLUSTER_URI)
DATABASE=$(env_value KUSTO_DATABASE)

if [[ -z "${CLUSTER:-}" || -z "${DATABASE:-}" ]]; then
    echo "error: KUSTO_CLUSTER_URI and KUSTO_DATABASE must both be set in $ENV_FILE" >&2
    exit 1
fi
CLUSTER="${CLUSTER%/}"  # tolerate a trailing slash

QUERY=""
RAW=0

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
        # Print the header block: line 2 through the first blank line. A fixed
        # line range silently drifts out of date every time the header is edited.
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1' (expected -q, -i, -r, or stdin)" >&2; exit 1 ;;
    esac
done

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

# jq -n --arg builds the JSON body so quotes, newlines, and backslashes in the
# query survive; string-concatenating it into the payload would not.
BODY=$(jq -n --arg db "$DATABASE" --arg csl "$QUERY" '{db: $db, csl: $csl}')

RESPONSE=$(curl -sS -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary "$BODY")

# Kusto reports query errors in a 200 body, not the HTTP status, so check the
# payload rather than curl's exit code.
if jq -e 'has("error")' >/dev/null 2>&1 <<<"$RESPONSE"; then
    jq -r '.error | "kusto error: \(.["@message"] // .message // tostring)"' <<<"$RESPONSE" >&2
    exit 1
fi

if [[ "$RAW" -eq 1 ]]; then
    printf '%s\n' "$RESPONSE"
    exit 0
fi

# v1 response shape: .Tables[0] carries the result set, .Columns[].ColumnName the
# header, .Rows[] the values. Later tables are QueryStatus/QueryProperties.
jq -r '
    .Tables[0] as $t
    | ([$t.Columns[].ColumnName] | @tsv),
      ([$t.Columns[].ColumnName] | map("-" * (length + 2)) | @tsv),
      ($t.Rows[] | map(if . == null then "" else tostring end) | @tsv)
' <<<"$RESPONSE" | column -t -s $'\t'
