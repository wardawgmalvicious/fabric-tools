# admin/

Service principal–driven notebooks for provisioning and managing Fabric workspace items. Every notebook here authenticates via SP credentials pulled from Azure Key Vault - no interactive login, no user-context calls.

## Contents

| Notebook | Purpose |
|---|---|
| [nb_sp_common.ipynb](nb_sp_common.ipynb) | Shared helpers: Key Vault access, SP token acquisition, workspace/capacity/item lookups. Imported by every other notebook in this folder via `%run`. |
| [nb_sp_create_item.ipynb](nb_sp_create_item.ipynb) | Create Fabric items (Lakehouse, Warehouse, Notebook, etc.) with SP, polling LROs to completion. |
| [nb_sp_identity.ipynb](nb_sp_identity.ipynb) | Inspect and manage workspace identities, role assignments, and SP membership. |
| [nb_sp_mirror.ipynb](nb_sp_mirror.ipynb) | Create and manage Mirrored Database items via SP. |
| [nb_sp_connections.ipynb](nb_sp_connections.ipynb) | Inventory data connections, grant a principal access (reshare), and rotate stored credentials. Bounded by the SP's own connection/gateway rights - no self-escalation. |

## Prerequisites

- Azure Key Vault containing the SP's `tenantId`, `clientId`, and `clientSecret` as secrets
- Service principal added to the target workspace with at least Contributor role
- Capacity assigned to the workspace
- Fabric notebooks runtime (PySpark)

## %run Dependency Graph

`nb_sp_common` is the base module - it loads libraries, fetches the SP credential bundle from Key Vault, and defines helper functions (`get_token`, `get_capacity_id`, `get_item_id_by_name`, ...). The other three notebooks `%run` it at the top of their first cell and then use the functions directly.

```
                    ┌─────────────────────┐
                    │    nb_sp_common     │
                    │  (Key Vault + SP   │
                    │   token + helpers)  │
                    └──────────┬──────────┘
                               │  %run
            ┌──────────────────┼──────────────────┐
            │                  │                  │
            ▼                  ▼                  ▼
  ┌──────────────────┐ ┌─────────────────┐ ┌────────────────┐
  │ nb_sp_create_    │ │ nb_sp_identity  │ │ nb_sp_mirror   │
  │ item             │ │                 │ │                │
  └──────────────────┘ └─────────────────┘ └────────────────┘
```

Run `nb_sp_common` standalone only when testing the Key Vault / token plumbing. For everything else, open one of the three downstream notebooks - the `%run` brings the common module in automatically.
