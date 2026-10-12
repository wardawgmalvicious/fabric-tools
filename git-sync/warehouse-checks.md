# Warehouse sync checks

Checks for a Fabric Warehouse kept in Git. Every sync builds the
warehouse's SQL project and then deploys it, and either step can refuse a
change that ran fine over sqlcmd.
[warehouse-build.ps1](warehouse-build.ps1) and
[warehouse-deploy-report.ps1](warehouse-deploy-report.ps1) run both steps
on your own machine first, so the refusal comes at commit or push time
rather than from the portal later.

Like [local-cli/](../local-cli/), these are templates: copy them into a
client repo at `scripts/git-sync/` and use them there. They need
PowerShell 7, and sign in as your Azure CLI session, never with a stored
credential.

## Two halves of one question

Both answer *will Fabric's Git sync accept this warehouse change?*, and
neither can stand in for the other:

| | `warehouse-build.ps1` | `warehouse-deploy-report.ps1` |
| --- | --- | --- |
| Answers | will the sync's build reject it? | will the sync's deploy refuse it for data loss? |
| Needs | the .NET SDK; no tenant | `sqlpackage`, `az`, `sqlcmd` and a live warehouse |
| Runs | in a pre-commit hook and in CI | by hand, before pushing a schema change |
| Exit status | 0 builds; 1 does not | 0 will sync; 3 will be refused; 1 no answer |

The report runs the build first and diffs the dacpac it leaves. Shipped
alone, the build would give exactly the false confidence the report exists
to remove: a change that loses data builds green and is then refused at
sync.

### warehouse-build.ps1 — what the sync's build rejects

