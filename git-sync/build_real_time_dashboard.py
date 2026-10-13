#!/usr/bin/env python
"""Build a Real-Time dashboard's RealTimeDashboard.json from the spec in this file.

THIS SCRIPT IS THE DASHBOARD'S AUTHORITY. Its pages and tiles are edited here and the script is
rerun; the JSON is never edited by hand or in the portal. A tile changed in the portal has to be
folded back into the spec, or the next run removes it, and --check is how that drift shows. In
return a tile reviews like code: a few lines of Python beside the query that feeds it.

THE BINDING IS THE ONE PART THAT DIFFERS BY ENVIRONMENT. The data source names its KQL database
twice: `database` is the database's logicalId from its .platform, the same in every environment
and what Git sync resolves inside the workspace, and `databaseArtifactId` is its item id, which
is not. The item id comes from the workspace's Variable Library, resolved for the environment
--env names, so the script holds no GUID but its own namespace. Deployment pipelines neither
rebind a dashboard's data source nor offer a rule for one, so an environment's dashboard reads
its own database only while it holds that environment's build.

IDS ARE DETERMINISTIC. Every id is uuid5(NAMESPACE, label), and the bytes are the portal's own
(indent 2, CRLF, no final newline), so a rerun writes the same file, and Git sync never reads a
regenerated one as every tile deleted and recreated. A page or tile key is its identity: never
change one once it has shipped. Titles are free to change.

Usage, from the repo root:
    python scripts/git-sync/build_real_time_dashboard.py                    # write, DEFAULT_ENV
    python scripts/git-sync/build_real_time_dashboard.py --env test         # write, bound to test
    python scripts/git-sync/build_real_time_dashboard.py --check            # compare, no writes
    python scripts/git-sync/build_real_time_dashboard.py --test --env dev   # run every tile

--check compares the committed file with this script's build for --env, byte for byte. --test
writes nothing either: it runs each tile's query through scripts/data/kql.sh, in --env and
against the database the build binds to, which is the only check a query gets before the portal
loads it. A tile fails on a query Kusto refuses, and on one it answers but flags as incomplete
or possibly wrong (kql.sh's exit 3), because the portal marks that tile too.

Exit status: 0 ok; 1 when --check finds a difference, a tile fails under --test, or the spec,
the Variable Library or a .platform does not give what the build needs; 2 for a usage error.

Standard library only, Python 3.10 or later.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import NamedTuple

# ---------------------------------------------------------------------------------------------
# Settings: set these once, when the script is copied into a repo
# ---------------------------------------------------------------------------------------------

# The script lives two levels below the repo root, at scripts/git-sync/, as the kql.sh that
# --test runs lives at scripts/data/.
REPO = Path(__file__).resolve().parents[2]

# The workspace folder Git sync writes, and the items the build reads or writes in it. Git sync
# has put a KQL database inside its Eventhouse's folder, under .children/ (2026-09-16), where
# Learn's example shows it beside the Eventhouse: use the path the repo holds.
WORKSPACE = REPO / "<workspace-folder>"
DASHBOARD = WORKSPACE / "<DashboardName>.KQLDashboard" / "RealTimeDashboard.json"
DATABASE_PLATFORM = (WORKSPACE / "<EventhouseName>.Eventhouse" / ".children"
                     / "<KqlDatabaseName>.KQLDatabase" / ".platform")
LIBRARY = WORKSPACE / "<VariableLibraryName>.VariableLibrary"

# The Variable Library's two variables the binding reads: an ItemReference to the KQL database,
# and a String naming the environment. That name, lower-cased, is what --env takes.
REFERENCE_VARIABLE = "<KqlDatabaseReferenceVariable>"
ENVIRONMENT_VARIABLE = "<EnvironmentNameVariable>"

# The environment main holds, so the one a bare run writes and --check compares against.
DEFAULT_ENV = "dev"

# The data source's name in the portal: {database} is the KQL database's display name and
# {environment} the --env value, so the portal shows which environment's build it holds.
DATA_SOURCE_NAME = "{database}_{environment}"

# Every id in the file derives from this. Mint it once for this dashboard and commit it:
#     python -c "import uuid; print(uuid.uuid4())"
# A new namespace changes every id, which the portal reads as every page and tile deleted and
# recreated. Never copy one from another dashboard.
NAMESPACE = "<namespace-uuid>"

# ---------------------------------------------------------------------------------------------
# Tiles and pages: what the spec is written in
# ---------------------------------------------------------------------------------------------


class Tile(NamedTuple):
    """One tile. The key is its identity; x, y, width and height are on the 24-column grid."""

    key: str
    title: str
    visual: str
    x: int
    y: int
    width: int
    height: int
    options: dict
    query: str


class Page(NamedTuple):
    """One page: its name as the portal shows it, and its tiles."""

    name: str
    tiles: list[Tile]


GRID_COLUMNS = 24

# A multistat needs this many grid units per slot, across and down, and nothing says so until
# the portal draws the tile. The dashboard loads, the tile shows "An error occurred", and its
# details read "Current tile size (12, 5) is smaller than the minimum supported tile size
# (15, 3)": a 12x5 tile with five slots in a row (2026-09-30). The JSON schema and the tile's
# query had both passed. A sandbox dashboard held the rule from one slot at 3x3 to a 5x5 grid of
# slots at 15x15, across and down (2026-10-01). problems() holds every multistat to it.
SLOT_SIZE = 3
MAX_SLOTS = 5


def card() -> dict:
    """The visualOptions of a card, which takes none: the query's single value is the figure."""
    return {}


