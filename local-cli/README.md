# local-cli/

Local-workstation CLI wrappers for ad-hoc Fabric data exploration. Unlike the rest of this repo (which runs *inside* Fabric), these scripts run on a developer's machine and authenticate via the Azure CLI session — no SAS, no SP, no stored credentials.

These are templates. Copy them into a client repo at `scripts/data/` and use them there.

## Contents

| File | Purpose |
|---|---|
| [sql.sh](sql.sh) | `sqlcmd` wrapper for any AAD-authenticated T-SQL endpoint (see *Supported endpoints* below). Reads named `SQL_ENDPOINT_<NAME>` entries from `.env` (bare host or ADO.NET connection string), then authenticates with the Azure CLI token, running `az login` itself if there isn't a usable one. `-e` picks an endpoint, `-d` overrides the database, `-l` lists what's configured. |
| [lake.sh](lake.sh) | DuckDB wrapper for OneLake Delta tables. Pre-loads the `delta` and `azure` extensions and creates an Azure secret bound to the Azure CLI credential chain, running `az login` itself if there isn't a usable one. |
| [kql.sh](kql.sh) | `curl` + `jq` wrapper around the Kusto query REST API for any AAD-authenticated KQL endpoint — Fabric Eventhouse / KQL database, Azure Data Explorer, Log Analytics ADX proxy. Reads `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` from `.env`, then authenticates with the Azure CLI token, running `az login` itself if there isn't a usable one. |
| [report-png.sh](report-png.sh) | `curl` + `jq` wrapper around the Power BI `exportToFile` REST API — renders a **published** report's pages to PNG (or PDF) files server-side, no Power BI Desktop involved. Reads `PBI_WORKSPACE_ID` from `.env`, then authenticates with the Azure CLI token, running `az login` itself if there isn't a usable one. `-r` picks the report by display name or GUID, `-p` a single page, `-f PDF` the format fallback, `-l` lists the workspace's reports. Built as the visual-verification step of an AI-driven report-authoring loop: publish PBIR edits → export PNGs → the agent reviews the rendered pages. |
| [.env.sample](.env.sample) | Template for the client repo's `.env` — every key the scripts read, with placeholder values. Copied to the **client repo root** (not `scripts/data/`) and filled in. |

### sql.sh — supported endpoints

The wrapper is just a transport: anything `sqlcmd --authentication-method ActiveDirectoryAzCli` can connect to is fair game. That includes:

One script covers all of them deliberately — a Fabric workspace exposes a single SQL host, and the "database" is just the item display name (the same host serves the Warehouse and the Lakehouse SQL endpoint), so per-endpoint-type scripts would be this file with a different `-d`. Multiple endpoints across hosts are handled by named `.env` entries instead (see deployment step 4).

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

All scripts piggyback on your Azure CLI session. Each needs a token for a *different* audience:

| Script | Token audience | How it gets one |
|---|---|---|
| `sql.sh` | `https://database.windows.net/` | passes `--authentication-method ActiveDirectoryAzCli` to sqlcmd, which reads the cached `az` session |
| `kql.sh` | the cluster URI itself (not a fixed resource string) | `az account get-access-token --resource <cluster-uri>` |
| `lake.sh` | `https://storage.azure.com/` | DuckDB secret with `PROVIDER credential_chain, CHAIN 'cli'` |
| `report-png.sh` | `https://analysis.windows.net/powerbi/api` | `az account get-access-token --resource <audience>` |

No SAS keys, no service principal secrets, no connection-string passwords.

### All of them log you in automatically

Each probes for a token against its own audience before doing any work, and if the cached session can't produce one it starts an interactive login:

```bash
az login --allow-no-subscriptions --scope <audience>/.default
```

So there is nothing to run first — invoke the script and answer the browser prompt if it appears. This matters most when an AI coding tool drives the script: without the probe, the failure surfaces as sqlcmd's generic login error, a bare `ERROR: Please run 'az login'`, or (for `lake.sh`) an opaque DuckDB failure part-way through a query — none of which a tool can act on.

`lake.sh` is the case the probe helps most: DuckDB fetches the token internally through the credential chain, so there is no exit code to react to and a bad session fails deep inside the query rather than up front.

Two details of that command are deliberate:

