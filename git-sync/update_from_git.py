#!/usr/bin/env python
"""Update a Git-connected workspace from its branch, through Fabric's REST API.

What the Source control pane's Update all does, run from a shell: read the workspace's Git
status, send Update From Git the two commit hashes it gives, see the long-running operation
through, and read the status again. A session that has just pushed to the branch a workspace
tracks can bring the workspace up to that push and read the result back, leaving a person only
the steps that nothing but the portal can take.

WHICH ENVIRONMENTS IT MAY UPDATE IS A SETTING. GIT_SYNCED lists the environments whose workspace
changes by an update from Git, and any other --env is refused before a call is made: a workspace
that a deployment pipeline promotes into changes by deployment, never by sync. This is the same
operation as the portal's button, so it inherits whatever the repo's agent instructions say
about who may update which of those environments, and when.

WHAT THE REQUEST SENDS. The two hashes from Get Status, and options.allowOverrideItems, as
Microsoft's update sample does; without it the update will not start while incoming items are
present (Learn, Update From Git). It never sends a conflictResolution, so an item changed both in
the workspace and on the branch stops the script before anything changes, and which side wins is
left to a person in the Source control pane. Uncommitted changes to items the incoming commits do
not touch are left as they are.

WHY THE STATUS IS READ AGAIN AFTER. An update can leave an item reading workspaceChange:
Modified that nobody edited (seen 2026-10-12 on a KQL database and a report), and committing
everything from the portal would then write it back over the branch. The second read names
whatever still differs.

WHAT AN UPDATE DOES NOT REACH. A running Activator rule keeps what it was set with until Update is
selected on it, a rule set from a KQL queryset or a dashboard tile runs its own copy of the query,
and a schedule bound to a Variable Library variable takes a synced value only at its next read of
the variable. The script says so when the incoming commits change such an item.

The workspace is the one REFERENCE_VARIABLE points into, in the Variable Library's value set for
--env, read by build_real_time_dashboard.py's rules; --workspace-id stands in for a repo with no
library. The token is the Azure CLI's at the Fabric API's audience, so the update runs as whoever
az is signed in as, who needs workspace Contributor with write on every item, and Git credentials
configured in that workspace (Learn). With no token it runs the az login the scripts/data
wrappers start, pinned to AZURE_TENANT_ID from the environment or .env, unless SKIP_AZ_LOGIN=1.

Usage, from the repo root:
    python scripts/git-sync/update_from_git.py                  # DEFAULT_ENV
    python scripts/git-sync/update_from_git.py --dry-run        # read only
    python scripts/git-sync/update_from_git.py --env <name>     # another of GIT_SYNCED

Exit status: 0 the workspace is at its branch head, or --dry-run found nothing in the way of an
update; 3 an item is in conflict, so no update was sent; 1 no answer: the workspace is not
connected, a call or the operation failed, the update ended short of the branch head, or the
Variable Library, .env or the login gave nothing to go on; 2 for a usage error, an --env that
GIT_SYNCED does not list among them.

Standard library only, Python 3.10 or later. The token travels in a request header, never on a
command line.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.message import Message
from pathlib import Path
from typing import NamedTuple

# ---------------------------------------------------------------------------------------------
# Settings: set these once, when the script is copied into a repo
# ---------------------------------------------------------------------------------------------

# The script lives two levels below the repo root, at scripts/git-sync/, and reads .env and the
# Variable Library from the root, as the scripts/data wrappers read .env.
REPO = Path(__file__).resolve().parents[2]

# The Variable Library the workspace is read from, and two of its variables: an ItemReference to
# any item in the workspace that syncs from Git, whose workspaceId is that workspace, and a String
# naming the environment. That name, lower-cased, is what --env takes. A repo that also holds
# build_real_time_dashboard.py names the same library and String there.
LIBRARY = REPO / "<workspace-folder>" / "<VariableLibraryName>.VariableLibrary"
REFERENCE_VARIABLE = "<ItemReferenceVariable>"
ENVIRONMENT_VARIABLE = "<EnvironmentNameVariable>"

# The environments whose workspace changes by an update from Git, lower-cased: a development
# workspace, and any branched one an agent works in. Any other --env is refused before a call is
# made, so never list one that a deployment pipeline promotes into.
GIT_SYNCED = ("dev",)

# The environment a bare run updates.
DEFAULT_ENV = "dev"

# ---------------------------------------------------------------------------------------------
# The engine: nothing below here is specific to one repo
# ---------------------------------------------------------------------------------------------

API = "https://api.fabric.microsoft.com/v1"
RESOURCE = "https://api.fabric.microsoft.com"

# Seconds between reads of a running operation, and before giving up on one. Retry-After asks for
# 20 or 30, but every update seen so far finished within seconds: 10 s, polled every 5
# (2026-10-13).
POLL = 5
POLL_LIMIT = 600

# Item types whose running state an update does not reach, and what each note says. Get Status
# names some types by internal names rather than its documented ones (an Activator ReflexProject,
# a KQL queryset KustoQueryWorkbench, a Variable Library Variables, seen 2026-10-13), so each set
# holds both. Its name for a Real-Time dashboard has not been seen, so that note may never print.
NOT_REACHED = (
    ({"ReflexProject", "Reflex"},
     ("a running Activator rule keeps what it was set with until Update is selected on it in the "
      "portal")),
    ({"KustoQueryWorkbench", "KQLQueryset"},
     ("an Activator rule set from one of its queries runs its own copy of the query; Learn says "
      "to delete the rule and set it again from the queryset")),
    ({"KQLDashboard"},
     ("an Activator rule set from one of its tiles runs its own copy of the tile's query; Learn "
      "says to delete the rule and set it again from the tile")),
    ({"Variables", "VariableLibrary"},
     ("a schedule bound to one of its variables takes a synced value only at its next read of "
      "the variable, which came 12 minutes after one update (2026-10-13)")),
)

_GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
# A tenant as az login takes one, a GUID or a domain name, and nothing else: see fabric_token().
_TENANT = re.compile(r"[0-9A-Za-z][0-9A-Za-z.-]*")


class FabricError(Exception):
    """A Fabric REST call that answered with an error, or an operation that failed."""


class Workspace(NamedTuple):
    """One environment's workspace, as the Variable Library or --workspace-id names it."""

    environment: str  # the --env name
    source: str  # where it was read, for messages: a value set, or --workspace-id
    workspace_id: str


