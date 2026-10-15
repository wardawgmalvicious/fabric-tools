# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A curated collection of Microsoft Fabric **notebooks**, **shell and PowerShell script templates**, and **Python generator templates** for platform engineering. There is no application to build, no test suite, and no package to install — artifacts are imported into a Fabric workspace (notebooks) or copied into client repos (`local-cli/`, `git-sync/`). Treat each file as a standalone deliverable.

The guiding philosophy is **SP-first, parameterized, CI/CD-ready**: everything authenticates via service principal, nothing hardcodes environment-specific GUIDs, and operations are built to slot into automated pipelines rather than depend on interactive portal clicks.

## Commands

There is no build/lint/test. The repo-level workflows are the notebook-metadata scrubber and the hooks that gate what leaves this clone:

```bash
# Activate all three hooks once per clone (REQUIRED before committing notebooks)
git config core.hooksPath .githooks

# Manually scrub a notebook (what pre-commit runs per staged .ipynb)
pwsh -File .githooks/scrub-fabric-notebook.ps1 path/to/notebook.ipynb

# Bypass the hooks if needed
git commit --no-verify
```

The scrubber requires PowerShell 7+ (`pwsh`) on PATH.

## Branching

A single self-contained commit goes straight to `main`. That is what every commit here has done (91 of them as of 2026-09-14, no feature branch ever), and for one notebook, one template, or one doc it stays correct — a branch buys no isolation and costs a merge. **Branch when the change spans more than one commit.** Name it per `~/.claude/CLAUDE.md` § "Branch naming", which is also where the general trigger lives; this section agrees with it and sharpens one half.

That half is the second condition, "an intermediate state would be broken while deployed". Here it reads **broken while public**: this repo is public and its artifacts are standalone deliverables rather than parts of a build, so a stranger can clone `main` at any commit and get whatever the intermediate state was. This repo's own history has the case — `53fd4a5` added the git hooks and `f27271e` marked them executable, so a POSIX clone taken between the two got hooks that silently did not run. Nothing about the final state being right makes that window not have existed.

A branch is also what makes `/land` usable: its preflight requires `git branch --show-current` to be something other than `main`, and its `--ff-only` integration preserves the logical commit split `/commit` just wrote instead of squashing it. So work heading for a PR wants a branch from its first commit, not a rescue branch cut afterwards.

## The push gate

This repo is public and [.githooks/pre-push](.githooks/pre-push) is the last thing between a commit and that. Two checks, both documented at length in the script header:

1. **identity-guard** — runs at `pre-commit` (staged additions, after the notebook scrub), `commit-msg` (the message, which nothing else reads and which cannot be fixed forward once pushed) and `pre-push` (messages and added lines of every commit no remote has). It calls the deployed `~/.claude/hooks/identity-guard.sh` rather than vendoring a copy, so there is one reader of the denylist at `~/.config/identity-denylist.txt`. Absent script or absent list → skipped, not failed.
2. **session gate** — refuses any push not issued from a Claude Code session (`CLAUDECODE=1`). The guard above matches only names already on its list; this covers the rest by making review a precondition. Nothing another harness wrote goes public unreviewed.

**When a push is blocked by the session gate, do not reach for the override or `--no-verify` on your own** — the override exists for a human who has reviewed the commits:

```bash
git -c fabrictools.push=reviewed push <same arguments>
```

Review the unpushed commits first (`git log -p @{u}..`), and if they are clean, push normally from the session — `CLAUDECODE=1` is already set there, so the gate passes without an override.

## Handoff briefs

Work that will outlive one session is written up as a brief,
`docs/handoffs/execute/<subject>.md` — named for its subject, with no date
or number, because the filename is the link target. The first one arrived
on 2026-10-12 and created the directory.
**Each brief holds its own state in frontmatter and no file lists the
queue**, so starting or landing one edits nothing a parallel session is
also editing:

