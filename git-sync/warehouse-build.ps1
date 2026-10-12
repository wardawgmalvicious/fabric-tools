<#
.SYNOPSIS
    Build a Fabric Warehouse's SQL project and fail on the DacFx errors that
    would fail its Git sync.

.DESCRIPTION
    Fabric runs a DacFx build of the warehouse's SQL project on commit from
    the workspace, update from Git, branch-out and new workspace from repo.
    That build validates references the engine itself never checks, so T-SQL
    that runs fine over sqlcmd can still fail the sync. Running the same
    build locally moves that failure from "the sync was rejected some time
    later" to "the commit did not go through".

    WHAT THIS CATCHES. Everything DacFx resolves at build time from the
    project model alone: an unresolved reference (SQL71501) left behind when
    a column is dropped from a table but a proc or view still names it, an
    uppercase built-in type such as SYSNAME, which fails a whole branch-out
    under the case-sensitive model collation, a three-part reference to the
    warehouse's own object, and a cyclic reference between warehouse items.

    WHAT THIS CANNOT CATCH, and why warehouse-deploy-report.ps1 sits beside
    it. The build compiles the project into a dacpac in isolation. It holds
    no connection to any warehouse, so it cannot know whether a column being
    dropped or narrowed holds data. Fabric's sync deploys a definition 2.0
    warehouse with BlockOnPossibleDataLoss = true, so a data-losing change is
    exactly the case that builds green here and is then refused at sync:
    narrowing a column to VARCHAR(50) built with 0 errors and was rejected by
    the deploy (September 2026). Run warehouse-deploy-report.ps1 before
    pushing any schema change.

    THE .sqlproj IS THE PORTAL'S, EXCEPT ITS SDK VERSION. The portal rewrites
    it on every commit from the workspace, so "A newer version of
    Microsoft.Build.Sql is available" is expected and not a finding. The SDK
    version is the one hand edit Microsoft documents: a stale one fails
    commits, updates and branch-outs alike, and fails this build with MSB4019.

    0 ERRORS MEANS GREEN ONLY FOR A FOLDER OF ITEM DEFINITIONS. Ad-hoc .sql
    files left in the *.Warehouse folder are built too, and raise SQL71006 and
    SQL70001 errors that Fabric's own build leaves out. Move them elsewhere.

    EXIT STATUS. 0 when the project builds and its dacpac exists, and 1 when
    it does not or the build could not run. There is no separate code for
    "the project has errors": dotnet's exit status does not tell a project
    error from a failed package restore, so this script cannot either.

    Deployment assumption: this script lives at
    <client-repo>/scripts/git-sync/, two levels below the repo root, like
    local-cli's scripts/data/.

