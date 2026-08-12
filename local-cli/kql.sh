#!/usr/bin/env bash
# Wrapper around the Kusto query REST API for any AAD-authenticated KQL endpoint —
# Fabric Eventhouse / KQL database, Azure Data Explorer, Log Analytics ADX proxy.
# Reads the cluster URI and database from the repo's .env and authenticates with
# the Azure CLI token (`az login`).
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
#
# Auth note: the token audience is the cluster host itself, not a fixed resource
# string. Under Conditional Access a plain `az login` may not cover it; if you
# get 401, run:
#   az login --scope "$KUSTO_CLUSTER_URI/.default"
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
env_value() {
    grep -E "^$1=" "$ENV_FILE" | head -n 1 | cut -d '=' -f 2- | tr -d '\r'
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
        -h|--help) sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