def _shown(path: Path) -> str:
    """A path as a message shows it: from the repo root, where it is inside the repo."""
    try:
        return path.relative_to(REPO).as_posix()
    except ValueError:
        return path.as_posix()


def _read_json(path: Path) -> dict:
    """Read one JSON part of an item, with a byte-order mark or without."""
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read {_shown(path)}: {exc}")


def env_value(key: str) -> str:
    """Resolve a key as the scripts/data wrappers do: the environment, then .env at the repo root.

    In .env a key's value is everything after the first = on the first line that starts KEY=,
    carriage returns dropped and nothing trimmed, which is sql.sh's rule.

    Returns:
        The value, or '' where neither holds the key.
    """
    if os.environ.get(key):
        return os.environ[key]
    try:
        text = (REPO / ".env").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    for line in text.split("\n"):
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].replace("\r", "")
    return ""


def fabric_token() -> str:
    """Return the Azure CLI's token for the Fabric API, logging in first when it has none.

    az is a .cmd shim on Windows, which CreateProcess runs only by its full path, so the path
    shutil.which() resolves through PATHEXT is what runs: the bare name raised FileNotFoundError
    (2026-10-13). Windows hands a .cmd to cmd.exe, which parses its arguments too, so every
    argument is a constant but the tenant, and that is checked first. The token comes back on
    stdout.

    Returns:
        The bearer token.

    Raises:
        SystemExit: if az is missing, AZURE_TENANT_ID is not a tenant, or no token can be had,
            even after a login, or without one when SKIP_AZ_LOGIN=1.
    """
    az = shutil.which("az")
    if not az:
        sys.exit("error: az not found on PATH (winget install Microsoft.AzureCLI)")
    get = [az, "account", "get-access-token", "--resource", RESOURCE,
           "--query", "accessToken", "-o", "tsv"]
    result = subprocess.run(get, capture_output=True, text=True, encoding="utf-8",
                            errors="replace", check=False)
    if result.returncode != 0 and os.environ.get("SKIP_AZ_LOGIN") != "1":
        # The login the scripts/data wrappers start: a Fabric-only tenant has no subscription,
        # and an account that is a guest in several tenants needs the tenant named.
        login = [az, "login", "--allow-no-subscriptions", "--scope", f"{RESOURCE}/.default",
                 "-o", "none"]
        tenant = env_value("AZURE_TENANT_ID")
        if tenant:
            if not _TENANT.fullmatch(tenant):
                sys.exit(f"error: AZURE_TENANT_ID {tenant!r} is neither a GUID nor a domain name")
            login += ["--tenant", tenant]
        print(f"note: no Azure CLI token for {RESOURCE}; starting az login", file=sys.stderr)
        if subprocess.run(login, check=False).returncode != 0:
            sys.exit("error: az login failed")
        result = subprocess.run(get, capture_output=True, text=True, encoding="utf-8",
                                errors="replace", check=False)
    token = result.stdout.strip()
    if result.returncode != 0 or not token:
        skipped = ", and SKIP_AZ_LOGIN=1" if os.environ.get("SKIP_AZ_LOGIN") == "1" else ""
        sys.exit(f"error: no Azure CLI token for {RESOURCE}{skipped}: {result.stderr.strip()}")
    return token