def multistat(across: int, down: int = 1, label: str = "Metric", value: str = "Value") -> dict:
    """The visualOptions of a multistat: a slot to each row of the query, across then down.

    Args:
        across: Slots in a row, 1 to 5. The tile needs SLOT_SIZE columns for each.
        down: Rows of slots, 1 to 5. The tile needs SLOT_SIZE rows for each.
        label: The query's column naming each figure.
        value: The query's column holding it.

    Returns:
        The tile's visualOptions.
    """
    return {
        "multiStat__displayOrientation": "horizontal",
        "multiStat__labelColumn": label,
        "multiStat__valueColumn": value,
        "multiStat__slot": {"width": across, "height": down},
        "multiStat__textSize": "auto",
    }


def chart(x_column: str, y_column: str) -> dict:
    """The visualOptions of a bar, column or line chart of one series, its legend hidden."""
    return {"hideLegend": True, "xColumn": x_column, "yColumns": [y_column]}


# A tile has no number format, so a figure is formatted in KQL and shown as text. Kusto has no
# format_number() and RE2 has no lookahead, so the grouping is spelled out. money() rounds to the
# cent and carries ($999.995 is $1,000.00); whole() groups an integer. Both group through the
# millions: a billion or more prints its leading digits ungrouped. A figure in text loses a
# card's own 1.2K shortening, which is the point; numbers on a chart's axis stay numbers.
MONEY = """let money = (v: real) {
    let r = round(v, 2);
    let a = abs(r);
    let w = tolong(a);
    let c = tolong(round((a - todouble(w)) * 100, 0));
    let cw = iff(c >= 100, w + 1, w);
    let cc = iff(c >= 100, long(0), c);
    let m = cw / 1000000;
    let t = (cw % 1000000) / 1000;
    let u = cw % 1000;
    let t3 = substring(strcat("00", tostring(t)), strlen(strcat("00", tostring(t))) - 3);
    let u3 = substring(strcat("00", tostring(u)), strlen(strcat("00", tostring(u))) - 3);
    let whole = case(m > 0, strcat(tostring(m), ",", t3, ",", u3),
                     t > 0, strcat(tostring(t), ",", u3), tostring(u));
    let c2 = substring(strcat("0", tostring(cc)), strlen(strcat("0", tostring(cc))) - 2);
    strcat(iff(r < 0, "-", ""), "$", whole, ".", c2)
};"""
WHOLE = """let whole = (v: long) {
    let a = abs(v);
    let m = a / 1000000;
    let t = (a % 1000000) / 1000;
    let u = a % 1000;
    let t3 = substring(strcat("00", tostring(t)), strlen(strcat("00", tostring(t))) - 3);
    let u3 = substring(strcat("00", tostring(u)), strlen(strcat("00", tostring(u))) - 3);
    strcat(iff(v < 0, "-", ""), case(m > 0, strcat(tostring(m), ",", t3, ",", u3),
                                     t > 0, strcat(tostring(t), ",", u3), tostring(u)))
};"""

# =============================================================================================
# THE SPEC: this dashboard's refresh settings, pages and tiles. Everything from here to the
# engine below is this dashboard's own; replace the sample with it.
# =============================================================================================