```yaml
---
status: open
priority: 2
needs: []
blocked-by: []
written: 2026-09-30
---
```

`status` is `open` or `deferred`, and `deferred` adds a `reopen-when:`
trigger. `priority` is `1` now, `2` next, `3` later — buckets with no order
inside one, so briefs sharing a bucket can run in parallel. `needs` lists
what a session cannot supply (`user`, `tenant`, `desktop`, or a short
phrase) and `blocked-by` lists brief filenames beside this one. Plain
`key: value` or `key: [a, b]` only — a trailing comment or a quoted value
fails the check. The body restates none of it, and landing deletes the
brief in the commit that finishes its work, dropping its name from every
other `blocked-by`; git history is the archive.

The view comes from agent-config's `scripts/handoff-status.py`, run by path
from this repo's root. It reads and never writes, `--check` exits 1 on a
bad value, and a worktree named after a brief's filename stem shows that
brief as in flight:

```bash
uv run --no-project <agent-config>/scripts/handoff-status.py . --no-inbox
```

**A brief is committed, so it is public** — unlike the note it is usually
triaged from, since `~/handoff-inbox/fabric-tools/` is private and may be
raw. Cite client material by kind, never by name; identity-guard reads only
its list. `docs/handoffs/execute/README.md`, which arrived with the first
brief, holds no queue: it declares direction (local, inbound or both), what
public means for scrubbing, and whether these briefs are the whole backlog.

## The notebook-metadata invariant (most important rule)

Notebooks downloaded from Fabric carry workspace-bound metadata — default lakehouse GUIDs, `spark_compute.compute_id`, `a365ComputeOptions`, `sessionKeepAliveTimeout`, session settings — that **must never be committed**. [.githooks/scrub-fabric-notebook.ps1](.githooks/scrub-fabric-notebook.ps1) rewrites each staged `.ipynb` so only an allowlist survives:

- **Top-level metadata kept:** `language_info`, `kernel_info`, `microsoft` (Fabric uses `microsoft.language` to route `%%sql` / `%%pyspark`).
- **Per-cell metadata kept:** `microsoft` only. All cell `outputs` are emptied and `execution_count` reset to `null`.
- **Cell `source` normalized to array-of-strings.** Jupyter accepts a bare string; Fabric's notebook importer does not — it fails with `400 Bad Request` / `pbi.error.exceptionCulprit: 1` and no further detail. The scrubber re-shapes without altering text (joining the array reproduces the original exactly). Cells authored programmatically rather than round-tripped through Fabric are the usual source of the bare-string form.

The scrubber is idempotent and preserves Jupyter/Fabric key ordering to keep diffs minimal. `.gitattributes` pins `*.ipynb` to `eol=lf` so scrubbing stays idempotent regardless of `core.autocrlf`. When editing notebooks, do not reintroduce stripped keys.

## Architecture

### admin/ — SP provisioning (the `%run` module pattern)
[admin/nb_sp_common.ipynb](admin/nb_sp_common.ipynb) is the base module: it reads SP credentials (`tenantId`/`clientId`/`clientSecret`) from Azure Key Vault via `notebookutils.credentials.getSecret`, acquires a Fabric API token (MSAL / client-credentials, audience `https://api.fabric.microsoft.com`), and defines shared helpers (`get_access_token`, `get_capacity_id`, `get_item_id_by_name`, ...). The other three admin notebooks (`nb_sp_create_item`, `nb_sp_identity`, `nb_sp_mirror`) `%run` it in their first cell and call the helpers directly. Run `nb_sp_common` standalone only to test Key Vault / token plumbing.

### maintenance/ — Lakehouse ops, routine and destructive
Routine and idempotent: `nb_lh_optimize` (OPTIMIZE + VACUUM), `nb_lh_configure` (Delta `TBLPROPERTIES`, reads current values and skips unchanged tables), `nb_spark_config` (session tuning). Safe to schedule; these never mutate schema or item metadata.

