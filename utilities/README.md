# utilities/

Helper notebooks that support CI/CD, environment management, and tenant housekeeping. These are not workspace-provisioning tools - they read metadata that already exists, transform it, and either feed it back into Fabric (Variable Libraries, migrated item definitions) or report on it so you can act.

## Contents

### Metadata and migration

| Notebook | Purpose |
|---|---|
| [nb_extract_guids.ipynb](nb_extract_guids.ipynb) | Enumerate workspace items and write their GUIDs into a Fabric Variable Library. Supports multiple workspaces, multiple value sets, and `__current__` auto-resolution for the running workspace. Optionally updates the Variable Library via the Fabric REST API. |
| [nb_migrate_items.ipynb](nb_migrate_items.ipynb) | Bulk-migrate code artifacts (Notebooks, Pipelines, Semantic Models, Reports, KQL Dashboards, Spark Job Definitions) between workspaces via the preview `exportItemDefinitions` / `importItemDefinitions` APIs. Definitions only - no Lakehouse/Warehouse data - and non-destructive; source items stay put. For one-shot workspace splits and cleanups, not ongoing promotion. Chain `nb_extract_guids` against the target afterwards: the migrated items get new GUIDs. |

### Audits (read-only report, writes behind `DRY_RUN`)

| Notebook | Purpose |
|---|---|
| [nb_connection_audit.ipynb](nb_connection_audit.ipynb) | Inventory data connections, flag stale ones by recency, rename them to a naming convention, and take ownership of the ones the caller can already manage. Bounded by the caller's connection/gateway rights - no self-escalation onto connections it has no role on. |
| [nb_deployment_pipeline_audit.ipynb](nb_deployment_pipeline_audit.ipynb) | Tenant-wide map of every workspace to the deployment-pipeline stage(s) pinning it, with cleanup flags (`ON_PIPELINE`, `EMPTY`, `OFF_CAPACITY`, `NO_ADMIN`, non-Active states). Optionally reclaims workspaces a pipeline is blocking: grant self Workspace Admin, unassign from all stages, delete. Runs on the admin REST APIs, so it needs the **Fabric Administrator** role rather than membership on each pipeline. |

## Prerequisites

- Fabric notebooks runtime (PySpark)
- `notebookutils` (for current-workspace resolution and token acquisition)
- A Variable Library item in the target workspace (`nb_extract_guids`, when `UPDATE_VARIABLE_LIBRARY = True`)
- SP or user token with write access to the Variable Library
- SP with Contributor on **both** workspaces, plus the *Service principals can use Fabric APIs* tenant setting (`nb_migrate_items`)
- Fabric Administrator role in Entra (`nb_deployment_pipeline_audit`)

## Usage Pattern

Variable Libraries let you reference items by variable name instead of hardcoding GUIDs - essential for promoting content across dev/test/prod. Run `nb_extract_guids` after creating or renaming items to keep the library in sync, then consume variables from pipelines, notebooks, and semantic models.

The audit notebooks run in the other direction: they report first and only write when you explicitly disable the gates. Read the report, decide, then re-run with the gate flipped. `nb_deployment_pipeline_audit`'s reclaim additionally runs in two phases - `RECLAIM_PHASE = "grant"`, then a session restart, then `"execute"` - because a workspace-admin grant only takes effect on a fresh sign-in; granting and unassigning in one session fails with a 401.