- **`--allow-no-subscriptions`** — a Fabric-only tenant has no Azure subscription attached, and without the flag `az login` fails with *No subscriptions found* before minting anything. The tokens these scripts need are tenant-scoped, so nothing is lost by allowing it.
- **`--scope <audience>/.default`** — the audience is requested explicitly rather than relying on a default ARM-scoped login, which is what makes the Conditional Access case below work rather than 401.

The probe asks for the specific audience rather than checking `az account show`, because under Conditional Access a session can be valid while still unable to mint a token for the target — `az account show` succeeds and the query still fails.

Knobs, both optional:

- `AZURE_TENANT_ID` — passed as `--tenant`. Read from the environment first, then from `.env`. Only needed for an account that is a guest in more than one tenant, where an unqualified login lands in the home tenant and mints a token the endpoint rejects. (`lake.sh` reads nothing else from `.env` and runs fine without one.)
- `SKIP_AZ_LOGIN=1` in the environment — suppresses the login prompt and lets the underlying tool fail with its own error. For CI, or a headless box where an interactive login would hang.

On a headless box, log in once by hand instead and the probe will pass from then on — one login per audience you use:

```bash
az login --use-device-code --allow-no-subscriptions --scope https://database.windows.net/.default
az login --use-device-code --allow-no-subscriptions --scope https://storage.azure.com/.default
az login --use-device-code --allow-no-subscriptions --scope "https://<cluster>.<region>.kusto.fabric.microsoft.com/.default"
az login --use-device-code --allow-no-subscriptions --scope "https://analysis.windows.net/powerbi/api/.default"
```

## Deployment into a client repo

1. Copy the files into the client repo:

   ```
   <client-repo>/scripts/data/sql.sh
   <client-repo>/scripts/data/lake.sh
   <client-repo>/scripts/data/kql.sh
   <client-repo>/scripts/data/report-png.sh
   ```

   (All scripts assume this exact two-deep location — they resolve the repo root via `SCRIPT_DIR/../..` to find `.env`.)

2. Make them executable: `chmod +x scripts/data/*.sh` (no-op on Windows but matters if anyone clones on macOS/Linux).

3. Copy [.env.sample](.env.sample) to the **client repo root** as `.env` and fill in the values (per-key details in the next two steps). The scripts resolve `.env` two levels above `scripts/data/`, so the repo root is the one location that works. Check the client repo's `.gitignore` covers `.env` — the sample is committable, the filled-in copy never is.

4. For `sql.sh`, define one `SQL_ENDPOINT_<NAME>` entry per endpoint (name them whatever you like):

   ```env
   SQL_ENDPOINT_WAREHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<WarehouseName>
   SQL_ENDPOINT_LAKEHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<LakehouseName>
   SQL_ENDPOINT_DATABASE=Server=tcp:<server>.database.windows.net,1433;Initial Catalog=<database>;Encrypt=True;
   ```

   Both value shapes are accepted because the portal hands out both: Fabric Warehouse / Lakehouse SQL endpoint gives a bare host with no database — the database is the **item display name**, which the portal never puts in the string, so append it yourself as `<host>/<database>` (or pass `-d` at run time). Fabric SQL Database and Azure SQL give a full ADO.NET string; only `Server=` and `Initial Catalog=`/`Database=` are parsed, the rest is ignored. `SQL_ENDPOINT_DEFAULT` names the endpoint used when `-e` isn't passed; with exactly one endpoint defined it's optional. `sql.sh -l` lists what's configured.

