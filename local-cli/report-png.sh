#!/usr/bin/env bash
# Renders a published Power BI report to PNG (or PDF) files via the Power BI
# `exportToFile` REST API — a visual feedback loop with no Power BI Desktop
# involved. Reads the workspace from the repo's .env and authenticates with
# the Azure CLI token, running `az login` for you if the cached session cannot
# mint one (see "Azure CLI login preflight" below).
#
# Requirements beyond auth: the workspace must be on a Fabric/Premium/Embedded
# capacity, and PNG export needs the tenant setting "Export reports as image
# files" enabled (off by default — if PNG returns 403/Failed, retry with
# `-f PDF`, which is enabled by default).
#
# .env keys:
#   PBI_WORKSPACE_ID    workspace (group) GUID — from the workspace URL:
#                       app.powerbi.com/groups/<GUID>/...
#   AZURE_TENANT_ID     optional — passed to `az login` when set
#
# Usage:
#   scripts/data/report-png.sh -l                          # list reports in the workspace
#   scripts/data/report-png.sh -r "<report-name>"       # export all pages to PNG
#   scripts/data/report-png.sh -r <report-guid>            # GUID works too
#   scripts/data/report-png.sh -r "Sales" -p "Overview"    # single page (display name or ReportSection name)
#   scripts/data/report-png.sh -r "Sales" -f PDF           # PDF fallback when PNG is tenant-blocked
#   scripts/data/report-png.sh -r "Sales" -o out/          # output dir (default report-pages/<Report>/)
#   scripts/data/report-png.sh -r "Sales" -w <ws-guid>     # override .env workspace
#
# Output: one PNG per report page (multi-page exports arrive as a zip and are
# extracted), file paths printed to stdout — ready for an AI tool to read the
# images back. Diagnostics go to stderr.
#
# Deployment assumption: this script lives at <client-repo>/scripts/data/
# so SCRIPT_DIR/../.. resolves to the repo root containing .env.

set -euo pipefail

for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found on PATH" >&2
        exit 1
    fi
done

# Resolve repo root (script lives in <repo>/scripts/data/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# Extract values without sourcing (.env may contain entries bash would choke on).
# `|| true` is load-bearing: under `set -o pipefail` a grep that matches nothing
# fails the pipeline, so a missing key would abort the script under `set -e`
# before the explicit check below could print a useful message.
env_value() {
    if [[ ! -f "$ENV_FILE" ]]; then return 0; fi
    { grep -E "^$1=" "$ENV_FILE" || true; } | head -n 1 | cut -d '=' -f 2- | tr -d '\r'
}

# --- Azure CLI login preflight ------------------------------------------------
# `az account get-access-token` fails with a bare "Please run 'az login'" when
# there is no usable session, which is a dead end when the script is driven by a
# tool rather than typed by hand. Probing first turns that into a login prompt.
#
# --allow-no-subscriptions: a Fabric-only tenant has no Azure subscription
# attached, and without the flag `az login` fails with "No subscriptions found"
# before minting anything. The token wanted here is tenant-scoped, so the flag
# costs nothing and keeps subscription-less tenants working.
#
# Escape hatches: SKIP_AZ_LOGIN=1 suppresses the prompt (CI, or when the
# underlying tool's own error is what you want to see). On a headless box with
# no browser, log in once by hand:
#   az login --use-device-code --allow-no-subscriptions --scope <resource>/.default
ensure_az_login() {
    local resource="$1"
    local scope="${resource%/}/.default"

    if ! command -v az >/dev/null 2>&1; then
        echo "error: az not found on PATH" >&2
        echo "hint: winget install Microsoft.AzureCLI" >&2
        exit 1
    fi

    # Probe the exact audience rather than calling `az account show`: under
    # Conditional Access the session can be valid while still unable to mint a
    # token for this resource, and only the former would be caught.
    if az account get-access-token --resource "$resource" -o none 2>/dev/null; then
        return 0
    fi

    if [[ "${SKIP_AZ_LOGIN:-0}" == "1" ]]; then
        echo "warning: no Azure CLI token for $resource, and SKIP_AZ_LOGIN=1" >&2
        return 0
    fi

    # Environment wins over .env so a one-off tenant switch needs no file edit.
    local tenant="${AZURE_TENANT_ID:-}"
    if [[ -z "$tenant" ]]; then
        tenant=$(env_value AZURE_TENANT_ID)
    fi
    local tenant_args=()
    # Only needed for an account that is a guest in several tenants, where an
    # unqualified login lands in the home tenant and mints a rejected token.
    if [[ -n "$tenant" ]]; then
        tenant_args=(--tenant "$tenant")
    fi

    echo "note: no Azure CLI token for $resource — starting interactive login" >&2
    # -o none plus the stderr redirect keep az's subscription dump out of this
    # script's stdout, which callers pipe into other tools.
    if ! az login --allow-no-subscriptions --scope "$scope" \
            ${tenant_args+"${tenant_args[@]}"} -o none >&2; then
        echo "error: az login failed" >&2
        exit 1
    fi
    if ! az account get-access-token --resource "$resource" -o none 2>/dev/null; then
        echo "error: az login succeeded but still no token for $resource" >&2
        exit 1
    fi
}