`nb_lh_drop_tables` is the exception and the only destructive notebook in this directory: it bulk-drops Delta tables whose names match a SQL `LIKE` pattern, per schema. It defaults to `DRY_RUN = True` and refuses whole-schema wildcard patterns unless `ALLOW_FULL_SCHEMA` is set. Run it interactively, read the dry-run output, then opt in — never schedule it.

### utilities/ — CI/CD metadata feedback loop, plus tenant audits
`nb_extract_guids` enumerates workspace items and writes their GUIDs into a Fabric **Variable Library** (optionally via the Fabric REST API) so downstream items reference GUIDs by variable name instead of hardcoding them — the mechanism that makes dev/test/prod promotion work. `nb_migrate_items` bulk-migrates code artifacts between workspaces via the preview `exportItemDefinitions` / `importItemDefinitions` APIs — definitions only, no Lakehouse/Warehouse data, and non-destructive (source items stay put).

Two audit notebooks sit alongside them, both gated the same way as `nb_lh_drop_tables`: the report is read-only and every write is behind `DRY_RUN`. `nb_connection_audit` inventories data connections, flags stale ones by recency, renames them to a convention, and takes ownership only of connections the caller can already manage — it never self-escalates onto a connection it holds no role on. `nb_deployment_pipeline_audit` is tenant-wide and runs against the **admin** REST APIs (`api.powerbi.com` for `/admin`, `/pipelines`, `/groups`; Fabric for item counts), so it needs the Fabric Administrator role rather than membership on each pipeline; it maps every workspace to the deployment-pipeline stages pinning it, then optionally reclaims workspaces a pipeline is blocking (grant self Workspace Admin → unassign → delete). That reclaim runs in two phases with a session restart between them, because a workspace-admin grant only takes effect on a fresh sign-in — granting and unassigning in one session fails with a 401.

### integration/ — external-source reference patterns
Authenticate to a third-party API (secrets from Key Vault), extract, land in Fabric. Two shapes: `nb_salesforce_ingest` writes a Lakehouse Delta table with overwrite, so re-runs are idempotent (fork the write cell for merge semantics). `nb_syteline_ingest` (Infor CloudSuite Industrial, via the ION REST IDO API) reads entity definitions and incremental watermarks from a Warehouse control table and POSTs each batch straight into an Eventhouse table with **Kusto streaming ingestion**; it is a pure Python notebook, no Spark. Its *Transport* cell is the piece worth reading before forking it — the notebook used to produce CloudEvents to a schema-associated Eventstream custom endpoint, and that cell records why a notebook producer should not reach for an Eventstream (Event Hubs acks bytes rather than delivery, so the path can accept and silently drop three ways; a single scheduled producer writing to one destination uses none of what an Eventstream is for), what was genuinely given up, and when an Eventstream *is* still the right answer. Both transports were considered; only one survives, deliberately. These are reference patterns to fork, not production pipelines.

