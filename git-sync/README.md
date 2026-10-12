# git-sync/

Scripts that write or check the item definitions a Fabric workspace syncs
to Git. Like [local-cli/](../local-cli/), they run on a developer's
machine or in CI rather than inside Fabric, and they are templates: copy
them into a client repo at `scripts/git-sync/`, beside `scripts/data/`.

## Contents

| File | Purpose |
| --- | --- |
| [build_real_time_dashboard.py](build_real_time_dashboard.py) | Writes a Real-Time dashboard's `RealTimeDashboard.json` from a spec of pages and tiles in the same file, bound to one environment's KQL database through the workspace's Variable Library. `--check` compares the committed file with the build, as a CI drift guard; `--test` runs every tile's query through [kql.sh](../local-cli/kql.sh). Standard library only, Python 3.10 or later. |

## Deployment into a client repo

1. Create the dashboard in the workspace and commit it from there, so its
   folder and `.platform` exist in Git. The script writes into an existing
   item and refuses to run without its `.platform`: the item's identity is
   the workspace's to mint, not the script's.
2. Copy the script to `<client-repo>/scripts/git-sync/`, one copy per
   dashboard, named for it. It finds the repo root two levels up, as the
   local-cli wrappers do from `scripts/data/`, so that location is
   load-bearing.
3. Fill in its settings block: the workspace folder and the three item
   paths, the Variable Library's two variable names, `DEFAULT_ENV`, and
   `NAMESPACE`, minted once for this dashboard and never copied from
   another:

   ```bash
   python -c "import uuid; print(uuid.uuid4())"
   ```

4. Replace the sample spec with the dashboard's own pages and tiles, run
   the script, and commit what it writes. The workspace's next update from
   Git loads it.
5. For `--test`, copy `local-cli/kql.sh` to `scripts/data/`, and give the
   client repo's `.env` each environment's Eventhouse query URI as
   `<ENV>_KUSTO_CLUSTER_URI`. [local-cli/README.md](../local-cli/README.md)
   covers the rest of its setup.
6. Pin the workspace folder's line endings. The portal writes a JSON part
   CRLF with no final newline, and `--check` compares bytes, so a checkout
   that translates the file fails it:

   ```gitattributes
   <workspace-folder>/** -text
   ```

   `-text`, not `text eol=lf`: forcing LF strips the portal's CRLF, and the
   next portal commit puts it back.

## build_real_time_dashboard.py

### Why generate a dashboard

A KQL dashboard item is one JSON file of tiles, queries, pages and a data
source: 48 KB for a dashboard of 33 tiles. Owning it in code buys three
things the portal cannot give:

1. **Tiles that review like code.** A tile is a few lines of Python beside
   the query that feeds it.
2. **Byte-stable output.** Every id is `uuid5(NAMESPACE, label)` and the
   serializer reproduces the portal's bytes, so a rerun writes the same
   file. A changed id reads as a deletion and a re-creation on the next
   update from Git, which loses pins and shares attached to it (Learn's
   identity rules for the item, 2026-10-12).
3. **One binding per environment.** The data source is the only part that
   differs by stage, and it comes from the Variable Library, so the script
   holds no GUID but its own namespace.

The price is a rule: the script is the authority. A tile changed in the
portal has to be folded back into the script, or the next run removes it,
and `--check` is how that drift shows. A page or tile key is its identity
and never changes once shipped; titles are free to.

### The binding

**Fabric gives a dashboard no way to follow its environment.** A Real-Time
dashboard is not among the items that read a Variable Library, and
deployment rules cover data sources only for Dataflow Gen1, semantic
models, paginated reports and mirrored databases (Learn, 2026-10-12). A
dashboard deployed from Dev to Test reads Dev's database until something
re-points it, and where one source feeds every stage, nothing looks wrong.
fabric-cicd rebinds one only when the database is parameterized in
`parameter.yml`'s `find_replace` (its item reference, v1.4.0).

This script binds at build time instead. The data source names its
database twice:

- `databaseArtifactId`, the database's item id, which differs by
  environment and comes from the Variable Library;
- `database`, its logicalId from its `.platform`, the same in every
  environment and what Git sync resolves inside the workspace.

The first load of a generated dashboard showed the two bind together;
whether the logicalId alone binds has not been tried.

The library needs two variables, named in the script's settings: an
ItemReference to the KQL database, a type Learn marks preview, and a
String naming the environment, whose value, lower-cased, is what `--env`
takes. Each value set is an environment, and so is the default value set
unless a value set names the same environment with the same database. A
library whose Dev runs on the defaults, with value sets for Test and Prod,
and one that gives every environment a value set of its own, both read as
they mean.