# The export API lives on the Power BI REST surface, not the Fabric one — the
# audience below is NOT api.fabric.microsoft.com (using that yields a 401).
RESOURCE="https://analysis.windows.net/powerbi/api"
API="https://api.powerbi.com/v1.0/myorg"

WORKSPACE=""
REPORT=""
PAGE=""
FORMAT="PNG"
OUTDIR=""
LIST=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w) WORKSPACE="$2"; shift 2 ;;
        -r) REPORT="$2"; shift 2 ;;
        -p) PAGE="$2"; shift 2 ;;
        -f) FORMAT="$2"; shift 2 ;;
        -o) OUTDIR="$2"; shift 2 ;;
        -l) LIST=1; shift ;;
        # Print the header block: line 2 through the first blank line. A fixed
        # line range silently drifts out of date every time the header is edited.
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "error: unknown argument '$1' (expected -w, -r, -p, -f, -o, -l)" >&2; exit 1 ;;
    esac
done

if [[ -z "$WORKSPACE" ]]; then
    WORKSPACE=$(env_value PBI_WORKSPACE_ID)
fi
if [[ -z "${WORKSPACE:-}" ]]; then
    echo "error: no workspace — set PBI_WORKSPACE_ID in $ENV_FILE or pass -w <guid>" >&2
    exit 1
fi

ensure_az_login "$RESOURCE"
TOKEN=$(az account get-access-token --resource "$RESOURCE" --query accessToken -o tsv)

# Every call funnels through here so HTTP failures surface the API's own error
# payload (which names the real cause: capacity, tenant setting, permissions)
# instead of curl's silence.
pbi_get() {
    local url="$1" out http
    out=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$url")
    http="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$http" != 2* ]]; then
        echo "error: GET $url returned HTTP $http" >&2
        jq -r '.error.message // .message // empty' <<<"$out" >&2 || true
        exit 1
    fi
    printf '%s' "$out"
}

GUID_RE='^[0-9a-fA-F-]{36}$'

BASE_WS="$API/groups/$WORKSPACE"

if [[ "$LIST" -eq 1 ]]; then
    pbi_get "$BASE_WS/reports" | jq -r '.value[] | [.id, .name] | @tsv' | column -t -s $'\t'
    exit 0
fi

if [[ -z "$REPORT" ]]; then
    echo "error: no report — pass -r <name-or-guid> (or -l to list)" >&2
    exit 1
fi

# Resolve a report display name to its GUID; a GUID passes through untouched.
if [[ "$REPORT" =~ $GUID_RE ]]; then
    REPORT_ID="$REPORT"
    REPORT_NAME=$(pbi_get "$BASE_WS/reports/$REPORT_ID" | jq -r '.name')
else
    REPORT_ID=$(pbi_get "$BASE_WS/reports" \
        | jq -r --arg n "$REPORT" '.value[] | select(.name == $n) | .id' | head -n 1)
    if [[ -z "$REPORT_ID" ]]; then
        echo "error: report '$REPORT' not found in workspace $WORKSPACE (try -l)" >&2
        exit 1
    fi
    REPORT_NAME="$REPORT"
fi
BASE="$BASE_WS/reports/$REPORT_ID"