### local-cli/ — workstation CLI wrappers (templates, not run in-place)
[sql.sh](local-cli/sql.sh) (sqlcmd over any AAD T-SQL endpoint), [kql.sh](local-cli/kql.sh) (curl+jq over the Kusto REST API), [lake.sh](local-cli/lake.sh) (DuckDB over OneLake Delta), [dax.sh](local-cli/dax.sh) (curl+jq over the Power BI `executeQueries` API — DAX against a published semantic model), [report-png.sh](local-cli/report-png.sh) (curl+jq over `exportToFile`), [ido.sh](local-cli/ido.sh) (curl+jq over the Infor ION REST IDO API — the read half of `nb_syteline_ingest`), and [cosmos.sh](local-cli/cosmos.sh) (curl+jq over the Cosmos DB REST API — a live Cosmos DB in Fabric container). Unlike the notebooks, these run on a developer's machine and auth via the **Azure CLI session** (`az login`), no SP/SAS. They are meant to be copied into a client repo at `scripts/data/` — all resolve the repo root via `SCRIPT_DIR/../..`, so that two-deep location is load-bearing. `sql.sh` reads named `SQL_ENDPOINT_<NAME>` entries from `<repo>/.env` (bare `host/database` or ADO.NET string; legacy `SQL_CONNECTION_STRING` still honored); `kql.sh` reads `KUSTO_CLUSTER_URI` plus named `KUSTO_DATABASE_<NAME>` entries (`-e` picks one, `-l` lists them — one Eventhouse query URI serves every KQL database under it, so extra databases are entries against the same host, mirroring `SQL_ENDPOINT_<NAME>`; the original single-slot `KUSTO_DATABASE` still works); `dax.sh` and `report-png.sh` share `PBI_WORKSPACE_ID` (plus `PBI_SEMANTIC_MODEL_ID` or `_NAME` for `dax.sh`) on the `analysis.windows.net/powerbi/api` audience — the `_ID`/`_NAME` suffix is a rule, not a label: GUID-valued keys are stage-specific and take an `<ENV>_` prefix, name-valued keys survive promotion and stay bare; `lake.sh` takes connection details inline in the ABFSS URL. `ido.sh` is the one wrapper pointed at a non-Microsoft system: it reads `ION_*` connection details plus `KEY_VAULT_URI` from `.env` and the four ION credentials from Key Vault, and with no `-p`/`-f`/`-o` it rebuilds the *registered* request by reading `ingest.Control` through `sql.sh` — so `-E` picks which stage's control table the registration comes from, never which ERP is queried, and the two scripts must be copied together. `cosmos.sh` reads `COSMOS_DATABASE_<NAME>` entries holding item display names and looks each item's endpoint up through the Fabric API on every run — the host embeds the item GUID, so it is never stored — which costs it a second audience, `api.fabric.microsoft.com`, beside `cosmos.azure.com`. It never merges per-range results: a cross-partition TOP, ORDER BY, aggregate, DISTINCT or GROUP BY runs only on a single-range container and fails elsewhere by design, pointing at `-p` or `sql.sh`.

### git-sync/ — item definitions from code, warehouse sync checks, and updates from Git (templates, not run in-place)
[build_real_time_dashboard.py](git-sync/build_real_time_dashboard.py) writes a Real-Time dashboard's `RealTimeDashboard.json` from a spec of pages and tiles in the same file, so the script, not the portal, is the dashboard's authority. It is copied into a client repo at `scripts/git-sync/`, one copy per dashboard: `REPO` is `parents[2]`, the same two-deep rule as `local-cli/`. The binding is the only per-environment part — `databaseArtifactId` from an ItemReference in the workspace's Variable Library (each value set is an environment, and so is the default value set where no value set names the same environment), `database` from the KQL database's `.platform` logicalId — and `--database-id` covers a repo with no library. Ids are `uuid5(NAMESPACE, label)` and `serialize()` reproduces the portal's bytes (indent 2, CRLF, no final newline), so `--check` is a byte comparison and the CI drift guard; fed the origin estate's spec and library, the engine reproduced its committed file byte for byte (2026-10-12). `--test` runs each tile through `scripts/data/kql.sh -E <env> -d <item id> -r` and fails kql.sh's exit 3 too. `problems()` refuses what the portal rejects without its schema noticing — a multistat under 3 grid units per slot each way, off-grid and overlapping tiles — and any character beyond ASCII, because how the portal serializes one is still unobserved. The sample spec builds its own rows, so it runs against any database. The script is copied into client repos, so it names neither this repo nor its folders. What still needs a tenant is in the folder README's *Limits*.

