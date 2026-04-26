#!/usr/bin/env bash
# Wrapper around DuckDB for exploring Fabric OneLake delta tables with
# Azure CLI auth (`az login` token, via credential_chain = cli).
#
# Auth note: DuckDB requests a token for the storage.azure.com audience.
# Under Conditional Access, a plain `az login` (ARM scope) may not be
# enough — `az account show` works but `az account get-access-token
# --resource https://storage.azure.com` fails. Fix:
#   az login --scope https://storage.azure.com/.default
#
# Usage:
#   # Quick one-liner — the delta/azure extensions and the azure secret are
#   # pre-loaded, so you can go straight to delta_scan / read_parquet.
#   scripts/data/lake.sh -c "SELECT COUNT(*) FROM delta_scan('abfss://<workspace>@onelake.dfs.fabric.microsoft.com/<lakehouse>.Lakehouse/Tables/<schema>/<table>')"
#
#   # Interactive REPL (extensions + secret pre-loaded):
#   scripts/data/lake.sh
#
#   # Any extra flags pass through to duckdb.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/lake.sh.
# It does not read .env — workspace, lakehouse, schema, and table are passed
# inline in each ABFSS URL.

set -euo pipefail

if ! command -v duckdb >/dev/null 2>&1; then
    echo "error: duckdb not found on PATH" >&2
    echo "hint: winget install DuckDB.cli, then restart your shell" >&2
    exit 1
fi
DUCKDB_BIN="duckdb"

# Init script: load extensions and create the azure secret via CLI chain.
INIT_SQL=$(cat <<'EOF'
INSTALL delta;
INSTALL azure;
LOAD delta;
LOAD azure;
CREATE OR REPLACE SECRET azure_onelake (TYPE azure, PROVIDER credential_chain, CHAIN 'cli');
EOF
)

# Write init to a temp file; -init runs it before -c / interactive prompt.
INIT_FILE=$(mktemp --suffix=.sql 2>/dev/null || mktemp -t duckdb-init.XXXXXX.sql)
trap 'rm -f "$INIT_FILE"' EXIT
printf '%s\n' "$INIT_SQL" > "$INIT_FILE"

exec "$DUCKDB_BIN" -init "$INIT_FILE" "$@"
