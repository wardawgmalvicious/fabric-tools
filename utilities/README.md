# utilities/

Helper notebooks that support CI/CD and environment management. These are not workspace-provisioning tools - they extract metadata, transform it, and feed it back into Fabric Variable Libraries so downstream items can reference GUIDs by name.

## Contents

| Notebook | Purpose |
|---|---|
| [nb_extract_guids.ipynb](nb_extract_guids.ipynb) | Enumerate workspace items and write their GUIDs into a Fabric Variable Library. Supports multiple workspaces, multiple value sets, and `__current__` auto-resolution for the running workspace. Optionally updates the Variable Library via the Fabric REST API. |
| [nb_connection_audit.ipynb](nb_connection_audit.ipynb) | Inventory data connections, flag stale ones by recency, rename them to a naming convention, and take ownership of the ones the caller can already manage. `DRY_RUN`-gated. Bounded by the caller's connection/gateway rights - no self-escalation onto connections it has no role on. |

## Prerequisites

- Fabric notebooks runtime (PySpark)
- `notebookutils` (for current-workspace resolution)
- A Variable Library item in the target workspace (when `UPDATE_VARIABLE_LIBRARY = True`)
- SP or user token with write access to the Variable Library

## Usage Pattern

Variable Libraries let you reference items by variable name instead of hardcoding GUIDs - essential for promoting content across dev/test/prod. Run `nb_extract_guids` after creating or renaming items to keep the library in sync, then consume variables from pipelines, notebooks, and semantic models.