5. **If the client repo already has a legacy `SQL_CONNECTION_STRING`**, it still works — the script falls back to it with a note on stderr suggesting the rename. Rename it to `SQL_ENDPOINT_<NAME>` when you want more than one endpoint.

   **Multi-environment repos** (dev/test/prod workspaces behind deployment pipelines): prefix any connection key with an environment name and pick the environment per run:

   ```env
   ENV_DEFAULT=DEV
   DEV_SQL_ENDPOINT_WAREHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<WarehouseName>
   PROD_SQL_ENDPOINT_WAREHOUSE=<yyy>.datawarehouse.fabric.microsoft.com/<WarehouseName>
   DEV_KUSTO_CLUSTER_URI=https://<cluster-d>.<region>.kusto.fabric.microsoft.com
   PROD_KUSTO_CLUSTER_URI=https://<cluster-p>.<region>.kusto.fabric.microsoft.com
   KUSTO_DATABASE=<KqlDatabaseName>
   DEV_PBI_WORKSPACE_ID=<workspace-guid>
   ```

   The environment is chosen by `-E <env>` on `sql.sh` / `kql.sh` / `report-png.sh`, else the `FAB_ENV` environment variable, else `ENV_DEFAULT` in `.env`; with none of the three set only bare keys are read (single-environment behavior, fully backward compatible). Lookup is `<ENV>_<KEY>` first, bare `<KEY>` as fallback — deployment pipelines keep item *display names* identical across stages, so typically only hosts, cluster URIs, and workspace GUIDs get prefixed while name-valued keys (`KUSTO_DATABASE`, the `/<database>` suffix inside each endpoint value) are written once. Environment names are alphanumeric only (no underscores — the key parse would be ambiguous). Point `ENV_DEFAULT` at the safe environment so reaching prod always takes an explicit `-E prod`. `lake.sh` has no environment flag — its connection details are inline in each ABFSS URL. `kql.sh` additionally accepts `-d <database>` to hit another database on the same cluster (e.g. a logging database beside the operational one).

6. For `kql.sh`, fill in the cluster URI and database:

   ```env
   KUSTO_CLUSTER_URI=https://<cluster>.<region>.kusto.fabric.microsoft.com
   KUSTO_DATABASE=<KqlDatabaseName>
   ```

   The Query URI is on the KQL database's detail page in the Fabric portal (or the ADX cluster overview blade). `KUSTO_DATABASE` takes the database name; the item GUID also works.

7. `lake.sh` takes no connection details from `.env` — workspace, lakehouse, schema, and table go inline in each ABFSS URL. The only key it reads is the optional `AZURE_TENANT_ID`, and it runs fine with no `.env` at all.