Two PowerShell 7 scripts answer, in two halves, whether Fabric's Git sync will accept a warehouse change. [warehouse-build.ps1](git-sync/warehouse-build.ps1) runs the `dotnet build` of the warehouse's `.sqlproj` that the sync runs — no tenant, meant for a pre-commit hook and CI. [warehouse-deploy-report.ps1](git-sync/warehouse-deploy-report.ps1) calls it, diffs the dacpac against the live warehouse with `sqlpackage /Action:DeployReport`, counts each flagged table's rows, and exits **3** when the sync will refuse a change for data loss, 0 when it will go through, 1 when there is no answer: `kql.sh`'s shape. Copied together into a client repo at `scripts/git-sync/`, two-deep like `scripts/data/`. Keep both ASCII, since one non-ASCII byte makes PSScriptAnalyzer demand a BOM, and start no help-block line with a dot and a word, as a wrapped `.sqlproj` would: PowerShell reads it as an unknown help keyword and drops the whole block, so `Get-Help` prints only the syntax (pwsh 7.6, 2026-10-12). The report reads `SQL_ENDPOINT_<NAME>` from `.env` with its own PowerShell copy of `sql.sh`'s lookup — the convention's second reader, named in both headers and mapped rule by rule in [git-sync/warehouse-checks.md](git-sync/warehouse-checks.md) — so a change to that lookup lands in both. It signs `sqlpackage` in through `Active Directory Default` narrowed by `AZURE_TOKEN_CREDENTIALS=AzureCliCredential`, never `/AccessToken`, so no bearer reaches a command line. Its split of data-loss alerts into BLOCKING (the table has rows) and tolerated (it is empty) rests on observed sync behavior, against sqlpackage's documented default; warehouse-checks.md keeps documented and observed claims apart, and should go on doing so.

[update_from_git.py](git-sync/update_from_git.py) is the Source control pane's **Update all** from a shell: an agent that has pushed to the branch a development workspace tracks updates that workspace through the REST API and reads its Git status back, so the person is left only the steps the portal alone can take. It finds the workspace through the Variable Library by the dashboard generator's rules, reading an ItemReference's `workspaceId` — the library's second reader, named in both — refuses any environment its `GIT_SYNCED` setting does not list, and never sends a `conflictResolution`, so a conflict exits 3 with nothing changed. Its page, [update-from-git.md](git-sync/update-from-git.md), carries the agent workflow and the scope rule a client repo's agent instructions need; the script it was ported from ran as a person only, and the port itself has run only against a mock of the API.

### docs/ — repo-level docs and generated assets
`docs/social/` holds the GitHub social preview card. `social-preview.html` is the design source; `social-preview.png` is build output that happens to be tracked — never hand-edit it, re-render it (headless Edge recipe in [docs/social/README.md](docs/social/README.md)) and check the dimensions, because a wrong `--window-size` fails silently. GitHub does not read the committed file: the card has to be uploaded by hand under Settings → General → Social preview, so a re-render is only half the job.

## Conventions when editing notebooks

- **Placeholders, not values.** Environment-specific names appear as angle-bracket placeholders (`<KeyVaultName>`, `<ServicePrincipalName>`, `<ServicePrincipalClientIdSecretName>`). Keep that style; never commit real GUIDs, workspace names, or secret values.
- **Runtime identity:** use `notebookutils.runtime.context["currentWorkspaceId"]` (documented public API, works in pure-Python notebooks). Reserve `spark.conf.*` (e.g. `trident.workspace.id`) for Spark-session tuning, not identity resolution.
- **LRO-aware:** poll long-running Fabric REST operations to completion with timeout handling rather than fire-and-forget.
- **Cell style:** banner comments (`# ----` blocks) section the cells; functions carry `:param:`/`:returns:`/`:raises:` docstrings. Match the surrounding density.
- Token audience matters — `api.fabric.microsoft.com` for Fabric REST, `storage.azure.com` for OneLake (see the `fabric-auth` skill). Wrong audience is the #1 cause of 401s.

## Coding rules

Path-scoped conventions for T-SQL, Spark SQL, Python/PySpark, KQL, DAX, M, TMDL, and pipeline expressions live in the user-scope `~/.claude/rules/` and auto-load when a matching file is in scope. There is no project-scope override in this repo.
