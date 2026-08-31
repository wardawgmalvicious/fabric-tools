# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A curated collection of Microsoft Fabric **notebooks**, **shell-script templates**, and **markdown configuration guides** for platform engineering. There is no application to build, no test suite, and no package to install — artifacts are imported into a Fabric workspace (notebooks), copied into client repos (`local-cli/`), or pasted into Fabric Copilot surfaces (`guides/`). Treat each file as a standalone deliverable.

The guiding philosophy is **SP-first, parameterized, CI/CD-ready**: everything authenticates via service principal, nothing hardcodes environment-specific GUIDs, and operations are built to slot into automated pipelines rather than depend on interactive portal clicks.

## Commands

There is no build/lint/test. The only repo-level workflow is the notebook-metadata scrubber:

```bash
# Activate the pre-commit hook once per clone (REQUIRED before committing notebooks)
git config core.hooksPath .githooks

# Manually scrub a notebook (what the hook runs per staged .ipynb)
pwsh -File .githooks/scrub-fabric-notebook.ps1 path/to/notebook.ipynb

# Bypass the hook if needed
git commit --no-verify
```

The hook requires PowerShell 7+ (`pwsh`) on PATH. On this Windows machine, prefer the **PowerShell tool** for shell work — the Bash tool's `bash.exe` is blocked (`EPERM`).

## The notebook-metadata invariant (most important rule)

Notebooks downloaded from Fabric carry workspace-bound metadata — default lakehouse GUIDs, `spark_compute.compute_id`, `a365ComputeOptions`, `sessionKeepAliveTimeout`, session settings — that **must never be committed**. [.githooks/scrub-fabric-notebook.ps1](.githooks/scrub-fabric-notebook.ps1) rewrites each staged `.ipynb` so only an allowlist survives:

- **Top-level metadata kept:** `language_info`, `kernel_info`, `microsoft` (Fabric uses `microsoft.language` to route `%%sql` / `%%pyspark`).
- **Per-cell metadata kept:** `microsoft` only. All cell `outputs` are emptied and `execution_count` reset to `null`.
- **Cell `source` normalized to array-of-strings.** Jupyter accepts a bare string; Fabric's notebook importer does not — it fails with `400 Bad Request` / `pbi.error.exceptionCulprit: 1` and no further detail. The scrubber re-shapes without altering text (joining the array reproduces the original exactly). Cells authored programmatically rather than round-tripped through Fabric are the usual source of the bare-string form.

The scrubber is idempotent and preserves Jupyter/Fabric key ordering to keep diffs minimal. `.gitattributes` pins `*.ipynb` to `eol=lf` so scrubbing stays idempotent regardless of `core.autocrlf`. When editing notebooks, do not reintroduce stripped keys.

## Architecture

### admin/ — SP provisioning (the `%run` module pattern)
[admin/nb_sp_common.ipynb](admin/nb_sp_common.ipynb) is the base module: it reads SP credentials (`tenantId`/`clientId`/`clientSecret`) from Azure Key Vault via `notebookutils.credentials.getSecret`, acquires a Fabric API token (MSAL / client-credentials, audience `https://api.fabric.microsoft.com`), and defines shared helpers (`get_access_token`, `get_capacity_id`, `get_item_id_by_name`, ...). The other three admin notebooks (`nb_sp_create_item`, `nb_sp_identity`, `nb_sp_mirror`) `%run` it in their first cell and call the helpers directly. Run `nb_sp_common` standalone only to test Key Vault / token plumbing.

### maintenance/ — idempotent Lakehouse ops
`nb_lh_optimize` (OPTIMIZE + VACUUM), `nb_lh_configure` (Delta `TBLPROPERTIES`, reads current values and skips unchanged tables), `nb_spark_config` (session tuning). Safe to schedule; these never mutate schema or item metadata.

### utilities/ — CI/CD metadata feedback loop
`nb_extract_guids` enumerates workspace items and writes their GUIDs into a Fabric **Variable Library** (optionally via the Fabric REST API) so downstream items reference GUIDs by variable name instead of hardcoding them — the mechanism that makes dev/test/prod promotion work. `nb_migrate_items` bulk-migrates code artifacts between workspaces.

### integration/ — external-source reference patterns
e.g. `nb_salesforce_ingest`. Authenticate to a third-party API (secrets from Key Vault), extract, land as Delta with overwrite. These are reference patterns to fork, not production pipelines.

### guides/ — Fabric Copilot config templates
Markdown for the semantic-model AI-instructions blob and Data Agent configuration. Replace the illustrative retail/sales examples with the target domain without changing structure. Each tracks its Microsoft Learn source + last-updated date.

### local-cli/ — workstation CLI wrappers (templates, not run in-place)
[sql.sh](local-cli/sql.sh) (sqlcmd over any AAD T-SQL endpoint), [kql.sh](local-cli/kql.sh) (curl+jq over the Kusto REST API), [lake.sh](local-cli/lake.sh) (DuckDB over OneLake Delta), [dax.sh](local-cli/dax.sh) (curl+jq over the Power BI `executeQueries` API — DAX against a published semantic model), and [report-png.sh](local-cli/report-png.sh) (curl+jq over `exportToFile`). Unlike everything else, these run on a developer's machine and auth via the **Azure CLI session** (`az login`), no SP/SAS. They are meant to be copied into a client repo at `scripts/data/` — all resolve the repo root via `SCRIPT_DIR/../..`, so that two-deep location is load-bearing. `sql.sh` reads named `SQL_ENDPOINT_<NAME>` entries from `<repo>/.env` (bare `host/database` or ADO.NET string; legacy `SQL_CONNECTION_STRING` still honored); `kql.sh` reads `KUSTO_CLUSTER_URI` / `KUSTO_DATABASE`; `dax.sh` and `report-png.sh` share `PBI_WORKSPACE_ID` (plus `PBI_SEMANTIC_MODEL_ID` or `_NAME` for `dax.sh`) on the `analysis.windows.net/powerbi/api` audience — the `_ID`/`_NAME` suffix is a rule, not a label: GUID-valued keys are stage-specific and take an `<ENV>_` prefix, name-valued keys survive promotion and stay bare; `lake.sh` takes connection details inline in the ABFSS URL.

## Conventions when editing notebooks

- **Placeholders, not values.** Environment-specific names appear as angle-bracket placeholders (`<KeyVaultName>`, `<ServicePrincipalName>`, `<ServicePrincipalClientIdSecretName>`). Keep that style; never commit real GUIDs, workspace names, or secret values.
- **Runtime identity:** use `notebookutils.runtime.context["currentWorkspaceId"]` (documented public API, works in pure-Python notebooks). Reserve `spark.conf.*` (e.g. `trident.workspace.id`) for Spark-session tuning, not identity resolution.
- **LRO-aware:** poll long-running Fabric REST operations to completion with timeout handling rather than fire-and-forget.
- **Cell style:** banner comments (`# ----` blocks) section the cells; functions carry `:param:`/`:returns:`/`:raises:` docstrings. Match the surrounding density.
- Token audience matters — `api.fabric.microsoft.com` for Fabric REST, `storage.azure.com` for OneLake (see the `fabric-auth` skill). Wrong audience is the #1 cause of 401s.

## Coding rules

Path-scoped conventions for T-SQL, Spark SQL, Python/PySpark, KQL, DAX, M, TMDL, and pipeline expressions live in the user-scope `~/.claude/rules/` and auto-load when a matching file is in scope. There is no project-scope override in this repo.
