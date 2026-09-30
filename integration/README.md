# integration/

Reference patterns for pulling data from external systems into Fabric via notebooks. Unlike the `admin/` and `maintenance/` notebooks - which operate on Fabric itself - the notebooks here authenticate to a third-party system, extract, and land the result in Fabric - as a Lakehouse Delta table, or as rows streamed straight into an Eventhouse table.

These are reference patterns, not production pipelines. Expect to fork and extend rather than run as-is.

## Contents

| Notebook | Source System | Purpose |
|---|---|---|
| [nb_salesforce_ingest.ipynb](nb_salesforce_ingest.ipynb) | Salesforce | Describes a Salesforce object via the REST API and writes its field metadata to a Lakehouse Delta table. Single-object focused - loop externally if you need to harvest many. |
| [nb_syteline_ingest.ipynb](nb_syteline_ingest.ipynb) | Infor CloudSuite Industrial (Syteline) | Metadata-driven ingestion via the ION REST IDO API: reads entity definitions and incremental watermarks from a Warehouse control table and writes each batch straight into an Eventhouse table with Kusto streaming ingestion. Pure Python (no Spark). |

## Prerequisites

- Fabric notebooks runtime (PySpark; `nb_syteline_ingest` is a pure Python notebook)
- Attached Lakehouse (schema-enabled recommended) for `nb_salesforce_ingest`; `nb_syteline_ingest` attaches none and instead needs a Warehouse for its control table and a KQL database for its landing tables (see the *Usage* steps in its header cell)
- Azure Key Vault holding the source-system credentials, with workspace identity granted `get` on secrets
- Network egress from Fabric to the source system's API (most public SaaS endpoints work out of the box; private/on-prem sources need a data gateway or VNet integration)

## Design Notes

- **Credentials in Key Vault, not the notebook.** Every notebook here reads secrets via `notebookutils.credentials.getSecret` - never hardcoded, never in notebook variables beyond the secret *name*.
- **Auth flow choice is documented per notebook.** Some source systems (like Salesforce) offer both legacy password-based and modern OAuth flows. The notebook's header cell calls out which flow it uses and when you'd want to switch.
- **Write pattern is Delta + overwrite** for Lakehouse-landing notebooks - re-runs are idempotent; fork the write cell for incremental / merge semantics. `nb_syteline_ingest` is the incremental variant: it streams each batch into an Eventhouse table itself and advances a per-entity watermark in a Warehouse control table only after the rows are committed, so a failed window is re-pulled on the next run and overlapping rows are deduplicated downstream. It used to produce CloudEvents to an Eventstream instead; its *Transport* cell records why that went, and when an Eventstream is still the right answer.
- **Optional Variable Library resolution.** Config values left blank (or as `<Placeholders>`) can resolve from a workspace Variable Library's active value set at run time - convenient for interactive runs across workspaces. SP / scheduled runs must pass explicit values instead: `notebookutils.variableLibrary` has no service-principal support.
