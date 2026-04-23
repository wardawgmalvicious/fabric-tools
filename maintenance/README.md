# maintenance/

Operational notebooks for keeping Fabric Lakehouses and Spark workloads healthy. Safe to run on a schedule - the operations here are idempotent and do not mutate schema or item metadata.

## Contents

| Notebook | Purpose |
|---|---|
| [nb_lh_optimize.ipynb](nb_lh_optimize.ipynb) | Run `OPTIMIZE` (with optional V-Order / Z-order) and `VACUUM` across all Delta tables in a Lakehouse. Compacts small files to keep the SQL Endpoint fast. |
| [nb_lh_configure.ipynb](nb_lh_configure.ipynb) | Apply Delta `TBLPROPERTIES` (Change Data Feed, auto-compact, deleted-file retention) across all Delta tables in a Lakehouse. Idempotent - skips tables already at the target values. |
| [nb_spark_config.ipynb](nb_spark_config.ipynb) | Apply Spark session configuration - pool settings, runtime tuning, native execution toggles. |

## Prerequisites

- Fabric notebooks runtime (PySpark)
- Attached Lakehouse (for `nb_lh_optimize` and `nb_lh_configure`)
- Appropriate workspace role to write to the target Lakehouse tables

## When to Run

- **nb_lh_optimize**: schedule weekly, or after large ETL loads. Small-file fragmentation is the #1 cause of slow SQL Endpoint queries. Aim for 128 MB – 1 GB per Parquet file.
- **nb_lh_configure**: one-time, or after onboarding new tables. Re-run is cheap - current properties are read first and unchanged tables are skipped.
- **nb_spark_config**: run at session start, or bake into a pipeline's preamble notebook.
