# Fabric Tools

A collection of reusable Microsoft Fabric notebooks for tenant provisioning, item management, and administration using Service Principal authentication.

## Notebooks

| Notebook | Description |
| --- | --- |
| `nb_spn_common` | Shared utilities — imports, Key Vault credential retrieval, access token acquisition, and helper functions. Referenced by all other notebooks via `%run`. |
| `nb_spn_create_item` | Create Fabric items (Workspaces, Lakehouses, Notebooks, Warehouses, Pipelines, Dataflows, SQL Databases, Variable Libraries, Eventhouses, Eventstreams, Ontologies, Reflexes). Supports single and batch item deployment. |
| `nb_spn_mirror` | Create and manage Mirrored Databases (Azure SQL, SQL MI, SQL Server, PostgreSQL, Cosmos DB) and Mirrored Databricks Catalogs. Includes connection validation and provisioning status polling. |
| `nb_spn_identity` | Manage item identities — associate the calling SPN/user/MI as the default identity for supported items (Lakehouse, Eventstream). Includes Warehouse takeover via Power BI API. |
| `nb_lh_optimize` | Lakehouse maintenance — Delta table optimization and vacuum operations. |
| `nb_extract_guids` | Extract workspace and item GUIDs for automation and configuration. |

## Prerequisites

- A Microsoft Fabric capacity with an active workspace
- An Entra ID Service Principal with Fabric API permissions
- An Azure Key Vault storing the SPN credentials (`FabricTenantId`, `FabricClientId`, `FabricClientSecret`)

## Usage

1. Upload the notebooks to a Fabric workspace
2. Update the Key Vault name in `nb_spn_common` to match your environment
3. Run any of the task-specific notebooks — each one calls `%run nb_spn_common` to load shared configuration and functions automatically