Fabric validates the warehouse's SQL project when you commit to Git or
update from it, and a project it cannot build fails the operation
([Git integration](https://learn.microsoft.com/fabric/data-warehouse/git-integration),
[troubleshooting](https://learn.microsoft.com/fabric/data-warehouse/troubleshoot-git-integration)).
That build checks references the engine never does, so T-SQL that runs
fine over sqlcmd can still fail the sync. A local `dotnet build` of the
same project catches the same things:

- `SQL71501`, an unresolved reference, such as a column dropped while a
  proc or view still names it.
- A type looked up by name, in the wrong case. The default collation is
  case-sensitive
  ([collation](https://learn.microsoft.com/fabric/data-warehouse/collation)),
  and so is the portal's project, `<ModelCollation>1033, CS`. `SYSNAME`
  failed a whole branch-out in a client estate, and builds here as
  `SQL71501: ... unresolved reference to Built-in Type [dbo].[SYSNAME]`.
  Keywords such as `INT` and `VARCHAR` build in any case.
- A three-part reference to the warehouse's own object, and a cyclic
  reference between warehouse items.
- A stale `Microsoft.Build.Sql` SDK version in the `.sqlproj`, as
  `MSB4019`.

The `.sqlproj` is the portal's: it is rewritten when a commit from the
workspace completes, so *A newer version of Microsoft.Build.Sql is
available* is expected and not a finding. Its SDK version is the one hand
edit Microsoft documents, and a stale one fails commits, updates and
branch-outs alike. `0.1.19-preview` fails with `MSB4019`, a missing
`NuGet.Build.Tasks.Pack.targets`, and `2.3.0-preview.2` builds under the
.NET SDK 10 locally and 8 in CI.

The error count is of distinct lines, because MSBuild prints every error
twice, as it happens and again in its summary; counted so, it matches
MSBuild's own *N Error(s)*. A zero exit with no dacpac is a failure. The
dacpac is found by the `.sqlproj` file's name, because it never sits
alone: the FabricDw package reference copies `master.dacpac` beside it on
every build.

Zero errors means green only for a folder of item definitions. Ad-hoc
`.sql` files left in the `*.Warehouse` folder are built too, and in a
client estate raised 13 `SQL71006` and `SQL70001` errors that Fabric's
own build left out. The portal deletes them from there anyway, so keep
them elsewhere.

### warehouse-deploy-report.ps1 — what the sync's deploy refuses

A warehouse's Git sync deploys with `BlockOnPossibleDataLoss = true`, so a
change that once synced with a "data will be lost" warning now fails
outright:

```text
DataLoss: The column [s].[t].[c] is being dropped
Msg 50000 ... Rows were detected. The schema update is terminating.
```

Learn documents that setting for
[deployment pipelines](https://learn.microsoft.com/fabric/data-warehouse/deploy-pipelines)
but not for Git sync, where it was observed in September 2026, and no
setting to change it was found. The remedy is to run the destructive half
by hand against the live warehouse **before** syncing, so the plan
carries no drop and no guard. The report says whether that is needed and
prints what to run.

A
[DeployReport](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-deploy-drift-report)
is a diff, not a deploy: it writes the plan as XML and executes nothing,
so pointing the report at production is safe. It flags data loss
**structurally** and never reads the data, while the guard the sync ran
fires only on a table with rows, `IF EXISTS (SELECT TOP 1 1 FROM
[s].[t])`. An empty table synced, and nulling the column first changed
nothing. So the report counts each flagged table's rows and splits its
findings:

| Finding | Means | Exit |
| --- | --- | --- |
| BLOCKING | an alert on a table with rows: the sync **will** fail | 3 |
| tolerated | an alert on an empty table: the sync will succeed | 0 |

Without the split the report would cry wolf on every empty table, which
is how a checker stops being trusted. The split rests on what the sync
was seen to do, though: sqlpackage's own
[documentation](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-deploy-drift-report)
says the setting blocks "regardless if the target database contains
data". It is the one place the report could pass a change the sync then
refuses, so tolerated alerts are always printed.

Two rules keep a reworded or unreadable report from passing as clean.
Alert text the parser does not recognize is a BLOCKING finding, printed
with its alert's name, since some texts mean nothing alone: a
`DataMotion` alert is only the name of a table the sync will rebuild. And
a table whose rows could not be counted is treated as having rows. Wrong
that way costs a needless check; the other way lets a failing sync
through.

The alert texts it reads, each an `<Issue Value="...">` under
`<Alert Name="DataIssue">` (sqlpackage 170.5.96):

- A drop names the column three-part and bracketed: `The column
  [s].[Orders].[Note] is being dropped, data loss could occur.`
- A type change names the column bare and brackets only the table, with
  two spaces before each type: `The type for column Customer in table
  [s].[Orders] is currently  VARCHAR (20) NOT NULL but is being changed
  to  VARCHAR (10) NOT NULL. Data loss could occur ...`
- A `NOT NULL` column added without a default reads `The column
  [s].[t].[c] on table [s].[t] must be added, but the column has no
  default value ...`. The parser leaves it unrecognized, so it always
  blocks: Fabric Warehouse can only `ADD` a nullable column
  ([ALTER TABLE](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql?view=fabric)).

A `]` inside a bracketed name comes doubled in the alert text, as bracket
quoting doubles it (`[s].[o'brien]]s]`), and stays doubled, so the name
goes back into T-SQL as it came. The row-count query also doubles any
`'`, and counts with `COUNT_BIG`: one table past 2,147,483,647 rows would
fail an `int` `COUNT` for every table at once.

What it prints to run:

- For a dropped column, a literal `ALTER TABLE ... DROP COLUMN` to run
  live first, behind a warning to capture the data, since nothing else
  protects it.
- For a narrowed column, the CTAS swap. Fabric Warehouse cannot reduce a
  column's size, even through the preview `ALTER COLUMN`
  ([ALTER TABLE](https://learn.microsoft.com/sql/t-sql/statements/alter-table-transact-sql?view=fabric)),
  so create the new shape, copy the rows, drop the original, `sp_rename`
  the replacement, and re-add constraints and security. The swap destroys
  the table's time-travel history
  ([time travel](https://learn.microsoft.com/fabric/data-warehouse/time-travel))
  and its GRANT/DENY.
- For anything unrecognized, its text and no remedy.

It cannot see a change that is not in the project. The report diffs with
sqlpackage's default `DropObjectsNotInSource = false`, so a live object
nobody committed is invisible to it.

### Signing in with no token on a command line

`sqlpackage` signs in through SqlClient
([authentication](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage#authentication)),
so the report hands it a connection string with
`Authentication=Active Directory Default` rather than a token on
`/AccessToken`, where any process listing could read it. That method
tries environment, workload identity, managed identity and developer-tool
credentials in turn
([default authentication](https://learn.microsoft.com/sql/connect/ado-net/sql/azure-active-directory-authentication#use-default-authentication)),
so for the length of the call the report sets
`AZURE_TOKEN_CREDENTIALS=AzureCliCredential`
([credential chains](https://learn.microsoft.com/dotnet/azure/sdk/authentication/credential-chains)),
narrowing the chain to the Azure CLI session `sqlcmd` already uses for the
row counts, then restores whatever was there.

What that costs, measured against a client warehouse on 2026-10-01:

- **About 30 s a report.** 50 s against 21 s with `/AccessToken`, warm,
  and 63.5 s for the first run, for the same report.
- **A version floor.** `Azure.Identity` honors one credential name from
  1.15.0, and a `sqlpackage` bundling an older one ignores the narrowing
  and falls back to the whole chain without an error. 170.5.96 bundles
  1.17.1; the `Azure.Identity.dll` under
  `~/.dotnet/tools/.store/microsoft.sqlpackage/` gives yours.

With no Azure CLI session, `sqlpackage` retried the sign-in 8 times over
13 min 39 s before failing (2026-10-01), which looks like a hang. So the
report probes for a token on `https://database.windows.net/` first, and
with none runs `az login --allow-no-subscriptions --scope
https://database.windows.net/.default`, as local-cli's scripts do; their
[auth notes](../local-cli/README.md#all-of-them-log-you-in-automatically)
explain both flags. `AZURE_TENANT_ID`, from the environment or `.env`,
pins the tenant. `SKIP_AZ_LOGIN=1` skips the login, and unlike in
local-cli, the report then stops at once rather than hand `sqlpackage` a
sign-in it would retry for 13 minutes.

### Exit status

| Code | `warehouse-build.ps1` | `warehouse-deploy-report.ps1` |
| --- | --- | --- |
| 0 | the project builds | the sync will go through, or every alert is on an empty table |
| 3 | — | the sync will be refused: at least one BLOCKING finding |
| 1 | it does not build, or could not run | no answer: no project, endpoint or login, a failed build, a `sqlpackage` error |

A failure exits 1 whatever the failing tool's own code was, so 3 always
means a finding. It is the shape of local-cli's
[kql.sh](../local-cli/README.md#kqlsh--how-it-works): 0 clean, 3 flagged,
anything else no answer. The build has no 3 because `dotnet` cannot give
it one: an unreachable package source fails it with exit 1 and a coded
error line, `MSB4236`, just as a project error does.

## Required tools

```powershell
winget install Microsoft.PowerShell          # pwsh 7, for both scripts
winget install Microsoft.DotNet.SDK.8        # or later; restores Microsoft.Build.Sql from NuGet
dotnet tool install -g microsoft.sqlpackage  # the report only; see the version floor above
winget install Microsoft.AzureCLI            # the report only
winget install Microsoft.Sqlcmd              # the report only: go-sqlcmd, for the row counts
```

`az` and `sqlcmd` are the two
[local-cli](../local-cli/README.md#required-cli-tools) already lists.
Without `sqlcmd` the report still runs, and treats every alert as
blocking.

## Deployment into a client repo

1. Copy both scripts into the client repo, together:

   ```text
   <client-repo>/scripts/git-sync/warehouse-build.ps1
   <client-repo>/scripts/git-sync/warehouse-deploy-report.ps1
   ```

   Two deep, like local-cli's `scripts/data/`: the report reads `.env`
   two levels up and calls `warehouse-build.ps1` beside itself.

2. The build needs nothing else. It takes the one `*.Warehouse/*.sqlproj`
   git tracks, or `-Project`, and the portal's `.gitignore` inside the
   `.Warehouse` folder already ignores the `bin/` and `obj/` it writes.

3. Point the report at the warehouse. It reads the `SQL_ENDPOINT_<NAME>`
   entries local-cli's `sql.sh` reads, from the same `.env` at the repo
   root, so a repo with local-cli needs nothing new. Otherwise copy
   [local-cli/.env.sample](../local-cli/.env.sample) there as `.env` and
   fill in the warehouse:

   ```env
   SQL_ENDPOINT_WAREHOUSE=<xxx>.datawarehouse.fabric.microsoft.com/<WarehouseName>
   ```

   Or skip `.env` and pass `-Server` and `-Database`.

4. Wire the build into a [pre-commit hook](#pre-commit-hook) and
   [CI](#ci-workflow). Portal commits are pushed by the service and run
   no local hook, so CI is the enforcement point and the hook is the fast
   feedback.

5. Optionally, tell the repo's AI tools the scripts exist with the
   [snippet below](#ai-tool-instruction-snippet), in the same file as
   local-cli's.

## Usage

```powershell
# Build the warehouse project, as the sync will
pwsh -NoProfile -File scripts/git-sync/warehouse-build.ps1

# A named project, one line of output on success
pwsh -NoProfile -File scripts/git-sync/warehouse-build.ps1 -Project ./<WarehouseName>.Warehouse -Quiet

# Will the dev warehouse accept this schema change?
pwsh -NoProfile -File scripts/git-sync/warehouse-deploy-report.ps1 -Environment dev

# A named .env entry, without rebuilding, keeping the raw XML
pwsh -NoProfile -File scripts/git-sync/warehouse-deploy-report.ps1 -Endpoint warehouse -SkipBuild -ReportPath ./plan.xml

# No .env: name the warehouse directly
pwsh -NoProfile -File scripts/git-sync/warehouse-deploy-report.ps1 -Server <xxx>.datawarehouse.fabric.microsoft.com -Database <WarehouseName>
```

**Full parameter names only.** `sql.sh` takes `-E <env>` and
`-e <entry>`, but PowerShell parameter names are case-insensitive, so
those two would be one parameter, and with `-Environment` and `-Endpoint`
both defined, `-E` is an ambiguous prefix.

Which warehouse to compare against depends on where the branch is
heading: the one its merge will sync to answers "will my PR sync". That
is also why the report stays out of CI, which would need a live
warehouse, a credential, and a target that changes with the branch.

## One .env convention, two readers

The report reads `.env` with its own copy of `sql.sh`'s lookup, because a
PowerShell script can reach `sql.sh` only through Git Bash, and on
Windows the `bash` on `PATH` can be the WSL launcher. Every rule below
lives in both, so a change to one is a change to both; both headers say
so.

| Rule | `sql.sh` | `warehouse-deploy-report.ps1` |
| --- | --- | --- |
| A key's value: the first line starting `KEY=`, everything after the first `=`, carriage returns dropped, nothing trimmed | `env_value` | `Get-EnvValue` |
| `<ENV>_<KEY>` first, then the bare `<KEY>` | `cfg_value` | `Get-ConfigValue` |
| Environment: the flag, then `FAB_ENV`, then `ENV_DEFAULT`, upper-cased | after the argument loop | `-Environment`, then the same |
| Entry: the flag, then `SQL_ENDPOINT_DEFAULT`, then the only entry, the environment's before the bare ones | after the argument loop, with `list_endpoints` | `-Endpoint`, then the same, with `Get-EndpointName` |
| An entry's key: the name upper-cased, then as given | after the entry is picked | the same |
| The legacy `SQL_CONNECTION_STRING`, bare only | after the entry lookup | the same |
| Two value shapes: ADO.NET, found by its `Server=` key, else `<host>[/<database>]` | the `grep -qiE` branch | `Split-EndpointValue` |
| A database override | `-d` | `-Database` |
| No `.env` at all | — | `-Server` with `-Database` |

On 2026-10-12, 22 `.env` files and flag sets went through both, covering
every rule above plus CRLF line endings, duplicate keys and commented-out
entries, and both resolved the same server and database, or failed
alike.

## How far this has been checked

The scripts this folder was ported from ran in a client estate: the build
in a pre-commit hook and CI from September 2026, and the report live on
2026-10-01 against a sandbox warehouse, where:

- a dropped column on a 240-row table was BLOCKING, with its `ALTER`;
- the same drop on an empty table was tolerated;
- a narrowed `varchar` was BLOCKING, with the CTAS guidance;
- a `NOT NULL` column with no default was BLOCKING, beside a `DataMotion`
  alert naming the table the sync would rebuild, in 57 to 66 s;
- the unmodified project gave "no differences" in 58 s.

The port changes how the project and endpoint are found, the login, and
the exit code for a refusal. It was checked offline on 2026-10-12 against
a synthetic project shaped like the portal's (.NET SDK 10.0.401,
Microsoft.Build.Sql 2.3.0-preview.2, sqlpackage 170.5.96):

- **The build**, for real: a clean project, `SQL71501`, `SYSNAME`,
  `MSB4019` and an unreachable package source, each error count equal to
  MSBuild's; project discovery with one, two and no tracked projects and
  an untracked copy; `-Configuration`, `-NoBuild`, and a leftover dacpac.
- **Real DeployReports**, from `sqlpackage /TargetFile` diffing variant
  dacpacs against the baseline: every alert text above, the doubled `]`,
  and the empty `<Alerts />` with no `<Operations>` of a report with
  nothing to say.
- **The report end to end**, in 42 cases, with stand-ins for `az`,
  `sqlpackage` and `sqlcmd` replaying those reports: every exit path,
  strict mode on an empty report, the narrowed sign-in and its restore,
  temp-file cleanup, the login flow, and both endpoint routes.
- **The `.env` parity** above.

Then live, on 2026-10-12, against the same client's sandbox warehouse,
through `-Server` and `-Database`, the narrowed sign-in and the project
the build found on its own:

- the unmodified project gave "no differences", exit 0, in 65 s with the
  build;
- a column dropped from an empty table was tolerated, its row count read
  live, exit 0, in 62 s;
- a column dropped from a 1,280-row table was BLOCKING with its `ALTER`,
  beside that tolerated one, exit 3, in 47 s.

Not run live: the `.env` route, checked against `sql.sh` instead, and the
interactive login, checked with a stand-in for `az`.

## Pre-commit hook

Add this stanza to `.githooks/pre-commit`, or save it as that file and
run `git config core.hooksPath .githooks` once per clone. It runs only
when a staged path is warehouse SQL or a `.sqlproj`, and where `pwsh` is
missing it says so and skips, since CI still runs the build.

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
STAGED="$(git diff --cached --name-only)"
STATUS=0

# --- Warehouse project build --------------------------------------------------
# Fabric runs this same build on sync and validates references the engine never
# checks, so a build error here is a sync that would be rejected. It cannot say
# a change will be refused for data loss: before pushing a schema change, run
# scripts/git-sync/warehouse-deploy-report.ps1.
if grep -qE '\.Warehouse/.*\.sql$|\.sqlproj$' <<<"$STAGED"; then
    if command -v pwsh >/dev/null 2>&1; then
        if ! pwsh -NoProfile -File "$REPO_ROOT/scripts/git-sync/warehouse-build.ps1" -Quiet; then
            echo >&2
            echo "pre-commit: the warehouse project does not build." >&2
            echo "            Fabric runs this same build on sync, so committing this fails there too." >&2
            echo "            Fix the build, or --no-verify if you know why." >&2
            STATUS=1
        fi
    else
        echo "pre-commit: pwsh not found; skipping the warehouse build." >&2
        echo "            CI will still run it." >&2
    fi
fi

exit $STATUS
```

## CI workflow

Save as `.github/workflows/build-warehouse.yml` and replace the project
path. It runs on every pull request and every push to `main` with no
path filter, on purpose: a merge can bring back a broken reference from
another branch. The token is read-only, and each action is pinned to the
commit its `v4` tag pointed at on 2026-10-01, and still did on
2026-10-12. The client estate's copy passed in 21 s.

```yaml
name: build warehouse

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0

      # Microsoft.Build.Sql ships net472 and net8.0 tools, and the FabricDw
      # package is a bare master.dacpac, so nothing here is Windows-only.
      - uses: actions/setup-dotnet@67a3573c9a986a3f9c594539f4ab511d57bb3ce9 # v4.3.1
        with:
          dotnet-version: '8.0.x'

      # The build Fabric runs on sync. A change refused for data loss still
      # passes here; that is warehouse-deploy-report.ps1's question, run by hand.
      - name: Build the warehouse project
        run: dotnet build "<path>/<WarehouseName>.Warehouse/<WarehouseName>.sqlproj" --configuration Debug
```

## AI tool instruction snippet

Paste this into the AI instruction file that holds local-cli's snippet
(`CLAUDE.md`, `.github/copilot-instructions.md` or `AGENTS.md`):

```markdown
## Warehouse Git sync checks (scripts/git-sync/)

- `pwsh -NoProfile -File scripts/git-sync/warehouse-build.ps1` — builds the warehouse's SQL project with the build Fabric runs on sync. Exit 1 means the sync would reject it too, so fix every error before committing. SQL71501 is an unresolved reference: usually a dropped column that a proc or view still reads (edit them in the same commit), or a type name such as `SYSNAME` in the wrong case. The pre-commit hook runs it on staged warehouse changes.
- `pwsh -NoProfile -File scripts/git-sync/warehouse-deploy-report.ps1 -Environment <env>` — predicts, against the live warehouse, whether the sync will refuse a schema change for data loss. Read-only; about a minute. Run it before pushing any change that drops, narrows or retypes a column or adds a NOT NULL one. Exit 0: the sync will go through. Exit 3: it will be refused, and the output lists the statements to run live first. Exit 1: the check did not run; read why, and never treat it as a pass. Never run the printed statements without the user's explicit go-ahead: they destroy data, and the output says what to capture first.
- A green build does not mean the sync will succeed; only the report answers that. Environments in this repo: `<list-environments>`; merges to `<branch>` sync to `<env>`.
```
