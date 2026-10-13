# Update from Git

[update_from_git.py](update_from_git.py) is the Source control pane's
**Update all**, run from a shell. It reads a Git-connected workspace's
status, updates the workspace to its branch's head through Fabric's REST
API, and reads the status again. An agent that has just pushed to the
branch a workspace tracks can bring the workspace up to that push and
check the result itself, leaving the person it works for only the steps
that nothing but the portal can take.

Like the rest of [git-sync/](README.md), it is a template: copy it into a
client repo at `scripts/git-sync/` and use it there. It needs Python 3.10
or later and the Azure CLI, and signs in as the Azure CLI session, never
with a stored credential.

## The workflow it carries

The workflow made the difference, more than the script. In the client
estate the script came from, an agent ran about ten sandbox round trips
this way on 2026-10-13, across a KQL queryset, an Activator, a Variable
Library and a pipeline schedule:

1. Push to the branch the workspace tracks.
2. Update the workspace from Git, with this script.
3. Read the result back by REST.
4. Hand the person only what the portal alone can do, such as setting an
   Activator rule or selecting **Update** on a running one.

Before that, every round trip meant asking the person to open **Source
control**, select **Update all**, and report what the workspace showed.
Three reads replace that report:

| Question | Call |
| --- | --- |
| Is the workspace at the branch head, and what is uncommitted? | `GET /v1/workspaces/{ws}/git/status`, which the script makes; `--dry-run` makes only the reads |
| What does a live item hold now? | `POST /v1/workspaces/{ws}/items/{id}/getDefinition`, then compare its parts with the committed files |
| Did a pipeline schedule turn on or off? | `GET /v1/workspaces/{ws}/items/{id}/jobs/Pipeline/schedules` |

Get Status and getDefinition are long-running: either can answer `202`,
and the answer is then at the `Location` header plus `/result` once the
operation there reads `Succeeded`. Poll it as the script does. `az rest`
prints a `202`'s empty body and exits 0 (Azure CLI 2.90.0, 2026-10-01),
so through it a getDefinition reads as an item with no definition. A live
definition is not quite the Git serialization either: where Git holds a
logicalId or a relative path, the live item can hold a runtime id or a
connection (seen 2026-10-12), so normalize those before reading a
difference as drift.

## What the script does

1. **Get Connection.** A workspace that is not `ConnectedAndInitialized`
   stops it, with exit 1.
2. **Get Status.** It prints the two heads and each item's incoming,
   uncommitted and conflicting change, then stops:
   - with exit 0 when the heads match, since there is nothing to update;
   - with exit 3 when any item's `conflictType` is `Conflict`. Learn's
     third value, `SameChanges`, is the same change on both sides, and
     does not stop it;
   - with exit 0 under `--dry-run`, having changed nothing.
3. **Update From Git**, with this body:

   ```json
   {"workspaceHead": "<from status>", "remoteCommitHash": "<from status>", "options": {"allowOverrideItems": true}}
   ```

4. **Polls the `202`'s `Location`** every 5 s, for up to 10 minutes,
   until the operation reads `Succeeded`, `Failed` or `Undefined`. A
   failure prints Fabric's error with each of its `moreDetails`, which is
   where a failed update names the item that stopped it.
5. **Get Status again.** It lists what is still uncommitted, and exits 1
   if the workspace is not at the head it read before.