# Live refresh: an open page checks the newest ingestion time of what its tiles read and reruns
# a tile only when that moves. minRefreshRate is the portal's "Refresh rate limit", and
# fallbackRefreshRate the interval for a visual that cannot detect ingestion. Measured on one
# dashboard with one viewer (2026-09-30): about 0.02 s of CPU a check, a check every 30 s, and
# 2.4 to 3.6 s a page load. Several viewers, or a page open all day, not measured.
AUTO_REFRESH = {"enabled": True, "defaultInterval": "5m", "minInterval": "30s"}
CHANGE_DETECTION = {"kind": "liveUpdates", "minRefreshRate": "30s", "fallbackRefreshRate": "5m"}


class Fact(NamedTuple):
    """A tabular source with a row per fact, and the two columns a tile reads from it."""

    source: str
    time: str
    value: str


# The tiles read their facts from one source. Make that a stored function, so what a fact is
# lives in the database once and a tile only picks a window and sums, then name it here, as in
# Fact("Orders()", "OrderTime", "Amount"). Until then SAMPLE stands in for it with rows made up
# on the spot, so the dashboard draws against any KQL database and --test passes there. A base
# query would not do the function's job: it is a `let` pasted into each tile that lists it, so
# it shares text, not work.
SAMPLE = Fact(
    source=("range Timestamp from startofmonth(now()) to now() step 15m\n"
            "| extend Amount = hash(tostring(Timestamp), 100000) / 100.0"),
    time="Timestamp",
    value="Amount",
)

# now() is UTC. A business whose day ends in another zone wants a stored function returning its
# own date, read here in place of startofday(now()), so that every tile agrees on what today is.
TODAY = "let Today = startofday(now());"


def since(fact: Fact, start: str) -> str:
    """The fact's rows from the start of a day to now: Today, or startofmonth(Today)."""
    return f"{fact.source}\n| where {fact.time} >= {start}"


def total_query(fact: Fact, start: str) -> str:
    """The fact's value from a start to now, as money."""
    return f"""{MONEY}
{TODAY}
{since(fact, start)}
| summarize Total = sum({fact.value})
| project Total = money(toreal(Total))"""


def count_query(fact: Fact, start: str) -> str:
    """How many facts there are from a start to now."""
    return f"""{WHOLE}
{TODAY}
{since(fact, start)}
| summarize Total = count()
| project Total = whole(Total)"""


def pace_query(fact: Fact) -> str:
    """Today beside the month's average day so far, and as a share of it.

    Three figures, one to each slot of the tile's multistat. A day with no facts has no row, so
    the average is over the days that had some; a calendar or business-day function would count
    the others.
    """
    days = since(fact, "startofmonth(Today)").replace("\n", "\n    ")
    return f"""{MONEY}
{TODAY}
let Days = materialize(
    {days}
    | summarize DayTotal = sum({fact.value}) by Day = startofday({fact.time}));
let TodayTotal = coalesce(
    toreal(toscalar(Days | where Day == Today | summarize sum(DayTotal))), 0.0);
let Average = toscalar(Days
    | where Day < Today
    | summarize Count = count(), Total = sum(DayTotal)
    | project iff(Count == 0, real(null), toreal(Total) / Count));
union
    (print Ord = 1, Metric = "Today", Value = money(TodayTotal)),
    (print Ord = 2, Metric = "Average Day", Value = iff(isnull(Average), "", money(Average))),
    (print Ord = 3, Metric = "% of Average",
        Value = iff(isnull(Average) or Average == 0, "n/a",
                    strcat(tostring(round(100.0 * TodayTotal / Average, 1)), "%")))
| order by Ord asc
| project Metric, Value"""


def by_day_query(fact: Fact, column: str) -> str:
    """The fact's value by day this month, for a chart."""
    return f"""{TODAY}
{since(fact, "startofmonth(Today)")}
| summarize ['{column}'] = round(toreal(sum({fact.value})), 2) by Day = startofday({fact.time})
| order by Day asc"""


PAGES: dict[str, Page] = {
    "overview": Page("Overview", [
        Tile("value-today", "Sample Value Today ($)", "card", 0, 0, 6, 4, card(),
             total_query(SAMPLE, "Today")),
        Tile("rows-today", "Sample Rows Today (#)", "card", 6, 0, 6, 4, card(),
             count_query(SAMPLE, "Today")),
        # Three figures in a row need 9 of the 24 columns and 3 rows (SLOT_SIZE).
        Tile("pace", "Sample Today against the Month", "multistat", 12, 0, 12, 4,
             multistat(3), pace_query(SAMPLE)),
        Tile("value-by-day", "Sample Value by Day, This Month ($)", "column", 0, 4, 24, 8,
             chart("Day", "Value ($)"), by_day_query(SAMPLE, "Value ($)")),
    ]),
}

