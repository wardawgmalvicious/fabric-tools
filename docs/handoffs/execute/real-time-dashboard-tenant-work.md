---
status: open
priority: 2
needs: [tenant, user]
blocked-by: []
written: 2026-10-12
---

# Handoff: prove the Real-Time dashboard generator on a tenant

- **Written**: 2026-10-12, from an inbox note of 2026-10-01 that ported a
  client estate's dashboard generator into
  [git-sync/build_real_time_dashboard.py](../../../git-sync/build_real_time_dashboard.py),
  which landed with this brief.
- **Kind**: three probes on a tenant, two of them in the portal, each
  ending in an edit to `git-sync/`; then one new mode, `--publish`.

## What is open

The template is verified offline only. Fed the client estate's spec and
Variable Library, its engine reproduced that estate's committed
`RealTimeDashboard.json` byte for byte (2026-10-12), a file an earlier
version of the same engine wrote and the portal loaded. What a tenant
still has to settle, as [git-sync/README.md](../../../git-sync/README.md)
§ Limits lists it:

1. **A portal round trip, and the bytes for a character beyond ASCII.**
   `problems()` refuses any such character, because no portal commit seen
   so far has held one. `json.dumps` escapes `é` as `\u00e9`, in
   lower-case hex. Were the portal to write the letter itself, or to
   escape it in upper-case hex as .NET's `System.Text.Json` does,
   `--check` would fail the first round trip as drift.
2. **Whether the logicalId alone binds.** The data source names its
   database by item id, `databaseArtifactId`, and by logicalId,
   `database`, and the first load showed the two bind together. If the
   logicalId alone binds inside a Git-synced workspace, each workspace
   resolves its own database, and the build per environment matters only
   where a deployment pipeline, not Git sync, carries the item.
3. **`--test` through the template's own call.** It passes the bound
   database's item id to `kql.sh -d`, which `kql.sh`'s header says a
   database answers to and Learn's `.show databases` example supports. No
   run against a Fabric Eventhouse has proved it.
4. **`--publish`**, unbuilt: push an environment's build to that stage's
   dashboard through the Fabric REST `updateDefinition` call, poll the
   long-running operation, then read the definition back and compare
   bytes. It would end the re-point by hand after each deployment.

## Where it runs

A workspace that syncs from a branch of a repo holding the template, with
an Eventhouse, a KQL database, a Variable Library holding the template's
two variables, and the dashboard item, created in the portal and committed
so its `.platform` exists. The sample spec runs as shipped: its tiles make
up their own rows, so a tile that draws proves the binding, not a query.
A sandbox workspace may sync from a branch other than `main`, so read its
connection, `GET /v1/workspaces/{workspaceId}/git/connection`, before
assuming what it holds. The user drives the portal. A session can only
watch a load, through `.show queries` and the `Kusto.Web.RTA` application
name the folder README gives.

The non-ASCII half of probe 1, and probe 2, already have a home. A
client estate's own brief (2026-10-01) runs the same round trip against
that estate's generator, with a workspace and branch set aside for it, and
lists the logicalId question as an extra the same setup could settle. Take
its result rather than repeating either probe here; that brief already
says to tell the user once its answer is in. The template's own round
trip with no diff, `--test` and `--publish` stay here.

1. **Round trip.** Build for the workspace's environment, commit, and
   update the workspace from Git. Open the page and see the four tiles
   draw, then read the workspace's source control panel: the dashboard
   unchanged means the round trip holds, and marked modified, commit it
   and read the diff. Then, in the portal, put `é` and an em dash into one
   tile's title, save, commit, and read the bytes the portal wrote for
   them.
2. **LogicalId alone.** Build twice on a scratch branch: with
   `--database-id` naming another environment's database, so the item id
   and the logicalId disagree, and with `databaseArtifactId` cut from the
   built file by hand. Sync each and see which database the tiles ran in:
   `.show queries` in each database, filtered to an application starting
   `Kusto.Web.RTA`, says which received them, and a probe tile of
   `print Database = current_database()` says it on the page.
3. **`--test`**, with `.env` holding the environment's cluster URI:

   ```bash
   python scripts/git-sync/build_real_time_dashboard.py --test --env <env>
   ```

   For exit 3, add a probe tile whose range runs backwards, such as
   `range Day from datetime(2026-10-02) to datetime(2026-10-01) step 1d`:
   a range like it drew Kusto's E_INVALIDARG warning on 2026-10-01, and
   the tile should report `FLAGGED`.

## Decision after probing

- **No diff on the round trip**: drop it from the folder README's
  *Limits*, with the date. A diff means the portal's shape moved, and
  `build()`, `SCHEMA_VERSION` and the README's table follow what it
  wrote.
- **The portal writes `\u00e9`, lower-case**: `serialize()` already
  matches, so lift the ASCII check from `problems()` and say so in
  `serialize()`'s docstring. **It writes `\u00E9`, upper-case**:
  `json.dumps` cannot emit that, so `serialize()` upper-cases its escapes
  after dumping, and the check lifts the same way. **It writes the
  characters themselves**: serialize with `ensure_ascii=False`, and lift
  the check. **Anything else**: record it, and keep the check. In every
  case, record the measured form and its date where the check stood.
- **The logicalId alone binds**: say so in the folder README's binding
  section, with the date, and put to the user whether the build should
  still carry an item id, since a deployment pipeline does not sync from
  Git and may still need one. **It does not**: record that, and the
  binding stands.
- **`kql.sh -d` takes the item id**: record the run, with its date, in
  `run_kql()`'s docstring and the README. **It refuses it**: pass the
  display name, `read_database()`'s second value, and record why, with
  the cost the docstring names: a missing cluster URI then answers from
  another stage's cluster without a word.
- **`--publish`**: build it once the probes have run, against the binding
  they confirm. Open for it: where each stage's dashboard item id comes
  from, an ItemReference to the dashboard in the same library being one
  answer; whether the payload carries `.platform`, which Learn's
  definition pages say `updateDefinition` accepts only with
  `?updateMetadata=true`; and how it authenticates, where the local-cli
  wrappers use the Azure CLI. If the probes land first, move `--publish`
  to a brief of its own in that commit.

## Where it lands

`git-sync/build_real_time_dashboard.py`: `problems()`, `serialize()`,
`run_kql()`, and `build()` or `SCHEMA_VERSION` if the shape moved.
`git-sync/README.md`: § Limits and the sections the probes touch. The
`git-sync/` entry in [CLAUDE.md](../../../CLAUDE.md), if the binding
changes. Delete this brief in the commit that finishes it.

## Not checked

Everything above. The offline checks of 2026-10-12 ran from a scratch
harness that was not committed: 69 checks on Python 3.11 to 3.13, and the
byte comparison against the client estate's committed file.

One character settles the portal's rule only inside the Basic
Multilingual Plane. A character outside it, such as an emoji, escapes as
a surrogate pair, and no probe here covers one.

## Scrubbing

The inbox note was raw. It named the client estate's items, Variable
Library, value sets, functions, columns, commits, pull requests and a
branch, and none of that is here. The figures that stay are counts, sizes
and dates. The estate's round-trip brief is cited by kind and date alone,
and only the general fact about hex case came from it.

## Re-measure before acting

```bash
grep -n 'SCHEMA_VERSION =\|beyond ASCII\|"-d", binding' git-sync/build_real_time_dashboard.py
sed -n '/^### Limits/,$p' git-sync/README.md
```