8. For `report-png.sh`, fill in the workspace GUID (from the workspace URL — `app.powerbi.com/groups/<GUID>/...`):

   ```env
   PBI_WORKSPACE_ID=<workspace-guid>
   ```

   The report itself is picked per run with `-r <display-name-or-guid>` (`-l` lists what's in the workspace). Two service-side prerequisites, both one-time: the workspace must be on a Fabric/Premium capacity, and PNG export needs the tenant setting **"Export reports as image files"** enabled (off by default — until then `-f PDF` works, as PDF export is on by default).

9. **Optional: tell the repo's AI tools the wrappers exist.** Drop the [snippet below](#ai-tool-instruction-snippet) into whichever instruction file your AI tool of choice reads. The same markdown content works for all of them.

   | Tool | File path |
   | --- | --- |
   | Claude Code | `<client-repo>/CLAUDE.md` |
   | GitHub Copilot (in-IDE: VS Code, JetBrains, Visual Studio) | `<client-repo>/.github/copilot-instructions.md` |
   | OpenAI Codex CLI / Cursor / Aider / GitHub Copilot coding agent / many others | `<client-repo>/AGENTS.md` (repo root) |

   `AGENTS.md` is an open cross-tool convention adopted by Codex, Cursor, Aider, Devin, Junie, Zed, Warp, the GitHub Copilot coding agent, and others — see [agents.md](https://agents.md). Note that GitHub Copilot reads `.github/copilot-instructions.md` for in-IDE completions but its coding-agent variant also reads `AGENTS.md`. If you only want one file, `AGENTS.md` has the broadest reach.

## Usage

### sql.sh

```bash
# One-shot query against the default endpoint
scripts/data/sql.sh -Q "SELECT TOP 5 * FROM <schema>.<Table>"

# Pick a named endpoint from .env
scripts/data/sql.sh -e database -Q "SELECT 1"

# Pick an environment (multi-env .env; defaults to ENV_DEFAULT / FAB_ENV)
scripts/data/sql.sh -E prod -Q "SELECT 1"

# Same host, different item (e.g. the Lakehouse SQL endpoint on a Fabric host)
scripts/data/sql.sh -d <LakehouseName> -Q "SELECT 1"

# List configured endpoints (* marks the default)
scripts/data/sql.sh -l

# Run a .sql file
scripts/data/sql.sh -i path/to/script.sql

# Pipe from stdin
echo "SELECT 1" | scripts/data/sql.sh

# Any other flags are passed through to sqlcmd
scripts/data/sql.sh -Q "SELECT @@VERSION" -h -1 -W
```

`-e`/`-d`/`-l` are consumed by the wrapper; everything else goes straight to sqlcmd. `-d` keeps sqlcmd's own meaning (database), so there is nothing new to remember.

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

### report-png.sh

```bash
# List reports in the configured workspace (id + name)
scripts/data/report-png.sh -l

# Export every page of a report to PNG (files land in report-pages/<Report>/,
# named by page display name; paths printed to stdout)
scripts/data/report-png.sh -r "Sales"

# Single page, by display name or internal ReportSection name
scripts/data/report-png.sh -r "Sales" -p "Overview"

# PDF fallback when the PNG tenant setting is off
scripts/data/report-png.sh -r "Sales" -f PDF

# Custom output dir / other workspace
scripts/data/report-png.sh -r "Sales" -o out/ -w <workspace-guid>
```

The export is asynchronous server-side rendering (progress on stderr, ~seconds for small reports). Multi-page PNG exports arrive as a zip; the script extracts it and renames the files from internal `ReportSection…` ids to page display names. Typical AI loop: edit PBIR → publish (Git sync or REST) → `report-png.sh` → the agent reads the PNGs and iterates.

## AI tool instruction snippet

Paste this into whichever AI instruction file the client repo uses (`CLAUDE.md`, `.github/copilot-instructions.md`, `AGENTS.md` — see the deployment-step table above). The content is the same for all three:

```markdown
## Local data wrappers (scripts/data/)

- `scripts/data/sql.sh` — sqlcmd wrapper for the repo's T-SQL endpoints (Fabric SQL DB / Fabric Warehouse / Azure SQL DB); reads `SQL_ENDPOINT_<NAME>` entries from `.env`. Usage: `scripts/data/sql.sh -Q "SELECT ..."` or `-i file.sql` or stdin; `-e <name>` picks an endpoint, `-d <database>` targets another item on the same host, `-l` lists endpoints.
- `scripts/data/lake.sh` — DuckDB wrapper for OneLake Delta tables; pre-loads delta/azure extensions and an `az`-CLI-chain secret. Usage: `scripts/data/lake.sh -c "SELECT ... FROM delta_scan('abfss://<workspace>@onelake.dfs.fabric.microsoft.com/<lakehouse>.Lakehouse/Tables/<schema>/<table>')"` or no-args for REPL.
- `scripts/data/kql.sh` — curl+jq wrapper for the repo's KQL endpoint (Fabric Eventhouse / ADX); reads `KUSTO_CLUSTER_URI` and `KUSTO_DATABASE` from `.env`. Usage: `scripts/data/kql.sh -q "<Table> | take 5"` or `-i file.kql` or stdin; `.show ...` commands work too.
- `scripts/data/report-png.sh` — renders a published Power BI report to PNG files via the exportToFile REST API (no Power BI Desktop); reads `PBI_WORKSPACE_ID` from `.env`. Usage: `scripts/data/report-png.sh -r "<ReportName>"` exports all pages (file paths on stdout — read the PNGs to review the rendered report); `-p <page>` one page, `-l` lists reports, `-f PDF` if PNG export is tenant-disabled. Use after publishing report edits to visually verify layout, sorting, theming, and non-empty visuals.
- All of these handle auth themselves — they check for a usable Azure CLI token and start an interactive `az login` if there isn't one, so just run them; don't run `az login` first or treat a login prompt as an error. No SAS or stored credentials. Schemas in this repo: `<list-known-schemas>`.
- Multi-environment: `-E <env>` on `sql.sh` / `kql.sh` / `report-png.sh` picks the environment (`<ENV>_`-prefixed `.env` keys, bare keys as fallback); without it the `ENV_DEFAULT` environment applies. Environments in this repo: `<list-environments>` (default `<default-env>`).
- Prefer these wrappers for ad-hoc data exploration when the user asks to inspect, sample, count, or query repo data — and default to running them unprompted whenever a question about the data's contents blocks a decision (a column's scale or units, nullability, cardinality, row counts). Check the data and report what you found instead of asking the user to check or hedging on an assumption. Read-only queries against the default environment need no confirmation.
```

Replace `<list-known-schemas>` with the actual schemas in the client lakehouse, and drop the T-SQL endpoint flavors that don't apply to the repo. If the repo has more than one SQL endpoint configured, list the endpoint names and what each serves.
