---
status: open
priority: 2
needs: [tenant, user]
blocked-by: []
written: 2026-10-13
---

# Handoff: prove the update-from-Git template on a tenant

- **Written**: 2026-10-13, from an inbox note of the same day that brought
  a client estate's update script here as
  [git-sync/update_from_git.py](../../../git-sync/update_from_git.py),
  which landed with this brief.
- **Kind**: three runs against a Git-connected workspace, each ending in
  an edit to [git-sync/update-from-git.md](../../../git-sync/update-from-git.md),
  and perhaps one to the script.

## What is open

The script the template was ported from made about ten round trips in
one day in that estate, signed in as a person. The port has run only
offline, against a mock of the API and a stand-in `az`. What a tenant
still has to settle, as the page's § How far this has been checked lists
it:

1. **The port, as a person.** A `--dry-run`, then an update, with the
   workspace found through a Variable Library by the port's rules. The
   dashboard generator reads a library by the same rules; the origin's
   own reader was different code.
2. **A service principal.** The same update signed in as one, with Git
   credentials through a configured connection, on Azure DevOps, where
   Learn documents the setup. The same run can ask whether a service
   principal can update a workspace a person connected to GitHub, which
   Learn neither documents nor rules out.
3. **The body without `allowOverrideItems`.** Learn says an update will
   not start while incoming items are present and the flag is unset, and
   does not define incoming items. One update with an incoming item
   change and the two hashes alone shows whether it starts, and what it
   refuses with if it does not.

## Where it runs

A workspace connected to a branch of a scratch repo that holds the
template and a Variable Library with the template's two variables, the
ItemReference pointing at any item in that workspace. A sandbox the user
can afford to update is enough; nothing here needs Test or Prod. The
script's first line names the branch the workspace tracks: read it
before assuming which one that is. Every update is a write to the
workspace, so each run waits for the user's word.

1. **The port.** Push a change to one item, run `--dry-run` and read
   what it lists, then run the update and read the second status. For
   exit 3, change one item both in the portal and on the branch, and run
   again.
2. **A service principal.** With the tenant setting *Service principals
   can call Fabric public APIs* covering it, Contributor on the
   workspace, and its Git credentials set by `PATCH …/git/myGitCredentials`
   to a configured connection, sign `az` in as it and repeat step 1's
   update. Record the `myGitCredentials` answer before and after.
3. **Two hashes alone.** With an incoming item change waiting, send
   `{"workspaceHead": "…", "remoteCommitHash": "…"}` to Update From Git
   by hand, polling as the script does, and record whether it starts and
   what it says.

## Decision after probing

- **The port runs clean**: record the run, with its date, in the page's
  § How far this has been checked, and take the port off its *Not run
  live* line. **It fails**: the bug is the port's; fix it, and record the
  fix and the run.
- **A service principal updates**: record what it took, with the date,
  in § Who it runs as, and take the service principal off *Not run
  live*. **It is refused**: record the error code and message there, and
  whether the items, the credentials or the identity caused it.
- **The two hashes alone start and apply an update**: the flag buys
  nothing seen so far, and dropping it would make the script refuse
  rather than override whatever *incoming items* covers. Put that choice
  to the user, and record the result in § The request body either way.
  **They do not start one**: record the error, which settles what
  Learn's sentence means, and the flag stays.

## Where it lands

`git-sync/update-from-git.md`: § How far this has been checked, § Who it
runs as and § The request body. `git-sync/update_from_git.py`, if the
port has a bug or the flag goes. The `git-sync/` entry in
[CLAUDE.md](../../../CLAUDE.md), where it says what has run. Delete this
brief in the commit that finishes it.

## Not checked

Everything above. The offline checks of 2026-10-13 ran from a scratch
harness that was not committed: 64 checks on Python 3.11 to 3.13.

## Scrubbing

The inbox note was raw. It named the client estate and its repo, the
Variable Library and the variable the script read, its items, its own
helper scripts and the wording of its agent instructions, and none of
that is here or on the page. The figures that stay are counts, durations
and dates; the scope rule is paraphrased, and the environment names left
are the generic ones the folder already used.

## Re-measure before acting

```bash
grep -n 'allowOverrideItems\|^GIT_SYNCED\|return 3' git-sync/update_from_git.py
sed -n '/^## How far this has been checked/,$p' git-sync/update-from-git.md
```
