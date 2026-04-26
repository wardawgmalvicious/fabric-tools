#!/usr/bin/env bash
# Wrapper around modern `sqlcmd` for any AAD-authenticated T-SQL endpoint —
# Fabric SQL Database, Fabric Warehouse / Lakehouse SQL endpoint, Azure SQL
# Database, Azure SQL Managed Instance, Synapse dedicated pool. Reads the
# connection string from the repo's .env via SQL_CONNECTION_STRING and
# authenticates with the Azure CLI token (`az login`).
#
# Usage:
#   scripts/data/sql.sh -Q "SELECT TOP 5 * FROM <schema>.<Table>"
#   scripts/data/sql.sh -i path/to/script.sql
#   echo "SELECT 1" | scripts/data/sql.sh
#
# Any extra flags are passed through to sqlcmd.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/sql.sh
# so SCRIPT_DIR/../.. resolves to the repo root containing .env.

set -euo pipefail

# Resolve repo root (script lives in <repo>/scripts/data/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: .env not found at $ENV_FILE" >&2
    exit 1
fi

# Env var holding the full ADO.NET-style connection string. Rename here to
# match an existing client .env convention (e.g., DAB_CONNECTION_STRING) if needed.
CONN_VAR="SQL_CONNECTION_STRING"

# Extract the raw connection string value without sourcing (.env may contain
# other entries with characters bash would choke on).
CONN=$(grep -E "^${CONN_VAR}=" "$ENV_FILE" | head -n 1 | cut -d '=' -f 2-)

if [[ -z "${CONN:-}" ]]; then
    echo "error: ${CONN_VAR} not set in $ENV_FILE" >&2
    exit 1
fi

# Parse Server= and Initial Catalog= from the connection string.
SERVER=$(printf '%s' "$CONN" | grep -oiE 'Server=[^;]+' | head -n1 | cut -d '=' -f2-)
DATABASE=$(printf '%s' "$CONN" | grep -oiE 'Initial Catalog=[^;]+' | head -n1 | cut -d '=' -f2-)

if [[ -z "$SERVER" || -z "$DATABASE" ]]; then
    echo "error: failed to parse Server/Initial Catalog from ${CONN_VAR}" >&2
    exit 1
fi

exec sqlcmd \
    -S "$SERVER" \
    -d "$DATABASE" \
    --authentication-method ActiveDirectoryAzCli \
    "$@"