# =============================================================================================
# THE ENGINE: nothing below here is specific to one dashboard
# =============================================================================================

# The definition as the portal committed it at this schema version (2026-09-30). Learn's sample
# schema for RealTimeDashboard.json is an older shape and is not what the portal writes.
SCHEMA_VERSION = 81
FLAVOR = "RTDashboard_Regular"
# A data source's workspace of all zeros is the dashboard's own workspace.
SAME_WORKSPACE = "00000000-0000-0000-0000-000000000000"
_GUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

KQL_WRAPPER = REPO / "scripts" / "data" / "kql.sh"

# Inside a Git for Windows root: the MSYS bash first, the bin\ launcher second. The launcher
# shares its name with System32's bash.exe, so the Defender ASR rule "Block use of copied or
# impersonated system tools" refuses it, CreateProcess raising WinError 5, while usr\bin\bash.exe
# runs (2026-09-18).
GIT_BASH_RELATIVE = (Path("usr") / "bin" / "bash.exe", Path("bin") / "bash.exe")
# `bash` on a Windows PATH is usually the WSL launcher, System32's or the WindowsApps alias,
# which fails on a Windows path with `execvpe(/bin/bash) failed`.
WSL_BASH_MARKERS = ("\\system32\\", "\\windowsapps\\")


class Binding(NamedTuple):
    """One environment's KQL database, as the dashboard's data source points at it."""

    environment: str  # the --env name
    source: str  # where it was read, for messages: a value set, or --database-id
    item_id: str  # the database's item id in that environment: databaseArtifactId


def _shown(path: Path) -> str:
    """A path as a message shows it: from the repo root, where it is inside the repo."""
    try:
        return path.relative_to(REPO).as_posix()
    except ValueError:
        return path.as_posix()


SCRIPT = _shown(Path(__file__).resolve())


def _read_json(path: Path) -> dict:
    """Read one JSON part of an item, with a byte-order mark or without."""
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as exc:
        sys.exit(f"error: cannot read {_shown(path)}: {exc}")


def uid(label: str) -> str:
    """The id of one labelled part of the dashboard, the same on every run."""
    return str(uuid.uuid5(uuid.UUID(NAMESPACE), label))


def load_bindings() -> dict[str, Binding]:
    """Read each environment's KQL database from the Variable Library.

    The default value set is variables.json, and each valueSets/*.json overrides it, as Fabric
    resolves them. Each value set is an environment, named by ENVIRONMENT_VARIABLE lower-cased.
    The default value set is one too, unless its name is empty or a value set names the same
    environment with the same database, so a library whose Dev runs on the defaults and one
    that gives Dev a value set of its own both read as they mean. update_from_git.py reads the
    library by the same rules, for the reference's workspaceId, so a change to one is a change
    to both.

    Returns:
        The --env name -> its binding.

    Raises:
        SystemExit: if the library lacks either variable, a value set names no environment, two
            name the same one, an environment's reference holds no item id, or two environments
            share a database. Each would bind the dashboard to a database other than the one
            --env names, and nothing would say so.
    """
    library = _read_json(LIBRARY / "variables.json")
    defaults = {variable.get("name"): variable.get("value")
                for variable in library.get("variables", [])}
    shown = _shown(LIBRARY)
    for variable in (REFERENCE_VARIABLE, ENVIRONMENT_VARIABLE):
        if variable not in defaults:
            sys.exit(f"error: {shown} defines no variable {variable!r}; set REFERENCE_VARIABLE "
                     f"and ENVIRONMENT_VARIABLE, or bind with --database-id")

    def environment_of(variables: dict) -> str:
        return str(variables.get(ENVIRONMENT_VARIABLE) or "").strip().lower()

    def item_of(variables: dict, source: str) -> str:
        reference = variables.get(REFERENCE_VARIABLE)
        item = reference.get("itemId") if isinstance(reference, dict) else None
        if not (isinstance(item, str) and _GUID.fullmatch(item)):
            sys.exit(f"error: {shown}, {source}: {REFERENCE_VARIABLE} holds no itemId GUID")
        return item.lower()

    bindings: dict[str, Binding] = {}
    for path in sorted((LIBRARY / "valueSets").glob("*.json")):
        source = f"valueSets/{path.name}"
        overrides = {override.get("name"): override.get("value")
                     for override in _read_json(path).get("variableOverrides", [])}
        variables = {**defaults, **overrides}
        environment = environment_of(variables)
        if not environment:
            sys.exit(f"error: {shown}, {source}: {ENVIRONMENT_VARIABLE} is empty, so --env "
                     f"cannot name it")
        if environment in bindings:
            sys.exit(f"error: {shown}: {bindings[environment].source} and {source} both name "
                     f"environment {environment!r}")
        bindings[environment] = Binding(environment, source, item_of(variables, source))

    environment = environment_of(defaults)
    if environment:
        source = "the default value set"
        item = item_of(defaults, source)
        named = bindings.get(environment)
        if named is None:
            bindings[environment] = Binding(environment, source, item)
        elif named.item_id != item:
            sys.exit(f"error: {shown}: {source} and {named.source} both name environment "
                     f"{environment!r}, with different databases")
    if not bindings:
        sys.exit(f"error: {shown} names no environment: {ENVIRONMENT_VARIABLE} is empty in "
                 f"every value set")

    owners: dict[str, Binding] = {}
    for binding in bindings.values():
        other = owners.setdefault(binding.item_id, binding)
        if other is not binding:
            sys.exit(f"error: {shown}: environments {other.environment!r} ({other.source}) and "
                     f"{binding.environment!r} ({binding.source}) share one database, so a "
                     f"build bound to it names neither. A value set that lost its override of "
                     f"{REFERENCE_VARIABLE} inherits the default's")
    return bindings