.PARAMETER Project
    The warehouse to build: its <Name>.Warehouse folder or the .sqlproj in it.
    By default, the one *.Warehouse/*.sqlproj that git tracks in this repo.
    With more than one, the script lists them and stops.

.PARAMETER Configuration
    Build configuration passed to dotnet. Debug by default, which is where the
    portal-owned .gitignore already expects bin/ and obj/ to land.

.PARAMETER Quiet
    Print one status line instead of dotnet's own output when the build
    succeeds. For a pre-commit hook, where a clean build should say almost
    nothing. A failing build always prints in full.

.PARAMETER NoBuild
    Build nothing; find the dacpac an earlier build left in
    bin/<Configuration>/. warehouse-deploy-report.ps1 -SkipBuild uses it.

.PARAMETER PassThru
    Write the dacpac's full path to the pipeline on success.
    warehouse-deploy-report.ps1 reads it from there.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/git-sync/warehouse-build.ps1

.EXAMPLE
    pwsh -NoProfile -File ./scripts/git-sync/warehouse-build.ps1 -Project ./<WarehouseName>.Warehouse -Quiet
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Configuration = 'Debug',
    [switch]$Quiet,
    [switch]$NoBuild,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Native commands report failure only through $LASTEXITCODE, which is checked
# after each one. A caller's session that opted into throwing on a non-zero
# exit would otherwise turn those checks into an unexplained exception.
$PSNativeCommandUseErrorActionPreference = $false

function Step { param($Message) Write-Host "`n=== $Message" -ForegroundColor Cyan }
function Ok   { param($Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Info { param($Message) Write-Host "  [info] $Message" -ForegroundColor Gray }
function Fail { param($Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

#region Resolve the project
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Resolve-ProjectFile {
    <#
    .SYNOPSIS
        Return the full path of the .sqlproj to build, or exit 1 saying why
        there is not exactly one.
    #>
    param([string]$Path)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) {
            Fail "-Project not found: $Path"
            exit 1
        }
        $item = Get-Item -LiteralPath $Path
        if ($item.PSIsContainer) {
            $inFolder = @(Get-ChildItem -LiteralPath $item.FullName -Filter '*.sqlproj' -File)
            if ($inFolder.Count -eq 1) { return $inFolder[0].FullName }
            Fail "expected one .sqlproj in $($item.FullName), found $($inFolder.Count)"
            exit 1
        }
        if ($item.Extension -ne '.sqlproj') {
            Fail "-Project takes a .Warehouse folder or a .sqlproj, not $($item.FullName)"
            exit 1
        }
        return $item.FullName
    }

    # Tracked files only. A recursive search would also find the copy in every
    # worktree or scratch checkout under the repo, and call each a second
    # project.
    $tracked = @(& git -C $repoRoot -c core.quotePath=false ls-files -- '*.sqlproj')
    if ($LASTEXITCODE -ne 0) {
        Fail "git could not list the files under $repoRoot. Pass -Project."
        exit 1
    }
    $warehouses = @($tracked | Where-Object { $_ -match '(^|/)[^/]+\.Warehouse/[^/]+\.sqlproj$' })
    if ($warehouses.Count -eq 1) { return (Join-Path $repoRoot $warehouses[0]) }
    if ($warehouses.Count -eq 0) {
        Fail "git tracks no *.Warehouse/*.sqlproj under $repoRoot. Pass -Project."
        exit 1
    }
    Fail "git tracks $($warehouses.Count) warehouse projects. Pass -Project with one of:"
    $warehouses | ForEach-Object { Info $_ }
    exit 1
}

function Find-Dacpac {
    <#
    .SYNOPSIS
        Return the dacpac a build of the project left in bin/<Configuration>/,
        or $null when there is none.
    .DESCRIPTION
        By name, because it is never the only one there: the FabricDw package
        reference copies master.dacpac beside it on every build. The name is
        the .sqlproj file's, whatever its <Name> says. Both measured
        2026-10-12.
    #>
    param([string]$SqlProjPath)

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($SqlProjPath) + '.dacpac'
    $dacpacPath = Join-Path (Split-Path -Parent $SqlProjPath) "bin/$Configuration/$fileName"
    if (Test-Path -LiteralPath $dacpacPath -PathType Leaf) { return $dacpacPath }
    return $null
}

$projectFile = Resolve-ProjectFile $Project
$projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile)
#endregion

#region Build
if ($NoBuild) {
    $dacpac = Find-Dacpac $projectFile
    if (-not $dacpac) {
        Fail "no dacpac for $projectName in bin/$Configuration. Build it first."
        exit 1
    }
    Ok "existing dacpac -- $dacpac"
    if ($PassThru) { Write-Output $dacpac }
    exit 0
}

if (-not (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail 'dotnet not found on PATH.'
    Info 'Install the .NET SDK; the Microsoft.Build.Sql SDK restores from NuGet on first build.'
    exit 1
}

if (-not $Quiet) { Step "Building $projectName ($Configuration)" }

# dotnet reports failure only through its exit code; try/catch and
# $ErrorActionPreference never see it. Without this check a failed build
# reports success and the commit proceeds.
$rawOutput = & dotnet build $projectFile --configuration $Configuration --nologo 2>&1
$buildExit = $LASTEXITCODE
$output = @($rawOutput | ForEach-Object { [string]$_ })

if ($buildExit -ne 0) {
    # Always in full on failure, even under -Quiet: the SQL71501 line is the
    # whole value of running this, and a hook that swallowed it would be an
    # unexplained refusal to commit.
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Fail "dotnet build exited $buildExit"

    # Any run of letters before the digits: SQL71501 and MSB4019, the two codes
    # the hints below are for, have three. Distinct lines, because MSBuild
    # prints each error twice, as it happens and again in its summary (both
    # measured 2026-10-01).
    $errorLines = @($output | Where-Object { $_ -match '\berror [A-Z]+\d+:' } | Sort-Object -Unique)
    if ($errorLines.Count -gt 0) {
        Info "$($errorLines.Count) build error(s). Fabric's build fails on these too; fix them before committing."
    }
    $unresolved = @($errorLines | Where-Object { $_ -match 'SQL71501' })
    if (@($unresolved | Where-Object { $_ -notmatch 'Built-in Type' }).Count -gt 0) {
        Info 'SQL71501 is an unresolved reference: an object still names something the project no longer defines.'
        Info 'Dropping a column means editing every proc and view that reads it, in the same commit.'
    }
    if (@($unresolved | Where-Object { $_ -match 'Built-in Type' }).Count -gt 0) {
        # SYSNAME, measured 2026-10-12. INT and VARCHAR are keywords and build
        # in any case; sysname is a type looked up by name.
        Info 'An unresolved Built-in Type is a type name in the wrong case. The model collation is'
        Info 'case-sensitive and sysname is looked up by name, so write sysname, not SYSNAME.'
    }
    $allOutput = $output -join "`n"
    if ($allOutput -match 'MSB4019|NuGet\.Build\.Tasks\.Pack') {
        Info 'MSB4019 usually means a stale Microsoft.Build.Sql SDK version in the .sqlproj.'
        Info 'Raise the <Sdk> Version to a current Microsoft.Build.Sql and commit the edit.'
    }
    exit 1
}

if (-not $Quiet) {
    $output | ForEach-Object { Write-Host $_ }
}

$dacpac = Find-Dacpac $projectFile
if (-not $dacpac) {
    # A zero exit with no artifact is not a success worth reporting as one.
    Fail "dotnet build exited 0 but left no dacpac for $projectName in bin/$Configuration"
    exit 1
}
Ok "build succeeded -- $dacpac"

if (-not $Quiet) {
    Info 'A green build does NOT mean the sync will succeed.'
    Info 'Before pushing a schema change, run: scripts/git-sync/warehouse-deploy-report.ps1'
}
#endregion

if ($PassThru) { Write-Output $dacpac }
exit 0
