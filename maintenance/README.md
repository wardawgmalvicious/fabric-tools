# maintenance/

Operational notebooks for keeping Fabric Lakehouses and Spark workloads healthy.

## Contents

### Routine (idempotent, schedule-safe)

These operations are idempotent and do not mutate schema or item metadata - safe to put on a timer.

| Notebook | Purpose |
|---|---|
| [nb_lh_optimize.ipynb](nb_lh_optimize.ipynb) | Run `OPTIMIZE` (with optional V-Order / Z-order) and `VACUUM` across all Delta tables in a Lakehouse. Compacts small files to keep the SQL Endpoint fast. |
| [nb_lh_configure.ipynb](nb_lh_configure.ipynb) | Apply Delta `TBLPROPERTIES` (Change Data Feed, auto-compact, deleted-file retention) across all Delta tables in a Lakehouse. Idempotent - skips tables already at the target values. |
| [nb_spark_config.ipynb](nb_spark_config.ipynb) | Apply Spark session configuration - pool settings, runtime tuning, native execution toggles. |

### Destructive (manual, dry-run first)

These *remove* tables. Run interactively, review the dry-run output, then opt in to the live run. **Do not schedule.**

| Notebook | Purpose |
|---|---|
| [nb_lh_drop_tables.ipynb](nb_lh_drop_tables.ipynb) | Bulk-drop Delta tables whose names match a SQL `LIKE` pattern, per schema. Defaults to `DRY_RUN = True`; refuses whole-schema wildcard patterns unless `ALLOW_FULL_SCHEMA` is set. For tearing down staging output or cleaning up after a failed load. |

## Prerequisites

- Fabric notebooks runtime (PySpark)
- Attached Lakehouse (for `nb_lh_optimize` and `nb_lh_configure`)
- Appropriate workspace role to write to the target Lakehouse tables

## When to Run

- **nb_lh_optimize**: schedule weekly, or after large ETL loads. Small-file fragmentation is the #1 cause of slow SQL Endpoint queries. Aim for 128 MB – 1 GB per Parquet file.
- **nb_lh_configure**: one-time, or after onboarding new tables. Re-run is cheap - current properties are read first and unchanged tables are skipped.
- **nb_spark_config**: run at session start, or bake into a pipeline's preamble notebook.