def read_database() -> tuple[str, str]:
    """The KQL database's logicalId and display name, from its .platform.

    Returns:
        The logicalId, which a data source's `database` holds, and the display name.

    Raises:
        SystemExit: if DATABASE_PLATFORM is not a KQL database's .platform with a logicalId.
    """
    shown = _shown(DATABASE_PLATFORM)
    platform = _read_json(DATABASE_PLATFORM)
    try:
        kind = platform["metadata"]["type"]
        name = platform["metadata"]["displayName"]
        logical_id = platform["config"]["logicalId"]
    except (KeyError, TypeError) as exc:
        sys.exit(f"error: {shown} holds no {exc}")
    if kind != "KQLDatabase":
        sys.exit(f"error: {shown} is a {kind}'s, not a KQL database's: check DATABASE_PLATFORM")
    if not (isinstance(logical_id, str) and _GUID.fullmatch(logical_id)):
        sys.exit(f"error: {shown}: logicalId {logical_id!r} is not a GUID")
    return logical_id, name


def build(binding: Binding, database: tuple[str, str]) -> dict:
    """The dashboard's definition, bound to one environment's database.

    The order of keys, and of tiles before queries, is the portal's own, so that a portal round
    trip changes nothing. One data source serves every query.
    """
    logical_id, display_name = database
    data_source = uid("datasource")
    tiles, queries = [], []
    for page_key, page in PAGES.items():
        for tile in page.tiles:
            query = uid(f"query:{tile.key}")
            queries.append({
                "dataSource": {"kind": "inline", "dataSourceId": data_source},
                "text": tile.query,
                "id": query,
                "usedVariables": [],
            })
            tiles.append({
                "id": uid(f"tile:{tile.key}"),
                "queryRef": {"kind": "query", "queryId": query},
                "title": tile.title,
                "visualType": tile.visual,
                "pageId": uid(f"page:{page_key}"),
                "layout": {"x": tile.x, "y": tile.y, "width": tile.width, "height": tile.height},
                "visualOptions": tile.options,
            })
    return {
        "schema_version": SCHEMA_VERSION,
        "flavor": FLAVOR,
        "autoRefresh": AUTO_REFRESH,
        "changeDetection": CHANGE_DETECTION,
        "tiles": tiles,
        "baseQueries": [],
        "parameters": [],
        "dataSources": [{
            "kind": "kusto-trident",
            "name": DATA_SOURCE_NAME.format(database=display_name,
                                            environment=binding.environment),
            "clusterUri": "",
            "databaseArtifactId": binding.item_id,
            "database": logical_id,
            "workspace": SAME_WORKSPACE,
            "id": data_source,
        }],
        "pages": [{"name": page.name, "id": uid(f"page:{key}")} for key, page in PAGES.items()],
        "queries": queries,
        "embeddedApps": [],
    }


