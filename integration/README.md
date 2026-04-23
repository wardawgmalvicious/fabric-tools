# integration/

Reference patterns for pulling data from external systems into a Fabric Lakehouse via notebooks. Unlike the `admin/` and `maintenance/` notebooks - which operate on Fabric itself - the notebooks here authenticate to a third-party system, extract, and land the result as a Delta table.

These are reference patterns, not production pipelines. Expect to fork and extend rather than run as-is.

## Contents

| Notebook | Source System | Purpose |
|---|---|---|
| [nb_salesforce_ingest.ipynb](nb_salesforce_ingest.ipynb) | Salesforce | Describes a Salesforce object via the REST API and writes its field metadata to a Lakehouse Delta table. Single-object focused - loop externally if you need to harvest many. |

## Prerequisites

- Fabric notebooks runtime (PySpark)
- Attached Lakehouse (schema-enabled recommended)
- Azure Key Vault holding the source-system credentials, with workspace identity granted `get` on secrets
- Network egress from Fabric to the source system's API (most public SaaS endpoints work out of the box; private/on-prem sources need a data gateway or VNet integration)

## Design Notes

- **Credentials in Key Vault, not the notebook.** Every notebook here reads secrets via `notebookutils.credentials.getSecret` - never hardcoded, never in notebook variables beyond the secret *name*.
- **Auth flow choice is documented per notebook.** Some source systems (like Salesforce) offer both legacy password-based and modern OAuth flows. The notebook's header cell calls out which flow it uses and when you'd want to switch.
- **Write pattern is always Delta + overwrite.** Re-runs are idempotent. If you need incremental / merge semantics, fork the write cell.