def load_workspaces() -> dict[str, Workspace]:
    """Read each environment's workspace from the Variable Library.

    The rules are build_real_time_dashboard.py's load_bindings(), reading the reference's
    workspaceId where that reads its itemId, so a change to one is a change to both. The default
    value set is variables.json, and each valueSets/*.json overrides it, as Fabric resolves them.
    Each value set is an environment, named by ENVIRONMENT_VARIABLE lower-cased. The default value
    set is one too, unless its name is empty or a value set names the same environment with the
    same workspace.

    Returns:
        The --env name -> its workspace.

    Raises:
        SystemExit: if the library lacks either variable, a value set names no environment, two
            name the same one, an environment's reference holds no workspaceId, or two
            environments share a workspace. Each would point the update at a workspace other than
            the one --env names, and nothing would say so.
    """
    library = _read_json(LIBRARY / "variables.json")
    defaults = {variable.get("name"): variable.get("value")
                for variable in library.get("variables", [])}
    shown = _shown(LIBRARY)
    for variable in (REFERENCE_VARIABLE, ENVIRONMENT_VARIABLE):
        if variable not in defaults:
            sys.exit(f"error: {shown} defines no variable {variable!r}; set REFERENCE_VARIABLE "
                     f"and ENVIRONMENT_VARIABLE, or name the workspace with --workspace-id")

    def environment_of(variables: dict) -> str:
        return str(variables.get(ENVIRONMENT_VARIABLE) or "").strip().lower()

    def workspace_of(variables: dict, source: str) -> str:
        reference = variables.get(REFERENCE_VARIABLE)
        workspace = reference.get("workspaceId") if isinstance(reference, dict) else None
        if not (isinstance(workspace, str) and _GUID.fullmatch(workspace)):
            sys.exit(f"error: {shown}, {source}: {REFERENCE_VARIABLE} holds no workspaceId GUID")
        return workspace.lower()

    workspaces: dict[str, Workspace] = {}
    for path in sorted((LIBRARY / "valueSets").glob("*.json")):
        source = f"valueSets/{path.name}"
        overrides = {override.get("name"): override.get("value")
                     for override in _read_json(path).get("variableOverrides", [])}
        variables = {**defaults, **overrides}
        environment = environment_of(variables)
        if not environment:
            sys.exit(f"error: {shown}, {source}: {ENVIRONMENT_VARIABLE} is empty, so --env "
                     f"cannot name it")
        if environment in workspaces:
            sys.exit(f"error: {shown}: {workspaces[environment].source} and {source} both name "
                     f"environment {environment!r}")
        workspaces[environment] = Workspace(environment, source, workspace_of(variables, source))

    environment = environment_of(defaults)
    if environment:
        source = "the default value set"
        workspace_id = workspace_of(defaults, source)
        existing = workspaces.get(environment)
        if existing is None:
            workspaces[environment] = Workspace(environment, source, workspace_id)
        elif existing.workspace_id != workspace_id:
            sys.exit(f"error: {shown}: {source} and {existing.source} both name environment "
                     f"{environment!r}, with different workspaces")
    if not workspaces:
        sys.exit(f"error: {shown} names no environment: {ENVIRONMENT_VARIABLE} is empty in "
                 f"every value set")

    owners: dict[str, Workspace] = {}
    for workspace in workspaces.values():
        other = owners.setdefault(workspace.workspace_id, workspace)
        if other is not workspace:
            sys.exit(f"error: {shown}: environments {other.environment!r} ({other.source}) and "
                     f"{workspace.environment!r} ({workspace.source}) share one workspace, so an "
                     f"update there names neither. A value set that lost its override of "
                     f"{REFERENCE_VARIABLE} inherits the default's")
    return workspaces


