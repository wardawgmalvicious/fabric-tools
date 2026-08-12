# local-cli/

Local-workstation CLI wrappers for ad-hoc Fabric data exploration. Unlike the rest of this repo (which runs *inside* Fabric), these scripts run on a developer's machine and authenticate via the Azure CLI session — no SAS, no SP, no stored credentials.

These are templates. Copy them into a client repo at `scripts/data/` and use them there.

## Contents

| File | Purpose |
|---|---|
| [sql.sh](sql.sh) | `sqlcmd` wrapper for any AAD-authenticated T-SQL endpoint (see *Supported endpoints* below). Reads `Server` and `Initial Catalog` from a connection string in `.env`, then authenticates with the Azure CLI token. |
| [lake.sh](lake.sh) | DuckDB wrapper for OneLake Delta tables. Pre-loads the `delta` and `azure` extensions and creates an Azure secret bound to the Azure CLI credential chain. |
| [kql.sh](kql.sh) | `curl` + `jq` wrapper around the Kusto query REST API for any AAD-authenticated KQL endpoint — Fabric Eventhouse / KQL database, Azure Data Explorer, Log Analytics ADX proxy. Reads `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` from `.env`, then authenticates with the Azure CLI token. |
| [.env.sample](.env.sample) | Template for the client repo's `.env` — every key the scripts read, with placeholder values. Copied to the **client repo root** (not `scripts/data/`) and filled in. |

### sql.sh — supported endpoints

The wrapper is just a transport: anything `sqlcmd --authentication-method ActiveDirectoryAzCli` can connect to is fair game. That includes:

- Fabric SQL Database (`*.database.fabric.microsoft.com`)
- Fabric Warehouse / Lakehouse SQL endpoint (`*.datawarehouse.fabric.microsoft.com`)
- Azure SQL Database (`*.database.windows.net`)
- Azure SQL Managed Instance
- Synapse dedicated SQL pool