def problems(dashboard: dict) -> list[str]:
    """What the portal would refuse and its JSON schema does not catch.

    The portal refuses most of these at load, and a multistat too small for its slots when it
    draws the tile. A character beyond ASCII is refused too, because serialize() cannot yet
    write one as the portal would.

    Returns:
        One line per problem; empty when there is none.
    """
    found = []
    beyond_ascii = ("has a character beyond ASCII; keep to ASCII until a portal commit shows how "
                    "the portal writes one (see serialize())")
    keys = [tile.key for page in PAGES.values() for tile in page.tiles]
    found += [f"tile key {key!r} is used twice" for key in sorted(set(keys)) if keys.count(key) > 1]
    references = sorted(tile["queryRef"]["queryId"] for tile in dashboard["tiles"])
    if references != sorted(query["id"] for query in dashboard["queries"]):
        found.append("the tiles do not reference each query exactly once")
    for page_key, page in PAGES.items():
        if not page.tiles:
            found.append(f"page {page_key} has no tiles")
        if not page.name.isascii():
            found.append(f"page {page_key}'s name {beyond_ascii}")
        for tile in page.tiles:
            where = f"{page_key}/{tile.key}"
            if tile.x < 0 or tile.y < 0:
                found.append(f"{where} starts off the grid, at ({tile.x}, {tile.y})")
            if tile.width < 1 or tile.height < 1:
                found.append(f"{where} is {tile.width}x{tile.height}, and a tile is at least 1x1")
            if tile.x + tile.width > GRID_COLUMNS:
                found.append(f"{where} runs past the {GRID_COLUMNS}-column grid")
            slot = tile.options.get("multiStat__slot")
            if tile.visual == "multistat" and slot is None:
                found.append(f"{where} is a multistat without multistat()'s options")
            if slot is not None:
                across, down = slot.get("width"), slot.get("height")
                if not all(isinstance(n, int) and 1 <= n <= MAX_SLOTS for n in (across, down)):
                    found.append(f"{where} has {across}x{down} slots, and the portal allows 1 to "
                                 f"{MAX_SLOTS} each way")
                elif tile.width < SLOT_SIZE * across or tile.height < SLOT_SIZE * down:
                    found.append(f"{where} is {tile.width}x{tile.height}, and its {across}x{down} "
                                 f"slots need at least {SLOT_SIZE * across}x{SLOT_SIZE * down}")
            for other in page.tiles:
                if (other.key < tile.key and tile.x < other.x + other.width
                        and other.x < tile.x + tile.width and tile.y < other.y + other.height
                        and other.y < tile.y + tile.height):
                    found.append(f"{page_key}: {other.key} and {tile.key} overlap")
            text = tile.title + tile.query + json.dumps(tile.options, ensure_ascii=False)
            if not text.isascii():
                found.append(f"{where} {beyond_ascii}")
    name = dashboard["dataSources"][0]["name"]
    if not name.isascii():
        found.append(f"the data source's name {name!a} {beyond_ascii}")
    return found


def serialize(dashboard: dict) -> bytes:
    """The file's bytes, as the portal writes a JSON part: indent 2, CRLF, no final newline.

    Only ASCII, which problems() holds the dashboard to: no portal commit seen so far has held
    any other character, so how the portal writes one is unknown. json.dumps writes an accented
    letter as a six-character escape, and were the portal to write the letter itself, --check
    would fail the first portal round trip as drift. The portal does write < > ' and + as they
    are, as json.dumps does (every portal-written file seen, 2026-10-01). Once a portal commit
    holds a character beyond ASCII, match what it wrote here and lift the check.
    """
    return json.dumps(dashboard, indent=2).replace("\n", "\r\n").encode("utf-8")


def bound_to(payload: bytes, bindings: dict[str, Binding]) -> str:
    """Say which environment a committed file is bound to, for --check's message."""
    try:
        item = json.loads(payload)["dataSources"][0]["databaseArtifactId"].lower()
    except (ValueError, KeyError, IndexError, TypeError, AttributeError):
        return "no database this script can read"
    for binding in bindings.values():
        if binding.item_id == item:
            return binding.environment
    return f"database {item}, which no environment here names"


