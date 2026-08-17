#!/usr/bin/env bash
# Wrapper around DuckDB for exploring Fabric OneLake delta tables with
# Azure CLI auth (`az login` token, via credential_chain = cli).
#
# Auth note: DuckDB requests a token for the storage.azure.com audience, which
# is narrower than what a plain `az login` (ARM scope) gets you — under
# Conditional Access `az account show` works while `az account get-access-token
# --resource https://storage.azure.com` fails, and DuckDB surfaces that as an
# opaque failure mid-query. The preflight below probes that audience up front
# and logs in with the right scope, so there is nothing to run first.
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
# No connection details come from .env — workspace, lakehouse, schema, and table
# are passed inline in each ABFSS URL. The only key it looks for is the optional
# AZURE_TENANT_ID below, and it runs fine with no .env at all.

set -euo pipefail

if ! command -v duckdb >/dev/null 2>&1; then
    echo "error: duckdb not found on PATH" >&2
    echo "hint: winget install DuckDB.cli, then restart your shell" >&2
    exit 1
fi
DUCKDB_BIN="duckdb"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Reads the one optional key the login preflight honours. Unlike sql.sh/kql.sh
# this script has no required .env, so a missing file is not an error.
env_value() {
    local file="$REPO_ROOT/.env"
    [[ -f "$file" ]] || return 0
    { grep -E "^$1=" "$file" || true; } | head -n 1 | cut -d '=' -f 2- | tr -d '\r'
}

# --- Azure CLI login preflight ------------------------------------------------
# DuckDB fetches the storage token internally through the credential chain, so
# there is no exit code to react to — a session that cannot mint one fails deep
# inside a query instead of up front. Probing the audience here turns that into
# a login prompt before any SQL runs.
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

# OneLake accepts this audience only — datalake.azure.net is rejected.
ensure_az_login "https://storage.azure.com/"

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