# Body: bare format for the whole report; a single page needs its internal
# ReportSection name inside powerBIReportConfiguration, so accept the display
# name too and translate it.
if [[ -n "$PAGE" ]]; then
    PAGE_NAME=$(pbi_get "$BASE/pages" \
        | jq -r --arg p "$PAGE" '.value[] | select(.name == $p or .displayName == $p) | .name' | head -n 1)
    if [[ -z "$PAGE_NAME" ]]; then
        echo "error: page '$PAGE' not found (names: $(pbi_get "$BASE/pages" | jq -r '[.value[].displayName] | join(", ")'))" >&2
        exit 1
    fi
    BODY=$(jq -n --arg f "$FORMAT" --arg p "$PAGE_NAME" \
        '{format: $f, powerBIReportConfiguration: {pages: [{pageName: $p}]}}')
else
    BODY=$(jq -n --arg f "$FORMAT" '{format: $f}')
fi

echo "note: starting $FORMAT export of '$REPORT_NAME'" >&2
RESPONSE=$(curl -sS -w '\n%{http_code}' -X POST "$BASE/ExportTo" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY")
HTTP="${RESPONSE##*$'\n'}"
RESPONSE="${RESPONSE%$'\n'*}"
if [[ "$HTTP" != 2* ]]; then
    echo "error: ExportTo returned HTTP $HTTP" >&2
    jq -r '.error.message // .message // empty' <<<"$RESPONSE" >&2 || true
    if [[ "$FORMAT" == "PNG" ]]; then
        echo "hint: PNG export needs the tenant setting 'Export reports as image files' (off by default) — try -f PDF" >&2
    fi
    echo "hint: the workspace must be on a Fabric/Premium capacity; PPU is not supported" >&2
    exit 1
fi
EXPORT_ID=$(jq -r '.id' <<<"$RESPONSE")

# The API is async: poll until Succeeded/Failed. percentComplete counts pages,
# so big reports show real progress. ~5 minute ceiling before giving up.
STATUS=""
for _ in $(seq 1 100); do
    STATE=$(pbi_get "$BASE/exports/$EXPORT_ID")
    STATUS=$(jq -r '.status' <<<"$STATE")
    case "$STATUS" in
        Succeeded) break ;;
        Failed)
            echo "error: export failed: $(jq -r '.error.message // "no detail"' <<<"$STATE")" >&2
            if [[ "$FORMAT" == "PNG" ]]; then
                echo "hint: if this is a tenant-setting block, retry with -f PDF" >&2
            fi
            exit 1 ;;
        *) echo "note: $STATUS ($(jq -r '.percentComplete // 0' <<<"$STATE")%)" >&2; sleep 3 ;;
    esac
done
if [[ "$STATUS" != "Succeeded" ]]; then
    echo "error: export still '$STATUS' after timeout" >&2
    exit 1
fi

# resourceFileExtension tells us what /file returns: .zip when a PNG export has
# multiple pages, otherwise .png/.pdf directly.
EXT=$(jq -r '.resourceFileExtension // ".zip"' <<<"$STATE")

if [[ -z "$OUTDIR" ]]; then
    OUTDIR="report-pages/$REPORT_NAME"
fi
mkdir -p "$OUTDIR"

FILE="$OUTDIR/${REPORT_NAME}${EXT}"
curl -sS -H "Authorization: Bearer $TOKEN" "$BASE/exports/$EXPORT_ID/file" -o "$FILE"

if [[ "$EXT" == ".zip" ]]; then
    if command -v unzip >/dev/null 2>&1; then
        unzip -oq "$FILE" -d "$OUTDIR"
    else
        # Git Bash on Windows has no unzip; PowerShell always does.
        powershell.exe -NoProfile -Command \
            "Expand-Archive -LiteralPath '$FILE' -DestinationPath '$OUTDIR' -Force" >&2
    fi
    rm -f "$FILE"
fi

# Zip entries are named after internal ReportSection ids — rename to display
# names so the files are self-describing ("Overview.PNG", not "ReportSectiond0…").
PAGES_JSON=$(pbi_get "$BASE/pages")
while IFS=$'\t' read -r section display; do
    for f in "$OUTDIR/$section".*; do
        [[ -e "$f" ]] || continue
        mv -f "$f" "$OUTDIR/${display}.${f##*.}"
    done
done < <(jq -r '.value[] | [.name, .displayName] | @tsv' <<<"$PAGES_JSON")

# Final stdout payload: the files, one per line, for the caller to open/read.
find "$OUTDIR" -maxdepth 1 -type f | sort