def find_bash() -> str:
    r"""A bash that can run kql.sh.

    On Windows, Git for Windows' own: found from `git` on PATH, whose root holds cmd\, bin\ and
    mingw64\bin\, then in the usual install folders, and never the WSL launcher.

    Returns:
        The path to the bash executable.

    Raises:
        SystemExit: if there is none.
    """
    if os.name != "nt":
        found = shutil.which("bash")
        if found:
            return found
        sys.exit("error: bash not found, and kql.sh is a bash script")
    roots: list[Path] = []
    git = shutil.which("git")
    if git:
        folder = Path(git).resolve().parent
        roots += [folder.parent, folder.parent.parent]
    roots.append(Path(os.environ.get("PROGRAMFILES", r"C:\Program Files")) / "Git")
    if os.environ.get("LOCALAPPDATA"):
        roots.append(Path(os.environ["LOCALAPPDATA"]) / "Programs" / "Git")
    for root in roots:
        for relative in GIT_BASH_RELATIVE:
            if (root / relative).is_file():
                return str(root / relative)
    found = shutil.which("bash")
    if found and not any(marker in found.lower() for marker in WSL_BASH_MARKERS):
        return found
    sys.exit("error: Git Bash not found, and kql.sh is a bash script; install Git for Windows")


def run_kql(
    bash: str, binding: Binding, query: str, show_login: bool = False
) -> tuple[int, str, str]:
    r"""Run one query through kql.sh against the bound database, raw.

    The database goes to kql.sh's -d as its item id, which kql.sh's header says a database
    answers to, so the query runs against the database the build binds to, and -E picks that
    environment's cluster from .env. A cluster that does not hold that database fails loudly,
    where a display name, the same in every environment, would quietly answer from another one.

    The query goes in on stdin, as bytes: a text-mode pipe on Windows rewrites every \n as \r\n
    on the way in (2026-09-23), and stdin keeps a long query off the command line. On
    Windows /usr/bin goes to the front of PATH, because a bash started from Windows inherits the
    Windows PATH, where kql.sh's tools would otherwise resolve to System32's or not at all.

    Args:
        bash: The bash to run kql.sh with, from find_bash().
        binding: The environment and database to query.
        query: The KQL.
        show_login: Leave kql.sh's stderr on the console, so its az login prompt shows.

    Returns:
        kql.sh's exit status, its stdout (the raw v1 response) and its stderr.
    """
    arguments = [KQL_WRAPPER.as_posix(), "-E", binding.environment, "-d", binding.item_id, "-r"]
    if os.name == "nt":
        command = [bash, "-c", 'export PATH="/usr/bin:$PATH"; exec bash "$0" "$@"', *arguments]
    else:
        command = [bash, *arguments]
    result = subprocess.run(
        command, cwd=REPO, input=query.encode("utf-8"), stdout=subprocess.PIPE,
        stderr=None if show_login else subprocess.PIPE, check=False,
    )
    return (result.returncode, result.stdout.decode("utf-8", errors="replace"),
            (result.stderr or b"").decode("utf-8", errors="replace"))


def rows_of(response: str) -> list[dict]:
    """The first table of a v1 Kusto response, a dict to each row.

    Raises:
        ValueError: if the response is not one.
    """
    try:
        table = json.loads(response)["Tables"][0]
        columns = [column["ColumnName"] for column in table["Columns"]]
        return [dict(zip(columns, row, strict=True))
                for row in table["Rows"] if isinstance(row, list)]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise ValueError(f"not a Kusto response ({exc}): {response[:200]!r}") from None


def test(binding: Binding) -> int:
    """Run every tile's query against the bound database, and report each.

    Returns:
        How many tiles failed.

    Raises:
        SystemExit: if kql.sh is missing, or cannot run a query there at all.
    """
    if not KQL_WRAPPER.is_file():
        sys.exit(f"error: --test runs {_shown(KQL_WRAPPER)}, which is not there")
    bash = find_bash()
    # One cheap query first, kql.sh's stderr left on the console: on a cold Azure CLI session it
    # logs in, and a captured prompt would look hung. A failure here is the transport's or the
    # binding's, not any tile's, so it stops the run rather than failing every tile alike.
    status, _, _ = run_kql(bash, binding, "print Ready = 1", show_login=True)
    if status != 0:
        sys.exit(f"error: kql.sh could not query {binding.environment}'s database "
                 f"{binding.item_id} (exit {status}; its message is above). Where the cluster "
                 f"says it has no such database, check .env's cluster URI for this environment")
    failed = 0
    for page_key, page in PAGES.items():
        for tile in page.tiles:
            where = f"{page_key}/{tile.key}"
            started = time.monotonic()
            status, response, errors = run_kql(bash, binding, tile.query)
            elapsed = f"{time.monotonic() - started:.1f}s"
            if status != 0:
                failed += 1
                lines = [line for line in errors.splitlines() if line.strip()]
                flagged = [line for line in lines if line.startswith("kusto ")]
                reason = (flagged or lines or [f"kql.sh exited {status}"])[0]
                state = "FLAGGED" if status == 3 else "FAILED"
                print(f"  {state:<8}{where} ({elapsed}): {reason[:300]}")
                continue
            try:
                rows = rows_of(response)
            except ValueError as exc:
                failed += 1
                print(f"  FAILED  {where} ({elapsed}): {exc}")
                continue
            first = rows[0] if rows else {}
            shown = ", ".join(f"{column}={value}" for column, value in first.items())
            print(f"  ok      {where} ({elapsed}): {len(rows)} row(s)  {shown[:110]}")
    return failed