The script refuses, rather than binds, wherever the library could point
the dashboard at a database other than the one `--env` names:

- a value set whose environment name is empty, or two sharing one;
- the default value set and a value set naming one environment with
  different databases;
- a reference with no `itemId` GUID;
- two environments on one database, which is how a value set that lost its
  override of the reference looks: it inherits the default's.

A repo with no Variable Library binds with `--database-id <GUID>`, the KQL
database's item id. `--env` then only names the build, and picks
`kql.sh`'s environment for `--test`.

### What the file holds

The portal's own shape at `schema_version` 81, as a portal commit wrote it
(2026-09-30). Learn's sample schema for `RealTimeDashboard.json` is an
older shape, with `$schema`, `id`, `eTag` and `title` at the top and a data
source carrying `scopeId` but neither `databaseArtifactId` nor
`workspace`; it is not what the portal writes. Learn's validation rules do
hold, and the build keeps them: every query is referenced exactly once,
and every id is an RFC 4122 UUID.

| Part | Keys, in the portal's order |
| --- | --- |
| Top level | `schema_version`, `flavor` (`RTDashboard_Regular`), `autoRefresh`, `changeDetection`, `tiles`, `baseQueries`, `parameters`, `dataSources`, `pages`, `queries`, `embeddedApps` |
| Tile | `id`, `queryRef` (`kind: query`, `queryId`), `title`, `visualType`, `pageId`, `layout` (`x`, `y`, `width`, `height` on a 24-column grid), `visualOptions` |
| Query | `dataSource` (`kind: inline`, `dataSourceId`), `text`, `id`, `usedVariables` |
| Page | `name`, `id` |
| Data source | `kind` (`kusto-trident`), `name`, `clusterUri` (empty), `databaseArtifactId`, `database`, `workspace` (all zeros, the dashboard's own), `id` |

The bytes are indent 2, CRLF, no final newline, as the portal writes a
JSON part. The portal writes `<`, `>`, `'` and `+` as they are, as
Python's `json.dumps` does. What it writes for a character beyond ASCII
has not been seen, so the script refuses one anywhere in the file until a
portal commit shows it. The portal's JSON schema flags `clusterUri: ""`,
on the file the portal itself wrote too; that is not an error.

### What problems() refuses

`problems()` runs before every write, check and test, and holds the spec
to what the portal rejects without its JSON schema noticing:

- **A multistat too small for its slots.** It needs `SLOT_SIZE` grid units
  per slot each way, with one to five slots across and down, and nothing
  says so until the portal draws the tile: the dashboard loads, the tile
  shows *An error occurred*, and its details give the minimum size. The
  JSON schema, `--check` and the tile's query had all passed. Search the
  portal's message for *minimum supported tile size*, since it has two
  spaces before the second pair. `SLOT_SIZE` in the script carries the
  measurement.
- A tile off the grid, past its 24 columns, or overlapping another on its
  page; a tile key used twice; a page with no tiles; a multistat without
  `multistat()`'s options.
- A character beyond ASCII anywhere in the file.

### --test

`--test` runs every tile's query through `scripts/data/kql.sh`, which is
the only check a query gets before the portal loads it. Each query goes
to `kql.sh -E <env> -d <item id> -r`, on stdin as bytes:

- `-d` takes the bound database's item id, so the query runs against the
  database the build binds to. `kql.sh`'s header says a database answers
  to its item id, and Learn's `.show databases` example shows a Fabric
  database's Kusto name as a GUID beside its display name, which
  `database()` accepts in place of the name. A cluster that lacks the
  database fails loudly, where a display name, the same in every
  environment, would answer from another stage's cluster without a word.
- `-E` picks that environment's cluster from `.env`.
- A tile fails on a query Kusto refuses, and on one it answers but flags
  as incomplete or possibly wrong, `kql.sh`'s exit 3, because the portal
  marks that tile too: a card with a warning icon, or a chart reading *An
  error occurred*.

One `print` query runs first with `kql.sh`'s stderr on the console, so a
cold Azure CLI session logs in where its prompt shows, and a transport or
binding fault stops the run instead of failing every tile alike. On
Windows the script runs Git for Windows' bash, never the WSL launcher that
`bash` on `PATH` often is.

A 33-tile dashboard took about 10 s a tile in one Dev environment, and
46 s a tile in a sandbox, 25.5 minutes in all (2026-10-01). The sample
spec's tiles make up their own rows, so they pass against any database:
that proves the binding and the transport, not a real tile's numbers.

### Checking a load

A session cannot load the dashboard, only watch a load. The database logs
each tile's query under an application whose name starts `Kusto.Web.RTA`,
and `.show queries` gives each one's state. A data source that did not
bind fails every tile alike. A definition the portal refuses shows *Error
loading dashboard / Error found at:* followed by a path such as
`/<section>`.

### CI

Two pieces, both from the estate the script came from, with actions pinned
to a full commit SHA because a tag can move.

**The drift check.** Make it a step of a job that already runs on every
pull request and is required, not a workflow of its own: a required
workflow that a filter skips leaves its check pending. `main` holds
`DEFAULT_ENV`'s build, and a feature branch may hold another while it is
tested in a branched workspace, so the step runs only on what is bound for
`main`: pull requests into it, and pushes to it, because a workspace
commits to `main` without a pull request.

```yaml
name: validate

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with:
          python-version: '3.12'
      - name: Check the Real-Time dashboard against its generator
        if: github.base_ref == 'main' || github.ref == 'refs/heads/main'
        run: python scripts/git-sync/build_real_time_dashboard.py --check
```

A failure is an annotation on the file naming the environment the
committed file is bound to. A repo binding with `--database-id` passes the
id in through `env:`, from a repository variable.

**The flip when a pull request leaves draft.** A branch tested in a
branched workspace holds that workspace's build, here `sandbox`'s, and the
drift check fails it on its way to `main`. This workflow rebuilds the file
for `DEFAULT_ENV` when the pull request is marked ready for review, and
pushes the commit to the branch. It flips only a file that is exactly the
sandbox build. Anything else could be a portal edit, which regenerating
would erase, so it fails instead and leaves the file to a person.

```yaml
name: rebind the dashboard

on:
  pull_request:
    branches: [main]
    types: [opened, reopened, synchronize, ready_for_review]

permissions:
  contents: read

concurrency:
  group: rebind-dashboard-${{ github.event.pull_request.number }}
  cancel-in-progress: false

jobs:
  rebind:
    # A draft keeps its workspace's binding on purpose; a fork's pull request
    # gets no secrets.
    if: ${{ !github.event.pull_request.draft && github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: ubuntu-latest
    env:
      HEAD_REF: ${{ github.event.pull_request.head.ref }}
      SCRIPT: scripts/git-sync/build_real_time_dashboard.py
      DASHBOARD: <workspace-folder>/<DashboardName>.KQLDashboard/RealTimeDashboard.json
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.pull_request.head.ref }}
          ssh-key: ${{ secrets.REBIND_DEPLOY_KEY }}
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with:
          python-version: '3.12'
      - name: Rebuild for the default environment if the file is the sandbox build
        run: |
          if python "$SCRIPT" --check > /dev/null; then
            echo "Already the default build; nothing to flip."
          elif python "$SCRIPT" --check --env sandbox > /dev/null; then
            python "$SCRIPT"
            echo "::notice file=$DASHBOARD::Rebuilt for the default environment; it was the sandbox build."
          else
            python "$SCRIPT" --check || true
            echo "::error file=$DASHBOARD::Not flipped: the file is neither build, so regenerating would erase a portal edit or a script change never rerun."
            exit 1
          fi
      - name: Commit and push the flip
        run: |
          if git diff --quiet; then
            exit 0
          fi
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add -- "$DASHBOARD"
          git commit -m "ci: rebind the dashboard before merge"
          git pull --rebase origin "$HEAD_REF"
          git push origin "HEAD:$HEAD_REF"
```

The push uses a deploy key with write access, not `GITHUB_TOKEN`: a push
made with `GITHUB_TOKEN` starts no workflow run, so the required check
would never run on the flip commit. The job runs the branch's own script
with that key loaded, which grants nothing the branch's author lacks as
long as the key cannot bypass `main`'s rules. The drift check stays the
gate: if this workflow fails or is skipped, the merge is blocked, never
wrong.

### Limits

- **One data source.** Every query uses it, and `bound_to()` reads the
  first. A dashboard over two databases needs a binding per database.
- **ASCII only**, until a portal commit shows how the portal writes a
  character beyond it; `serialize()` says what to change then. A currency
  sign other than `$` is beyond ASCII too.
- **No parameters or base queries.** Both lists stay empty, so there is no
  time-range parameter, and Activator sets an alert only on a tile whose
  query filters on `_startTime` and `_endTime` (Learn, 2026-10-12).
- **`money()` and `whole()` group through the millions.** A billion or
  more prints its leading digits ungrouped.
- **Schema version 81.** A portal commit at a later version fails
  `--check`, and the build follows what that commit wrote.
- **Not yet verified against a tenant:** a portal round trip of a
  generated file, byte for byte; whether the logicalId alone binds; and
  `--test` through this script's own call to `kql.sh`. A `--publish` mode,
  pushing an environment's build to that stage's dashboard through the
  Fabric REST update-definition call and reading it back, would end the
  re-point after each deployment. It is unbuilt.
