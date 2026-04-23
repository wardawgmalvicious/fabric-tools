# admin/

Service principal–driven notebooks for provisioning and managing Fabric workspace items. Every notebook here authenticates via SPN credentials pulled from Azure Key Vault - no interactive login, no user-context calls.

## Contents

| Notebook | Purpose |
|---|---|
| [nb_spn_common.ipynb](nb_spn_common.ipynb) | Shared helpers: Key Vault access, SPN token acquisition, workspace/capacity/item lookups. Imported by every other notebook in this folder via `%run`. |
| [nb_spn_create_item.ipynb](nb_spn_create_item.ipynb) | Create Fabric items (Lakehouse, Warehouse, Notebook, etc.) with SPN, polling LROs to completion. |
| [nb_spn_identity.ipynb](nb_spn_identity.ipynb) | Inspect and manage workspace identities, role assignments, and SPN membership. |
| [nb_spn_mirror.ipynb](nb_spn_mirror.ipynb) | Create and manage Mirrored Database items via SPN. |

## Prerequisites

- Azure Key Vault containing the SPN's `tenantId`, `clientId`, and `clientSecret` as secrets
- Service principal added to the target workspace with at least Contributor role
- Capacity assigned to the workspace
- Fabric notebooks runtime (PySpark)

## %run Dependency Graph

`nb_spn_common` is the base module - it loads libraries, fetches the SPN credential bundle from Key Vault, and defines helper functions (`get_token`, `get_capacity_id`, `get_item_id_by_name`, ...). The other three notebooks `%run` it at the top of their first cell and then use the functions directly.

```
                    ┌─────────────────────┐
                    │   nb_spn_common     │
                    │  (Key Vault + SPN   │
                    │   token + helpers)  │
                    └──────────┬──────────┘
                               │  %run
            ┌──────────────────┼──────────────────┐
            │                  │                  │
            ▼                  ▼                  ▼
  ┌──────────────────┐ ┌─────────────────┐ ┌────────────────┐
  │ nb_spn_create_   │ │ nb_spn_identity │ │ nb_spn_mirror  │
  │ item             │ │                 │ │                │
  └──────────────────┘ └─────────────────┘ └────────────────┘
```

Run `nb_spn_common` standalone only when testing the Key Vault / token plumbing. For everything else, open one of the three downstream notebooks - the `%run` brings the common module in automatically.