def describe(error: dict, fallback: str) -> str:
    """One line from a Fabric error: its errorCode and message, then each of its moreDetails.

    moreDetails is where a failed update names the item that stopped it, and why (seen
    2026-10-13).
    """
    lines = []
    for entry in [error, *(error.get("moreDetails") or [])]:
        if not isinstance(entry, dict):
            continue
        code = str(entry.get("errorCode") or (fallback if entry is error else ""))
        message = str(entry.get("message") or "").strip()
        lines.append(": ".join(part for part in (code, message) if part))
    return "; ".join(line for line in lines if line) or fallback


def call(token: str, method: str, url: str,
         body: dict | None = None) -> tuple[int, Message, dict]:
    """Send one request.

    Returns:
        The status code, the headers, and the JSON body, {} when there is none.

    Raises:
        FabricError: on an error status, carrying Fabric's errorCode and message, or when the
            request gets no answer at all.
    """
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    where = f"{method} {urllib.parse.urlsplit(url).path}"
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
            payload = json.loads(raw) if raw.strip() else {}
            return response.status, response.headers, payload if isinstance(payload, dict) else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            detail = json.loads(raw)
        except ValueError:
            detail = None
        if not isinstance(detail, dict):
            detail = {"message": raw.decode("utf-8", "replace").strip()}
        raise FabricError(f"{where}: {describe(detail, f'HTTP {error.code}')}") from None
    except ValueError as error:
        raise FabricError(f"{where}: an answer that is not JSON: {error}") from None
    except (OSError, http.client.HTTPException) as error:
        raise FabricError(f"{where}: no whole answer: {error!r}") from None


def run(token: str, method: str, url: str, body: dict | None = None, *,
        result: bool = False) -> dict:
    """Send one call, and see a long-running one through.

    Fabric answers a long-running call 200 when it finished at once, or 202 with a Location to
    poll. Once the operation succeeds, Location plus /result holds its answer, where it has one:
    Get Status does, Update From Git does not. The Location can name a regional host rather than
    the API's own (seen 2026-09-30), and every poll carries the token, so it has to keep the
    API's scheme: a token never goes out over plain HTTP.

    Args:
        token: Bearer token for the Fabric API.
        method: HTTP method.
        url: Request URL.
        body: JSON body to send, if any.
        result: Fetch the operation's result once a 202 has run to success.

    Returns:
        The response body, or the operation's result; {} when there is neither.

    Raises:
        FabricError: if the call is refused, the operation fails, or it runs past POLL_LIMIT.
    """
    status, headers, payload = call(token, method, url, body)
    if status != 202:
        return payload
    location = headers.get("Location")
    if not location:
        raise FabricError(f"{method} {url}: 202 with no Location to poll")
    if urllib.parse.urlsplit(location).scheme != urllib.parse.urlsplit(API).scheme:
        raise FabricError(f"{method} {url}: 202 with a Location this script will not send the "
                          f"token to: {location}")
    deadline = time.monotonic() + POLL_LIMIT
    while True:
        time.sleep(POLL)
        _, _, operation = call(token, "GET", location)
        state = operation.get("status")
        if state == "Succeeded":
            break
        if state in ("Failed", "Undefined"):
            error = operation.get("error")
            detail = describe(error, str(state)) if isinstance(error, dict) else "no error given"
            raise FabricError(f"operation {state}: {detail}")
        if time.monotonic() > deadline:
            raise FabricError(f"operation still {state} after {POLL_LIMIT} s: {location}. It may "
                              f"yet finish: read the status with --dry-run once it has")
    return call(token, "GET", f"{location}/result")[2] if result else {}


def _changed(value: object) -> bool:
    """Whether a Get Status change field holds a change: none reads as null, or as "None"."""
    return bool(value) and value != "None"


def named(status: dict, side: str, only: str | None = None) -> list[str]:
    """Name each item with a change on one side of a Get Status answer.

    Args:
        status: A Get Status answer.
        side: remoteChange, workspaceChange or conflictType.
        only: Keep just this value of the side, such as Conflict.

    Returns:
        One 'name (type) change' per item.
    """
    entries = []
    for change in status.get("changes") or []:
        value = change.get(side)
        if not _changed(value) or (only and value != only):
            continue
        item = change.get("itemMetadata") or {}
        entries.append(f"{item.get('displayName', '?')} ({item.get('itemType', '?')}) {value}")
    return entries