These wrappers live in `fabric-tools` because Fabric is the primary use case, but Azure SQL DB is a common Fabric mirroring source, so cross-platform usage is expected. T-SQL surface differs by endpoint (Fabric Warehouse has restrictions Azure SQL DB doesn't, and vice versa) — that's a query concern, not a wrapper concern.

### kql.sh — how it works

There is no `sqlcmd` equivalent for Kusto, so `kql.sh` posts to the cluster's REST endpoints directly with `curl` and formats the JSON response into a table with `jq`. Management commands (leading dot, e.g. `.show tables`) are routed to `/v1/rest/mgmt` automatically; everything else goes to `/v1/rest/query`. Kusto reports query errors in a 200 body rather than the HTTP status, so the script inspects the payload and surfaces the Kusto error message on stderr with a non-zero exit.

## Required CLI tools

Install once per workstation:

```powershell
winget install Microsoft.Sqlcmd     # modern Go-based sqlcmd (not the legacy ODBC tool)
winget install DuckDB.cli           # duckdb on PATH
winget install Microsoft.AzureCLI   # provides `az login` and credential chain
winget install jqlang.jq            # jq, used by kql.sh (curl ships with Windows)
```

> Verify the `Microsoft.Sqlcmd` package id with `winget search sqlcmd` if the install fails — Microsoft has historically shipped sqlcmd under a few different package names.

## Auth model

All scripts piggyback on your existing Azure CLI session:

```bash
az login --tenant <tenant-id-or-domain>
az account set --subscription <subscription-id>   # optional, scope to the right sub
```

- `sql.sh` passes `--authentication-method ActiveDirectoryAzCli` to sqlcmd, which fetches a SQL-audience token from the cached `az` session.
- `lake.sh` creates a DuckDB secret with `PROVIDER credential_chain, CHAIN 'cli'`, so DuckDB's azure extension picks up the same `az` token for OneLake (storage-audience) requests.
- `kql.sh` runs `az account get-access-token --resource <cluster-uri>` — the token audience is the cluster host itself, not a fixed resource string.

No SAS keys, no service principal secrets, no connection-string passwords. Token lifetime follows your `az` session — re-run `az login` if a script suddenly returns 401.

**Auth gotcha**: DuckDB requests a token for the `https://storage.azure.com` audience. Under Conditional Access, a plain `az login` may give you an ARM-scoped session that silently fails to mint a storage token (you'll see `'az account get-access-token' command failed: ERROR: Please run 'az login'` even though `az account show` works). Fix with a scoped login:

```bash
az login --scope https://storage.azure.com/.default
```

`kql.sh` has the same failure mode with a different scope — its token audience is the cluster URI, so if it returns 401 under Conditional Access:

```bash
az login --scope "https://<cluster>.<region>.kusto.fabric.microsoft.com/.default"
```

## Deployment into a client repo

1. Copy the files into the client repo:

   ```
   <client-repo>/scripts/data/sql.sh
   <client-repo>/scripts/data/lake.sh
   <client-repo>/scripts/data/kql.sh
   ```

   (All scripts assume this exact two-deep location — they resolve the repo root via `SCRIPT_DIR/../..` to find `.env`.)

2. Make them executable: `chmod +x scripts/data/*.sh` (no-op on Windows but matters if anyone clones on macOS/Linux).

3. Copy [.env.sample](.env.sample) to the **client repo root** as `.env` and fill in the values (per-key details in the next two steps). The scripts resolve `.env` two levels above `scripts/data/`, so the repo root is the one location that works. Check the client repo's `.gitignore` covers `.env` — the sample is committable, the filled-in copy never is.

4. For `sql.sh`, fill in the connection string:

   ```env
   SQL_CONNECTION_STRING=Server=tcp:<server>.database.fabric.microsoft.com,1433;Initial Catalog=<database>;Encrypt=True;
   ```

   The script only parses `Server=` and `Initial Catalog=` — the rest of the connection string is ignored, so paste whatever Fabric gives you.

5. **If the client repo already uses a different env var name** (e.g., `DAB_CONNECTION_STRING`, `FABRIC_SQL_CONN`), edit the `CONN_VAR="SQL_CONNECTION_STRING"` line near the top of `sql.sh` to match. There's an inline comment at that line marking it as the rename point.

6. For `kql.sh`, fill in the cluster URI and database:

   ```env
   KUSTO_CLUSTER_URI=https://<cluster>.<region>.kusto.fabric.microsoft.com
   KUSTO_DATABASE=<KqlDatabaseName>
   ```

   The Query URI is on the KQL database's detail page in the Fabric portal (or the ADX cluster overview blade). `KUSTO_DATABASE` takes the database name; the item GUID also works.

7. `lake.sh` does not read `.env` — workspace, lakehouse, schema, and table go inline in each ABFSS URL.

8. **Optional: tell the repo's AI tools the wrappers exist.** Drop the [snippet below](#ai-tool-instruction-snippet) into whichever instruction file your AI tool of choice reads. The same markdown content works for all of them.

   | Tool | File path |
   | --- | --- |
   | Claude Code | `<client-repo>/CLAUDE.md` |
   | GitHub Copilot (in-IDE: VS Code, JetBrains, Visual Studio) | `<client-repo>/.github/copilot-instructions.md` |
   | OpenAI Codex CLI / Cursor / Aider / GitHub Copilot coding agent / many others | `<client-repo>/AGENTS.md` (repo root) |

   `AGENTS.md` is an open cross-tool convention adopted by Codex, Cursor, Aider, Devin, Junie, Zed, Warp, the GitHub Copilot coding agent, and others — see [agents.md](https://agents.md). Note that GitHub Copilot reads `.github/copilot-instructions.md` for in-IDE completions but its coding-agent variant also reads `AGENTS.md`. If you only want one file, `AGENTS.md` has the broadest reach.

## Usage

### sql.sh

```bash
# One-shot query
scripts/data/sql.sh -Q "SELECT TOP 5 * FROM <schema>.<Table>"

# Run a .sql file
scripts/data/sql.sh -i path/to/script.sql

# Pipe from stdin
echo "SELECT 1" | scripts/data/sql.sh

# Any flags are passed through to sqlcmd
scripts/data/sql.sh -Q "SELECT @@VERSION" -h -1 -W
```

### lake.sh

```bash
# One-shot query against a OneLake Delta table
scripts/data/lake.sh -c "SELECT COUNT(*) FROM delta_scan('abfss://<workspace>@onelake.dfs.fabric.microsoft.com/<lakehouse>.Lakehouse/Tables/<schema>/<table>')"

# Interactive REPL — extensions and azure secret are already loaded
scripts/data/lake.sh
```

### kql.sh

```bash
# One-shot query
scripts/data/kql.sh -q "<Table> | count"

# Run a .kql file
scripts/data/kql.sh -i path/to/query.kql

# Pipe from stdin
echo "<Table> | take 5" | scripts/data/kql.sh

# Management commands (leading dot) route to /v1/rest/mgmt automatically
scripts/data/kql.sh -q ".show tables"

# -r emits the raw Kusto JSON response instead of a table, for piping to jq
scripts/data/kql.sh -r -q "<Table> | take 1" | jq '.Tables[0].Rows'
```

## AI tool instruction snippet

Paste this into whichever AI instruction file the client repo uses (`CLAUDE.md`, `.github/copilot-instructions.md`, `AGENTS.md` — see the deployment-step table above). The content is the same for all three:

```markdown
## Local data wrappers (scripts/data/)

- `scripts/data/sql.sh` — sqlcmd wrapper for the repo's T-SQL endpoint (Fabric SQL DB / Fabric Warehouse / Azure SQL DB); reads `<ENV_VAR>` from `.env`, authenticates via `az login`. Usage: `scripts/data/sql.sh -Q "SELECT ..."` or `-i file.sql` or stdin.
- `scripts/data/lake.sh` — DuckDB wrapper for OneLake Delta tables; pre-loads delta/azure extensions and an `az`-CLI-chain secret. Usage: `scripts/data/lake.sh -c "SELECT ... FROM delta_scan('abfss://<workspace>@onelake.dfs.fabric.microsoft.com/<lakehouse>.Lakehouse/Tables/<schema>/<table>')"` or no-args for REPL.
- `scripts/data/kql.sh` — curl+jq wrapper for the repo's KQL endpoint (Fabric Eventhouse / ADX); reads `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` from `.env`, authenticates via `az login`. Usage: `scripts/data/kql.sh -q "<Table> | take 5"` or `-i file.kql` or stdin; `.show ...` commands work too.
- All require an active `az login` session; no SAS or stored credentials. Schemas in this repo: `<list-known-schemas>`.
- Prefer these wrappers for ad-hoc data exploration when the user asks to inspect, sample, count, or query repo data.
```

Replace `<ENV_VAR>` with whatever name the client repo uses (e.g., `SQL_CONNECTION_STRING`, `DAB_CONNECTION_STRING`) and `<list-known-schemas>` with the actual schemas in the client lakehouse. Drop the T-SQL endpoint flavors that don't apply to the repo.
