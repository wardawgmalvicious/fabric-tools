# fabric-tools

A collection of Microsoft Fabric notebooks for platform engineering - SP-first, Variable Library-driven, and CI/CD-ready.

Most community Fabric content assumes interactive user authentication and manual portal clicks. This toolkit takes the opposite approach: everything runs via service principal, everything is parameterized, and everything is designed to slot into automated pipelines.

## Repository Structure

```
fabric-tools/
├── admin/              # SP-based workspace provisioning, item creation, identity, mirroring
│   ├── nb_sp_common.ipynb
│   ├── nb_sp_create_item.ipynb
│   ├── nb_sp_identity.ipynb
│   ├── nb_sp_mirror.ipynb
│   └── README.md
├── maintenance/        # Lakehouse optimization, Spark configuration, table settings
│   ├── nb_lh_configure.ipynb
│   ├── nb_lh_optimize.ipynb
│   ├── nb_spark_config.ipynb
│   └── README.md
├── integration/        # Reference patterns for ingesting from external systems
│   ├── nb_salesforce_ingest.ipynb
│   └── README.md
├── utilities/          # GUID extraction, Variable Library management
│   ├── nb_extract_guids.ipynb
│   ├── nb_migrate_items.ipynb
│   └── README.md
├── guides/             # Reusable configuration guides for Fabric Copilot surfaces
│   ├── configure-ai-semantic-model.md
│   ├── configure-data-agent.md
│   └── README.md
├── local-cli/          # Local-workstation CLI wrappers (sqlcmd, DuckDB) for ad-hoc Fabric data exploration
│   ├── lake.sh
│   ├── sql.sh
│   └── README.md
├── .githooks/          # Opt-in pre-commit hook that strips Fabric metadata from notebooks
└── README.md
```

## Prerequisites

- Microsoft Fabric workspace with capacity assigned
- Azure Key Vault with service principal credentials stored as secrets
- Service principal with appropriate Fabric API permissions
- Fabric notebooks runtime (PySpark)

## Design Principles

- **SP-first**: All admin operations authenticate via service principal through Azure Key Vault - no interactive login dependencies.
- **Variable Library-driven**: GUIDs and environment-specific values are managed through Fabric Variable Libraries, not hardcoded in notebooks.
- **Idempotent where possible**: Maintenance operations (OPTIMIZE, VACUUM) are safe to re-run. Creation operations validate before acting.
- **LRO-aware**: All long-running Fabric REST API operations are polled to completion with timeout handling.

## Getting Started

1. Clone or import these notebooks into your Fabric workspace.
2. Configure `nb_sp_common` with your Key Vault name and secret names.
3. Start with `admin/nb_sp_create_item.ipynb` to provision workspace items, or `maintenance/nb_lh_optimize.ipynb` to run table maintenance.

See each folder's README for detailed usage.

## Contributing

Notebooks downloaded from Fabric carry workspace-bound metadata - default lakehouse GUIDs, `spark_compute.compute_id`, `a365ComputeOptions`, and session settings - that should not be committed. A pre-commit hook in [.githooks/](.githooks/) strips this metadata automatically (and resets cell `outputs` / `execution_count`) on every commit.

Activate it once per clone:

```bash
git config core.hooksPath .githooks
```

The hook requires PowerShell 7+ (`pwsh`) on PATH. Bypass with `git commit --no-verify` if needed.

## License

MIT