def incoming_types(status: dict) -> set[str]:
    """Return the item types the incoming commits change."""
    return {(change.get("itemMetadata") or {}).get("itemType", "")
            for change in status.get("changes") or []
            if _changed(change.get("remoteChange"))}


def short(sha: object) -> str:
    """A commit hash as the output shows it."""
    return str(sha)[:7] if sha else "none"


def show(label: str, entries: list[str]) -> None:
    """Print each entry under a label."""
    for entry in entries:
        print(f"  {label}: {entry}")


def main() -> int:
    """Parse the arguments, then read the workspace's Git status and update it from its branch."""
    # A display name can hold any character, and a Windows console's code page cannot print them
    # all; a backslash escape beats a UnicodeEncodeError halfway through an update.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--env", "-E", default=DEFAULT_ENV, metavar="NAME",
                        help=f"whose workspace to update, as the Variable Library names it: one "
                             f"of {', '.join(GIT_SYNCED)} (default: {DEFAULT_ENV})")
    parser.add_argument("--workspace-id", metavar="GUID",
                        help="update this workspace instead of reading the Variable Library; "
                             "--env must still be one of GIT_SYNCED, and names the run")
    parser.add_argument("--dry-run", action="store_true",
                        help="read the connection and the status, and change nothing")
    args = parser.parse_args()

    env = args.env.strip().lower()
    if env not in GIT_SYNCED:
        parser.error(f"argument --env: {args.env!r} is not in GIT_SYNCED "
                     f"({', '.join(GIT_SYNCED)}): only those environments' workspaces change by "
                     f"an update from Git, and deployment pipelines promote the rest")
    if args.workspace_id is not None:
        if not _GUID.fullmatch(args.workspace_id):
            parser.error(f"argument --workspace-id: {args.workspace_id!r} is not a GUID")
        workspace = Workspace(env, "--workspace-id", args.workspace_id.lower())
    else:
        workspaces = load_workspaces()
        if env not in workspaces:
            parser.error(f"argument --env: the Variable Library names no environment {env!r} "
                         f"(it names {', '.join(map(repr, sorted(workspaces)))})")
        workspace = workspaces[env]

    base = f"{API}/workspaces/{workspace.workspace_id}"
    git = f"{base}/git"
    token = fabric_token()
    try:
        name = run(token, "GET", base).get("displayName", "?")
        connection = run(token, "GET", f"{git}/connection")
        state = connection.get("gitConnectionState")
        if state != "ConnectedAndInitialized":
            print(f"{env}: {name} ({workspace.workspace_id}) reads {state}, not "
                  f"ConnectedAndInitialized, so there is nothing to update")
            return 1
        branch = (connection.get("gitProviderDetails") or {}).get("branchName") or "?"
        print(f"{env}: {name} ({workspace.workspace_id}, from {workspace.source}) tracks {branch}")
        before = run(token, "GET", f"{git}/status", result=True)
        head, tip = before.get("workspaceHead"), before.get("remoteCommitHash")
        if not tip:
            raise FabricError("Get Status gave no remoteCommitHash, so there is no head to "
                              "update to")
        print(f"{env}: the workspace is at {short(head)}, {branch} at {short(tip)}")
        show("incoming", named(before, "remoteChange"))
        show("uncommitted", named(before, "workspaceChange"))
        if head == tip:
            print(f"{env}: already at {branch}'s head")
            return 0
        conflicts = named(before, "conflictType", only="Conflict")
        if conflicts:
            show("conflict", conflicts)
            print(f"{env}: not updated: choose each conflicting item's side in the Source "
                  "control pane")
            return 3
        if args.dry_run:
            print(f"{env}: --dry-run, so not updated")
            return 0
        started = time.monotonic()
        run(token, "POST", f"{git}/updateFromGit", {
            "workspaceHead": head,
            "remoteCommitHash": tip,
            "options": {"allowOverrideItems": True},
        })
        print(f"{env}: updated to {short(tip)} in {time.monotonic() - started:.0f} s")
        after = run(token, "GET", f"{git}/status", result=True)
    except FabricError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    show("still uncommitted", named(after, "workspaceChange"))
    kinds = incoming_types(before)
    for types, note in NOT_REACHED:
        if kinds & types:
            print(f"  note: {note}")
    if after.get("workspaceHead") != tip:
        print(f"{env}: the workspace reads {short(after.get('workspaceHead'))}, not "
              f"{short(tip)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