6. **Notes** for the item types an update does not fully reach, when the
   incoming commits changed one: see
   [What an update does not reach](#what-an-update-does-not-reach).

It first reads the workspace itself, so that its first line names the
workspace as well as its id. Against a mock of the API, where the update
takes no time, a run prints:

```text
sandbox: Sales Sandbox (<workspace-id>, from valueSets/Sandbox.json) tracks feature/sample
sandbox: the workspace is at aaaaaaa, feature/sample at bbbbbbb
  incoming: Order alerts (ReflexProject) Modified
  incoming: Settings (Variables) Modified
  uncommitted: Scratch (SynapseNotebook) Modified
sandbox: updated to bbbbbbb in 0 s
  still uncommitted: Scratch (SynapseNotebook) Modified
  note: a running Activator rule keeps what it was set with until Update is selected on it in the portal
  note: a schedule bound to one of its variables takes a synced value only at its next read of the variable, which came 12 minutes after one update (2026-10-13)
```

### The request body

**It never sends a `conflictResolution`.** An item changed both in the
workspace and on the branch stops the script at step 2, before anything
changes, and which side wins is chosen in the Source control pane by a
person. Uncommitted changes to items the incoming commits do not touch
are left as they are: after every update in the origin estate, such items
still read as uncommitted.

**It sends `allowOverrideItems: true`.** Learn's `UpdateOptions` says
that "when incoming items are present and the allow override items is
not specified or is provided as false, the update operation will not
start". Both of Learn's request examples send it, and so does Microsoft's
`GitIntegration-UpdateFromGit.ps1` sample, under the comment "Allows
overwriting existing items if needed" (all read 2026-10-13). All fourteen
update bodies the origin estate sent on 2026-10-12 and 2026-10-13 set it.
Learn does not define *incoming items*, and no update with incoming item
changes has been sent without the flag, so whether the two hashes alone
would start one is unverified.

### Why the status is read again

An update can leave an item reading `workspaceChange: Modified` that
nobody edited. One update of six items left two that way on 2026-10-12,
cause unknown: a KQL database whose `DatabaseSchema.kql` held the
branch's lines in another order, and a report whose `.platform`
description the update had not applied. Committing everything from the
portal would then write both back over the branch. The second read names
whatever still differs, to be committed item by item, or not at all.

### Item types in Get Status

Get Status names some item types by internal names rather than the
values its documented `ItemType` enum lists, so the script's notes match
both. Filter `changes[]` on a documented name and these items drop out
without a word:

| Item | Get Status `itemType` | Learn's `ItemType` |
| --- | --- | --- |
| Activator | `ReflexProject` | `Reflex` |
| Variable Library | `Variables` | `VariableLibrary` |
| KQL queryset | `KustoQueryWorkbench` | `KQLQueryset` |
| KQL database | `KustoDatabase` | `KQLDatabase` |
| Notebook | `SynapseNotebook` | `Notebook` |
| Data pipeline | `Pipeline` | `DataPipeline` |
| Report | `report` | `Report` |
| Semantic model | `dataset` | `SemanticModel` |
| SQL database | `SQLDbNative` | `SQLDatabase` |
| User data functions | `FunctionSet` | `UserDataFunction` |
| Plan | `Planning` | `Plan` |
| Warehouse | `Warehouse` | `Warehouse` |

All were seen between 2026-09-30 and 2026-10-13. A Real-Time dashboard's
has not been seen, so the script's note for one may never print. Two
more departures from Learn's examples:

- An absent `remoteChange` or `workspaceChange` comes back as the key
  with the value `null` (2026-10-13), where Learn's examples leave the key
  out and its `ChangeType` has no `None`.
- `conflictType` reads `"None"` unless the item is in conflict, as
  Learn's `ConflictType` has it: 114 entries in 35 reads on 2026-10-13.

So the script tests a value, never whether its key is there, and takes
`null` and `"None"` alike as no change.

## Which workspace, and who may update it

**The workspace comes from the Variable Library**, as the dashboard
generator's binding does. `REFERENCE_VARIABLE` is an ItemReference to any
item in the workspace that syncs from Git, whose `workspaceId` is that
workspace. `ENVIRONMENT_VARIABLE` is a String naming each value set's
environment, and lower-cased it is what `--env` takes. The library is
read from the checkout by [the generator's rules](README.md#the-binding),
with `workspaceId` where those read `itemId`, so anything that could
point the update at a workspace other than the one `--env` names is
refused. That includes two environments on one workspace, which is how a
value set that lost its override of the reference looks. The two scripts
are the library's two readers, and each names the other, so a change to
the rules lands in both. A repo with no library passes
`--workspace-id <GUID>` instead, and the GUID is then the caller's word
for which workspace `--env` means.

**`GIT_SYNCED` lists the environments it may touch**, and any other
`--env` is refused before a call is made, with `--workspace-id` or
without. List only environments whose workspace changes by an update from
Git: a development workspace, and any branched one an agent works in.
Never list one that a deployment pipeline promotes into, since updating
it from Git would go around the pipeline. `DEFAULT_ENV` is what a bare
run updates.

**The script is the same operation as the portal's button**, so it
inherits whatever the repo says about who may update which environment.
In the estate it came from, the agent instructions already allowed a Git
sync of the sandbox workspace, and updating it by REST counted as that
sync, not as a new deploy step. So after a push to the branch the sandbox
tracks, the agent ran the script there unasked and checked the result by
REST. It updated Dev only on the person's word, because some changes need
a script run there first; a change that would lose warehouse data is one
([warehouse-checks.md](warehouse-checks.md)). Test and Prod stayed with
deployment pipelines. Give the client repo's agent instructions the same
three tiers; [the snippet below](#ai-tool-instruction-snippet) is a
start.

## Who it runs as

The token is the Azure CLI's,
`az account get-access-token --resource https://api.fabric.microsoft.com`,
so the update runs as whoever `az` is signed in as: a person at a
workstation, or a service principal that a CI job signed in. With no
token, the script runs the login that local-cli's scripts start, whose
[auth notes](../local-cli/README.md#all-of-them-log-you-in-automatically)
explain its flags, pinned to `AZURE_TENANT_ID` from the environment or
`.env`. With `SKIP_AZ_LOGIN=1` it stops with exit 1 instead, which is
what CI wants. Only a person's sign-in has been measured.

Either identity needs, per Learn (read 2026-10-13):

- **Contributor in the workspace, with write permission on every item.**
  Git integration's permissions table adds item ownership where the
  tenant blocks updates by non-owners, and Build on external dependencies
  where there are any; the REST reference asks only for Contributor.
  Learn also says that from December 1, 2026, users without read-write
  permission on workspace items can't use Git integration.
- **Its own Git credentials, configured in the workspace.** Get Status
  and Update From Git both require them. `GET …/git/myGitCredentials`
  answers `source`: `Automatic`, `ConfiguredConnection` with a
  `connectionId`, or `None`, and `PATCH …/git/myGitCredentials` sets
  them. On Azure DevOps a person is usually `Automatic` once an admin has
  connected the workspace; on GitHub the credential is a connection
  holding a personal access token.

A service principal needs three things more:

- the tenant setting *Service principals can call Fabric public APIs*;
- items it can act on: Learn supports one for Update From Git "only when
  all the items involved in the operation support service principals";
- Git credentials through a configured connection. Learn documents this
  for Azure DevOps: share an *Azure DevOps – Source control* connection
  with the service principal, or create one with its own credentials
  through the Connections API, then, signed in as the service principal,
  `PATCH …/git/myGitCredentials` with
  `{"source": "ConfiguredConnection", "connectionId": "<id>"}`
  ([Learn](https://learn.microsoft.com/fabric/cicd/git-integration/automate-git-integration-with-service-principal)).
  Learn's end-to-end automation tutorial says a service principal cannot
  connect a workspace to GitHub. Whether one can update a workspace that
  a person connected to GitHub has not been tried.

### Running `az` from Python on Windows

`az` on Windows is a `.cmd` shim, and `CreateProcess` does not search
`PATHEXT`, so `subprocess.run(["az", ...])` raises `FileNotFoundError`
(WinError 2) while `subprocess.run([shutil.which("az"), ...])` runs the
shim (Python 3.13, 2026-10-13). The script does the latter, with no shell
between. A `.cmd` still runs through `cmd.exe`, which parses its
arguments too, so every argument the script passes is a constant but the
tenant, and the tenant has to look like a GUID or a domain name first. A
comment after `AZURE_TENANT_ID` on its line in `.env` fails that check
rather than reaching `az`, because `.env` values are read whole, as
`sql.sh` reads them.

## What an update does not reach

An update from Git rewrites stored definitions, and three kinds of change
do not take effect by that alone. The script prints a note after an
update whose incoming commits touched the item type:

- **A running Activator rule** keeps the values it was started or last
  updated with until **Update** is selected on it in the portal. In the
  origin estate an alert went on sending its old text while Git status,
  getDefinition and the file all read the new one (2026-10-13).
- **A rule set from a KQL queryset or a Real-Time dashboard tile runs its
  own copy of the query**, taken when the rule was created. Learn says to
  delete the rule and set it again from the changed
  [queryset](https://learn.microsoft.com/fabric/real-time-intelligence/data-activator/ingestion/ingestion-kql-querysets)
  or
  [tile](https://learn.microsoft.com/fabric/real-time-intelligence/data-activator/ingestion/ingestion-realtime-dashboards)
  (read 2026-10-13).
- **A schedule bound to a Variable Library variable** takes a synced
  value only at its next read of the variable, which came 12 minutes
  after one update in a sandbox (2026-10-13).

**A binding that arrives with a sync reads unevaluated at first.** A
pipeline schedule that a sync created in a Dev workspace on 2026-10-13,
bound to a variable, read through List Item Schedules:

- 20 minutes after: `enabledEvalState` and
  `nextResolveVariableReferenceDateTime` both `null`;
- 40 minutes after: `enabledEvalState` `Normal`, and its next read of the
  variable 7 minutes away.

So `null` means the variable has not been read yet. Wait for the first
read, which came 20 to 40 minutes after that sync, before calling a
binding broken. Learn documents neither timing, and this one workspace
was [disconnected from Git](#disconnecting-a-workspace) 18 minutes after
the sync, before either read.

### Disconnecting a workspace

Disconnecting a workspace from Git stops its syncing, not what runs in
it. `POST /v1/workspaces/{ws}/git/disconnect` with an empty body
answered `200` on 2026-10-13. Get Connection then read `NotConnected`,
the items were unchanged, and the schedule above went on: it completed a
scheduled run 11 minutes later, and 26 minutes after the disconnect it
still read `enabledEvalState` `Normal`, so its variable was still being
read. Learn requires workspace Admin to disconnect. So retiring a sandbox
workspace means turning its schedules off as well. A POST with no body
and no `Content-Length` header is refused `411` before Fabric sees it
(seen 2026-10-12): send `Content-Length: 0`, or `{}`.

## Exit status

| Code | Means |
| --- | --- |
| 0 | the workspace is at its branch head, already or after the update; or `--dry-run` found nothing in the way of one |
| 3 | an item is in conflict, so no update was sent: a person chooses each side in the Source control pane |
| 1 | no answer: not connected and initialized, a call or the operation failed, the update ended short of the head, or the Variable Library, `.env` or the login gave nothing to go on |
| 2 | a usage error, such as an `--env` that `GIT_SYNCED` does not list |

3 is a finding and 1 a failure, the shape of local-cli's
[kql.sh](../local-cli/README.md#kqlsh--how-it-works) and the
[warehouse checks](warehouse-checks.md#exit-status). The script it was
ported from exits 1 on a conflict.

## Required tools

```powershell
winget install Microsoft.AzureCLI   # az, for the token
```

And Python 3.10 or later: the script imports nothing outside the standard
library.

## Deployment into a client repo

1. Copy the script to `<client-repo>/scripts/git-sync/`. It finds the
   repo root two levels up, for `.env` and the Variable Library, so that
   location is load-bearing.
2. Fill in its settings block: the Variable Library's folder and two of
   its variables, `GIT_SYNCED` and `DEFAULT_ENV`. A repo with the
   dashboard generator already has the library and the String naming each
   environment. Give the library an ItemReference into the Git-connected
   workspace if it has none, overridden in every value set. With no
   library, plan on `--workspace-id`.
3. Configure Git credentials in the workspace for each identity that will
   run it ([Who it runs as](#who-it-runs-as)), then check with
   `--dry-run`, which reads and changes nothing.
4. Give the repo's agent instructions the scope rule:
   [the snippet below](#ai-tool-instruction-snippet), in the file that
   holds local-cli's.

## Usage

```bash
# Update the default environment's workspace to its branch head
python scripts/git-sync/update_from_git.py

# Read the connection and the status, and change nothing
python scripts/git-sync/update_from_git.py --dry-run

# Another environment GIT_SYNCED lists
python scripts/git-sync/update_from_git.py --env sandbox

# No Variable Library: name the workspace
python scripts/git-sync/update_from_git.py --env dev --workspace-id <workspace-guid>
```

**Running it from CI** wants the identity signed in to `az` before the
script starts, by a federated-credential login step for instance, and
`SKIP_AZ_LOGIN=1`, so that a missing sign-in fails at once rather than
waiting on a login nobody will answer. None of that has been measured;
[Who it runs as](#who-it-runs-as) lists what the identity needs.

## AI tool instruction snippet

Paste this into the AI instruction file that holds local-cli's snippet
(`CLAUDE.md`, `.github/copilot-instructions.md` or `AGENTS.md`), and fill
in the angle brackets:

```markdown
## Updating Fabric workspaces from Git (scripts/git-sync/)

- `python scripts/git-sync/update_from_git.py --env <env>` updates that
  environment's workspace to the head of the branch it tracks, as the
  Source control pane's Update all does, and reads its Git status before
  and after. `--dry-run` only reads. Exit 0: the workspace is at the
  branch head. Exit 3: an item is in conflict and nothing changed; name
  it to the user, since only the portal resolves it. Exit 1: read the
  error, and don't retry blindly.
- `<sandbox-env>` tracks `<branch>`: after pushing there, run the script
  for it unasked, then check the result by REST instead of asking the
  user to look in the portal. Update `<dev-env>` only on the user's word.
  Never update an environment that deployment pipelines promote into;
  the script refuses them anyway.
- After an update, tell the user what only the portal can do: select
  Update on a running Activator rule whose definition changed, and delete
  and set again any rule made from a changed KQL queryset or dashboard
  tile. A schedule bound to a Variable Library variable takes a synced
  value at its next read of it, 12 to 40 minutes later when measured, so
  don't call its binding broken before then.
- If the script lists items still uncommitted after an update, say so:
  committing everything from the portal would write them back over the
  branch.
```

## How far this has been checked

The script this was ported from ran in a client estate's sandbox and Dev
workspaces on 2026-10-12 and 2026-10-13, signed in as a person:

- its updates answered `202` and finished in seconds, its own run in 10 s
  polled every 5 s, where Learn's sample answer carries
  `Retry-After: 30` and one observed answer carried `20` (2026-09-30);
- all fourteen update bodies sent those two days set
  `allowOverrideItems`, and one, sent outside the script, also chose a
  `conflictResolution`;
- after each update, items with uncommitted changes that the incoming
  commits did not touch still read as uncommitted.

The port changes how the workspace is found (this repo's library rules,
or `--workspace-id`), which environments it may update (a setting, not
two names in the code), the login (`SKIP_AZ_LOGIN`, and the tenant check
before `cmd.exe`), the exit code for a conflict (3, not 1), the error
text (`moreDetails`), the first line (the workspace's name, one more
call), and console output past the code page. On 2026-10-13 it passed 64
offline checks on Python 3.11, 3.12 and 3.13, against a mock of the API
on localhost and a stand-in `az.cmd` run through `cmd.exe`:

- every exit path above; Get Status and Update From Git each answering
  `200` and `202`; a failed and an undefined operation; error answers in
  JSON and not; a refused connection, and a poll that runs out;
- the request body, exactly; the bearer on every request, polls
  included; and a `Location` on another scheme, refused before the token
  goes to it;
- each of the library's refusals, and a byte-order mark;
- the login: no token with and without `SKIP_AZ_LOGIN`, the tenant from
  the environment and from a CRLF `.env`, a tenant `cmd.exe` would parse,
  a failed login, and no `az` at all;
- display names beyond a cp1252 console's code page, in a real process.

Not run live: the port itself, a service principal, and an update sent
without `allowOverrideItems`.