def main() -> int:
    """Parse the arguments, then write, check or test the dashboard."""
    # A row's figures can hold any character, and a Windows console's code page cannot print
    # them all; a backslash escape beats a UnicodeEncodeError halfway through --test.
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # --env is checked against the library once parsed, rather than given its environments as
    # choices, so that --help and a mistyped flag still answer where the library cannot be read.
    parser.add_argument("--env", default=DEFAULT_ENV, metavar="NAME",
                        help="the environment whose KQL database the dashboard binds to, and "
                             f"where --test runs, as the Variable Library names it (default: "
                             f"{DEFAULT_ENV}, which main holds)")
    parser.add_argument("--database-id", metavar="GUID",
                        help="bind to this KQL database item id instead of reading the Variable "
                             "Library; --env then only names the build and picks kql.sh's "
                             "environment")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true",
                      help="verify the committed file is what this script builds; write nothing")
    mode.add_argument("--test", action="store_true",
                      help="run every tile's query in --env through kql.sh; write nothing")
    args = parser.parse_args()

    try:
        uuid.UUID(NAMESPACE)
    except ValueError:
        print(f"error: NAMESPACE is {NAMESPACE!r}, not a UUID. Mint one for this dashboard,\n"
              '       python -c "import uuid; print(uuid.uuid4())"\n'
              f"       and set it in {SCRIPT}", file=sys.stderr)
        return 1
    env = args.env.strip().lower()
    if args.database_id is not None:
        if not _GUID.fullmatch(args.database_id):
            parser.error(f"argument --database-id: {args.database_id!r} is not a GUID")
        bindings = {env: Binding(env, "--database-id", args.database_id.lower())}
    else:
        bindings = load_bindings()
        if env not in bindings:
            parser.error(f"argument --env: invalid choice: {args.env!r} (choose from "
                         f"{', '.join(map(repr, sorted(bindings)))})")
    binding = bindings[env]

    dashboard = build(binding, read_database())
    found = problems(dashboard)
    if found:
        for problem in found:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    if args.test:
        print(f"testing {len(dashboard['tiles'])} tile queries in {env}, against database "
              f"{binding.item_id}:")
        failed = test(binding)
        print(f"{failed} tile(s) failed" if failed else "every tile's query ran clean")
        return 1 if failed else 0

    payload = serialize(dashboard)
    relative = _shown(DASHBOARD)
    shape = (f"{len(dashboard['pages'])} page(s), {len(dashboard['tiles'])} tile(s), bound to "
             f"{env} ({dashboard['dataSources'][0]['name']})")
    if args.check:
        current = DASHBOARD.read_bytes() if DASHBOARD.is_file() else None
        if current == payload:
            print(f"{relative} is what this script builds: {shape}")
            return 0
        state = ("is missing" if current is None
                 else f"is bound to {bound_to(current, bindings)}")
        print(f"::error file={relative}::{relative} is not what {SCRIPT} builds for {env}, and "
              f"the file {state}. Fold any portal edit back into the script, then run: "
              f"python {SCRIPT} --env {env}")
        return 1

    platform = DASHBOARD.parent / ".platform"
    if not platform.is_file():
        print(f"error: {_shown(platform)} is missing; the item's identity is not this script's "
              f"to invent. Create the dashboard in the workspace and commit it from there first",
              file=sys.stderr)
        return 1
    kind = _read_json(platform).get("metadata", {}).get("type")
    if kind != "KQLDashboard":
        print(f"error: {_shown(platform)} is a {kind}'s, not a Real-Time dashboard's: check "
              f"DASHBOARD", file=sys.stderr)
        return 1
    DASHBOARD.write_bytes(payload)
    print(f"wrote {relative}: {shape}, {len(payload)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
