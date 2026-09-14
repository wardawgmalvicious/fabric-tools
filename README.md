# fabric-tools

A collection of Microsoft Fabric notebooks, local CLI wrappers, and configuration guides for platform engineering - SP-first, Variable Library-driven, and CI/CD-ready.

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
├── maintenance/        # Lakehouse optimization, table settings, Spark configuration, bulk table drops
│   ├── nb_lh_configure.ipynb
│   ├── nb_lh_drop_tables.ipynb
│   ├── nb_lh_optimize.ipynb
│   ├── nb_spark_config.ipynb
│   └── README.md
├── integration/        # Reference patterns for ingesting from external systems
│   ├── nb_salesforce_ingest.ipynb
│   ├── nb_syteline_ingest.ipynb
│   └── README.md
├── utilities/          # GUID extraction, Variable Library management, workspace migration, tenant audits
│   ├── nb_connection_audit.ipynb
│   ├── nb_deployment_pipeline_audit.ipynb
│   ├── nb_extract_guids.ipynb
│   ├── nb_migrate_items.ipynb
│   └── README.md
├── guides/             # Reusable configuration guides for Fabric Copilot surfaces
│   ├── configure-ai-semantic-model.md
│   ├── configure-data-agent.md
│   └── README.md
├── local-cli/          # Local-workstation CLI wrappers (sqlcmd, DuckDB, curl + jq over REST) for ad-hoc Fabric data exploration
│   ├── .env.sample
│   ├── dax.sh
│   ├── kql.sh
│   ├── lake.sh
│   ├── report-png.sh
│   ├── sql.sh
│   └── README.md
├── docs/               # Repo-level documentation and generated assets
│   └── social/         # GitHub social preview card - HTML source plus the rendered PNG
├── .githooks/          # Opt-in git hooks - strip Fabric metadata from notebooks, gate what reaches a public remote
└── README.md
```

## Prerequisites

- Microsoft Fabric workspace with capacity assigned
- Azure Key Vault with service principal credentials stored as secrets
- Service principal with appropriate Fabric API permissions
- Fabric notebooks runtime (PySpark; a few notebooks are pure Python)
- For `local-cli/` only: Azure CLI (`az login`) on the workstation, plus `sqlcmd`, `duckdb`, `curl`, and `jq`. These wrappers authenticate as the signed-in user, not a service principal.

## Design Principles

- **SP-first**: All admin operations authenticate via service principal through Azure Key Vault - no interactive login dependencies.
- **Variable Library-driven**: GUIDs and environment-specific values are managed through Fabric Variable Libraries, not hardcoded in notebooks.
- **Idempotent where possible**: Maintenance operations (OPTIMIZE, VACUUM) are safe to re-run. Creation operations validate before acting. Destructive operations default to a dry run.
- **LRO-aware**: All long-running Fabric REST API operations are polled to completion with timeout handling.

## Getting Started

1. Clone or import these notebooks into your Fabric workspace.
2. Configure `nb_sp_common` with your Key Vault name and secret names.
3. Start with `admin/nb_sp_create_item.ipynb` to provision workspace items, or `maintenance/nb_lh_optimize.ipynb` to run table maintenance.
4. For querying Fabric from your own machine, copy `local-cli/` into a client repo at `scripts/data/` and its `.env.sample` to that repo's root as `.env`.

See each folder's README for detailed usage.

## Contributing

Three hooks live in [.githooks/](.githooks/). Activate them once per clone:

```bash
git config core.hooksPath .githooks
```

| Hook | What it does |
| --- | --- |
| `pre-commit` | Strips Fabric-injected metadata from staged notebooks (default lakehouse GUIDs, `spark_compute.compute_id`, `a365ComputeOptions`, session settings), resets cell `outputs` / `execution_count`, re-stages - then scans the staged additions for denylisted identity strings. Requires PowerShell 7+ (`pwsh`) on PATH when notebooks are staged. |
| `commit-msg` | Scans the commit message for the same strings. Nothing is committed yet, so this blocks cleanly - reword and commit again. |
| `pre-push` | Scans the messages and added lines of every commit no remote already has, then refuses any push not issued from a Claude Code session. |

The identity scan is the local denylist at `~/.config/identity-denylist.txt` (override with `IDENTITY_DENYLIST`), read by `~/.claude/hooks/identity-guard.sh` (override with `IDENTITY_GUARD`). It catches a client or employer name, a tenant or account name, a hardcoded profile path. The list lives outside every repo because the list is itself the thing that must not be committed; no list, or no guard script, means the scan is skipped rather than failing - so a fresh clone or CI still works.

The push gate exists because this repo is public and an agent that runs none of Claude Code's own hooks - GitHub Copilot, VS Code's Source Control view, a plain terminal - otherwise reaches `origin` with nothing in between. Git runs its own hooks whoever pushes. Having reviewed the commits yourself, push once with:

```bash
git -c fabrictools.push=reviewed push <same arguments>
```

Same syntax in Git Bash and PowerShell, and it lasts exactly one command - unlike a `git config` value or an environment variable, which would silently open the gate for every later push. `--no-verify` skips all three, as it skips every hook; these guard against accidents, not intent.

## License

MIT
