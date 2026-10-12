<#
.SYNOPSIS
    Predict whether Fabric's Git sync will refuse a warehouse schema change for
    data loss, and print the live statements to run first if it will.

.DESCRIPTION
    Fabric's Git sync deploys a definition 2.0 warehouse with
    BlockOnPossibleDataLoss = true, and no setting to change that was found.
    So a schema change that once synced with a "data will be lost" warning now
    fails the sync outright (observed September 2026; warehouse-checks.md has
    the sources):

        DataLoss: The column [s].[t].[c] is being dropped
        Msg 50000 ... Rows were detected. The schema update is terminating.

    The remedy is to run the destructive half by hand against the live
    warehouse BEFORE syncing, so the generated plan carries no drop and no
    guard. This script tells you whether that is needed and exactly what to
    run, instead of finding out when the portal rejects the sync.

    HOW IT WORKS. It builds the project to a dacpac with warehouse-build.ps1,
    then asks sqlpackage for a DeployReport against the chosen warehouse. A
    DeployReport is a diff, not a deploy: it generates the plan and writes it
    to XML without executing anything. Every operation this script performs is
    read-only, so pointing it at production is safe.

    WHY IT ALSO COUNTS ROWS. DeployReport flags data loss STRUCTURALLY; it
    never looks at the data. A dropped column is reported whether the table
    holds a million rows or none, while the guard the sync actually ran was
    IF EXISTS (SELECT TOP 1 1 FROM [s].[t]), which fires only when rows exist:
    an empty table synced, and dropping a column from one still raised a
    data-loss alert here (September 2026). sqlpackage's own documentation says
    the setting blocks whether or not there is data, so this split rests on
    what the sync was seen to do. Reporting the raw alerts alone would cry
    wolf on every empty table, so each flagged table is counted and the
    finding is split:

        BLOCKING   alert + the table has rows  -> the sync WILL fail
        tolerated  alert + the table is empty  -> the sync will succeed

    An alert whose text this script does not recognize, and a table whose rows
    could not be counted, both count as BLOCKING. Wrong in that direction
    costs a needless check; wrong in the other lets a failing sync through.

    SIGN-IN. sqlpackage signs in as the Azure CLI session, the identity
    sqlcmd uses for the row counts, so no token is ever on a command line.
    That costs about 30 s a report, and needs a sqlpackage that bundles
    Azure.Identity 1.15 or later; an older one ignores the narrowing and falls
    back to the whole credential chain without an error. See
    warehouse-checks.md.

    WHAT IT DOES NOT DO. It never writes to a warehouse. The remediation is
    printed for you to run, deliberately: dropping a column is irreversible
    and nothing else protects that data, so capture what you need first. It
    also cannot see a change that is not in the project. Only what
    the .sqlproj builds is compared; a live object no one has committed is
    invisible here, and DropObjectsNotInSource = false means the deploy
    leaves it alone anyway.

    EXIT STATUS. 0 when the sync will go through, 3 when it will be refused
    (a BLOCKING finding), and 1 when there is no answer: no project, no
    endpoint, no login, a failed build, a sqlpackage error. A failure exits 1
    whatever the failing tool's own code was, so 3 always means a finding.
    The same shape as local-cli's kql.sh: 0 clean, 3 flagged, 1 no result.

    .env: the SQL_ENDPOINT_<NAME> lookup is local-cli's scripts/data/sql.sh's,
    reimplemented here because a PowerShell script cannot shell out to it
    without Git Bash. Each lookup function names the sql.sh code it mirrors,
    and the parity table in warehouse-checks.md maps every rule. Change both
    or neither.

    Deployment assumption: this script lives at
    <client-repo>/scripts/git-sync/ beside warehouse-build.ps1, two levels
    below the repo root, so the .env it reads is the one at the root.

.PARAMETER Project
    The warehouse project: its <Name>.Warehouse folder or the .sqlproj in it.
    Passed to warehouse-build.ps1, which by default takes the one
    *.Warehouse/*.sqlproj that git tracks in this repo.

.PARAMETER Configuration
    Build configuration, passed to warehouse-build.ps1. The dacpac is read
    from bin/<Configuration>/ whether or not -SkipBuild is passed. Debug by
    default.

.PARAMETER Environment
    The environment whose endpoint to read, as sql.sh -E picks it: keys
    prefixed <ENV>_ first, bare keys as fallback. Defaults to the FAB_ENV
    environment variable, then to ENV_DEFAULT in .env; with none of the three
    set, only bare keys are read. Letters and digits only.

.PARAMETER Endpoint
    Which SQL_ENDPOINT_<NAME> entry to compare against, as sql.sh -e picks
    it. Defaults to SQL_ENDPOINT_DEFAULT, then to the only entry when there
    is exactly one.

.PARAMETER Server
    The warehouse's SQL connection string host, skipping .env. Needs
    -Database.

.PARAMETER Database
    The warehouse's name, which is its item display name. With -Server, the
    target; without it, a replacement for the .env entry's database, as
    sql.sh -d is.

.PARAMETER SkipBuild
    Reuse the dacpac already in bin/<Configuration>/ instead of rebuilding.
    Only safe when nothing under the project has changed since the last build.

.PARAMETER ReportPath
    Keep the raw DeployReport XML at this path. Without it the XML goes to a
    temp file and is deleted.

.EXAMPLE
    pwsh -NoProfile -File ./scripts/git-sync/warehouse-deploy-report.ps1 -Environment dev

.EXAMPLE
    pwsh -NoProfile -File ./scripts/git-sync/warehouse-deploy-report.ps1 -Server <host>.datawarehouse.fabric.microsoft.com -Database <WarehouseName>

.EXAMPLE
    pwsh -NoProfile -File ./scripts/git-sync/warehouse-deploy-report.ps1 -Environment dev -ReportPath ./plan.xml
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Configuration = 'Debug',
    [ValidatePattern('^[A-Za-z0-9]+$')]
    [string]$Environment,
    [string]$Endpoint,
    [string]$Server,
    [string]$Database,
    [switch]$SkipBuild,
    [string]$ReportPath
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
function Warn { param($Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Fail { param($Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

#region Pre-flight
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$envFile = Join-Path $repoRoot '.env'
$buildScript = Join-Path $PSScriptRoot 'warehouse-build.ps1'

foreach ($tool in 'sqlpackage', 'az') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Fail "$tool not found on PATH."
        if ($tool -eq 'sqlpackage') { Info 'Install with: dotnet tool install -g microsoft.sqlpackage' }
        if ($tool -eq 'az') { Info 'Install with: winget install Microsoft.AzureCLI' }
        exit 1
    }
}
if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
    Fail "warehouse-build.ps1 not found beside this script, at $buildScript"
    exit 1
}
if ($Server -and -not $Database) {
    Fail '-Server needs -Database, the warehouse name.'
    exit 1
}
#endregion

#region .env lookup, mirroring scripts/data/sql.sh
# Read values without sourcing or parsing anything, as sql.sh does, so a .env
# line this script has no use for can never break it.
$script:EnvLines = @()
if (Test-Path -LiteralPath $envFile -PathType Leaf) {
    $script:EnvLines = @(Get-Content -LiteralPath $envFile)
}

function Get-EnvValue {
    # sql.sh env_value: the first line starting KEY=, all of it after the
    # first '=', with carriage returns dropped. Nothing trimmed or unquoted.
    param([string]$Key)
    foreach ($line in $script:EnvLines) {
        if ($line.StartsWith("$Key=", [System.StringComparison]::Ordinal)) {
            return $line.Substring($Key.Length + 1).Replace("`r", '')
        }
    }
    return ''
}

function Get-ConfigValue {
    # sql.sh cfg_value: <ENV>_<KEY> while an environment is active, then <KEY>.
    param([string]$Key)
    if ($script:EnvName) {
        $scoped = Get-EnvValue "$($script:EnvName)_$Key"
        if ($scoped) { return $scoped }
    }
    return (Get-EnvValue $Key)
}

function Get-EndpointName {
    # sql.sh list_endpoints: the <NAME> of each <prefix>SQL_ENDPOINT_<NAME> key
    # except DEFAULT, one per line it appears on.
    param([string]$Prefix)
    $pattern = '^' + [regex]::Escape($Prefix) + 'SQL_ENDPOINT_([A-Za-z0-9_]+)'
    foreach ($line in $script:EnvLines) {
        if ($line -cmatch $pattern -and $Matches[1] -cne 'DEFAULT') { $Matches[1] }
    }
}

function Split-EndpointValue {
    # sql.sh's two value shapes: an ADO.NET string, detected by its Server=
    # key, or <host>[/<database>]. Returns the server and the database.
    param([string]$Value)
    if ($Value -match '(^|;)\s*Server\s*=') {
        $serverPart = ''
        $databasePart = ''
        if ($Value -match '(?:^|;)\s*Server\s*=([^;]+)') { $serverPart = $Matches[1].TrimStart() }
        if ($Value -match '(?:^|;)\s*(?:Initial Catalog|Database)\s*=([^;]+)') { $databasePart = $Matches[1].TrimStart() }
        return @($serverPart, $databasePart)
    }
    $halves = $Value -split '/', 2
    return @($halves[0], $(if ($halves.Count -gt 1) { $halves[1] } else { '' }))
}

$entry = ''
if ($Server) {
    $targetServer = $Server
    $targetDatabase = $Database
    $script:EnvName = ''
} else {
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        Fail "no .env at $envFile, and no -Server."
        Info 'Pass -Server and -Database, or copy local-cli/.env.sample there and fill in SQL_ENDPOINT_<NAME>.'
        exit 1
    }

    # Environment: -Environment, then FAB_ENV, then ENV_DEFAULT; upper-cased.
    $script:EnvName = $Environment
    if (-not $script:EnvName) { $script:EnvName = [string]$env:FAB_ENV }
    if (-not $script:EnvName) { $script:EnvName = Get-EnvValue 'ENV_DEFAULT' }
    $script:EnvName = $script:EnvName.ToUpperInvariant()

    # Entry: -Endpoint, then SQL_ENDPOINT_DEFAULT, then the only entry, looking
    # among the active environment's entries before the bare ones.
    $entry = $Endpoint
    if (-not $entry) { $entry = Get-ConfigValue 'SQL_ENDPOINT_DEFAULT' }
    if (-not $entry) {
        $names = @(Get-EndpointName $(if ($script:EnvName) { "$($script:EnvName)_" } else { '' }))
        if ($names.Count -eq 0 -and $script:EnvName) { $names = @(Get-EndpointName '') }
        if ($names.Count -eq 1) { $entry = $names[0] }
    }

    $endpointValue = ''
    if ($entry) {
        $endpointValue = Get-ConfigValue "SQL_ENDPOINT_$($entry.ToUpperInvariant())"
        if (-not $endpointValue) { $endpointValue = Get-ConfigValue "SQL_ENDPOINT_$entry" }
    }
    if (-not $endpointValue) {
        # Legacy single-slot key, read bare only, exactly as sql.sh reads it.
        $endpointValue = Get-EnvValue 'SQL_CONNECTION_STRING'
        if ($endpointValue) { Info 'using the legacy SQL_CONNECTION_STRING; sql.sh -l lists named entries.' }
    }
    if (-not $endpointValue) {
        Fail "no endpoint configured in $envFile"
        if ($entry -and $script:EnvName) {
            Info "looked for $($script:EnvName)_SQL_ENDPOINT_$($entry.ToUpperInvariant()), then SQL_ENDPOINT_$($entry.ToUpperInvariant())"
        } elseif ($entry) {
            Info "looked for SQL_ENDPOINT_$($entry.ToUpperInvariant())"
        }
        Info 'expected SQL_ENDPOINT_<NAME>=<host>[/<database>] or an ADO.NET string; pass -Endpoint to pick one.'
        exit 1
    }

    $targetServer, $targetDatabase = Split-EndpointValue $endpointValue
    if ($Database) { $targetDatabase = $Database }
}

if (-not $targetServer) {
    Fail 'could not determine a server from the endpoint value.'
    exit 1
}
if (-not $targetDatabase) {
    # Fabric's copied connection string genuinely omits it.
    Fail "no database for endpoint '$(if ($entry) { $entry } else { '<legacy>' })'"
    Info 'The database is the warehouse ITEM DISPLAY NAME. Append it in .env as'
    Info '<host>/<WarehouseName>, or pass -Database.'
    exit 1
}
#endregion

#region Sign in
# Probe the exact audience rather than calling az account show: under
# Conditional Access a session can be valid while still unable to mint a token
# for this resource. Probing first matters more here than in sql.sh. With no
# session, sqlpackage retried the sign-in for 13 minutes before failing
# (2026-10-01), which looks like a hang.
$resource = 'https://database.windows.net/'
$null = & az account get-access-token --resource $resource -o none 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($env:SKIP_AZ_LOGIN -eq '1') {
        # Unlike sql.sh, which hands on to sqlcmd's own error here: sqlpackage's
        # own error would arrive 13 minutes later.
        Fail "no Azure CLI token for $resource, and SKIP_AZ_LOGIN=1."
        exit 1
    }
    # The environment wins over .env so a one-off tenant switch needs no edit.
    $tenant = [string]$env:AZURE_TENANT_ID
    if (-not $tenant) { $tenant = Get-EnvValue 'AZURE_TENANT_ID' }
    $tenantArgs = @(if ($tenant) { '--tenant', $tenant })
    Info "no Azure CLI token for $resource; starting an interactive login."
    # --allow-no-subscriptions: a Fabric-only tenant has no subscription, and
    # without it az login fails before minting anything.
    $scope = $resource.TrimEnd('/') + '/.default'
    & az login --allow-no-subscriptions --scope $scope @tenantArgs -o none
    if ($LASTEXITCODE -ne 0) {
        Fail 'az login failed.'
        exit 1
    }
    $null = & az account get-access-token --resource $resource -o none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "az login succeeded but still no token for $resource."
        exit 1
    }
}
#endregion

#region Build
$buildArgs = @{ Configuration = $Configuration; Quiet = $true; PassThru = $true; NoBuild = [bool]$SkipBuild }
if ($Project) { $buildArgs['Project'] = $Project }
$buildOutput = @(& $buildScript @buildArgs)
if ($LASTEXITCODE -ne 0) {
    Fail 'no dacpac to compare. Fix the build first.'
    exit 1
}
$dacpac = [string]($buildOutput | Select-Object -Last 1)
if (-not $dacpac -or -not (Test-Path -LiteralPath $dacpac -PathType Leaf)) {
    Fail "warehouse-build.ps1 succeeded but passed back no dacpac path (got '$dacpac')."
    exit 1
}
#endregion

#region Deploy report
Step "Comparing $([System.IO.Path]::GetFileNameWithoutExtension($dacpac)) against $targetDatabase$(if ($script:EnvName) { " ($($script:EnvName))" })"
Info 'sqlpackage takes about a minute.'

# SqlClient's Active Directory Default, narrowed by AZURE_TOKEN_CREDENTIALS to
# the Azure CLI credential, keeps the bearer token off sqlpackage's command
# line, where /AccessToken put it in reach of any process listing. Unnarrowed,
# the chain tries environment, managed identity and Visual Studio credentials
# first, so the identity could change with the machine.
$connectionServer = $targetServer
if ($connectionServer -notmatch '^\w+:' -and $connectionServer -notmatch ',\d+$') {
    $connectionServer = "tcp:$connectionServer,1433"
}
$connection = [System.Data.Common.DbConnectionStringBuilder]::new()
$connection['Server'] = $connectionServer
$connection['Database'] = $targetDatabase
$connection['Authentication'] = 'Active Directory Default'
$connection['Encrypt'] = 'True'

$keepReport = -not [string]::IsNullOrWhiteSpace($ReportPath)
$reportFile = if ($keepReport) {
    # Resolved here: sqlpackage would resolve a relative path against the
    # process's directory, which need not be this session's location.
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) "wh-deployreport-$([guid]::NewGuid()).xml"
}

$priorCredentials = $env:AZURE_TOKEN_CREDENTIALS
try {
    $env:AZURE_TOKEN_CREDENTIALS = 'AzureCliCredential'
    $sqlpackageOutput = & sqlpackage /Action:DeployReport "/SourceFile:$dacpac" `
        "/TargetConnectionString:$($connection.ConnectionString)" `
        "/OutputPath:$reportFile" /p:BlockOnPossibleDataLoss=true 2>&1
    $sqlpackageExit = $LASTEXITCODE

    if ($sqlpackageExit -ne 0 -or -not (Test-Path -LiteralPath $reportFile -PathType Leaf)) {
        $sqlpackageOutput | ForEach-Object { Write-Host ([string]$_) }
        Fail "sqlpackage exited $sqlpackageExit"
        exit 1
    }

    $reportXml = [xml](Get-Content -LiteralPath $reportFile -Raw)
} finally {
    # Runs on the exit above and on a parse error too, either of which would
    # otherwise leave the temp report behind. The XML is in memory from here.
    # Assigning $null deletes the variable when it was unset before.
    $env:AZURE_TOKEN_CREDENTIALS = $priorCredentials
    if (-not $keepReport -and (Test-Path -LiteralPath $reportFile)) {
        Remove-Item -LiteralPath $reportFile
    }
}

# A document of another shape would parse to no alerts and no operations, which
# reads as "no differences". Refuse it instead.
if ($reportXml.DocumentElement.LocalName -ne 'DeploymentReport') {
    Fail "sqlpackage wrote a <$($reportXml.DocumentElement.LocalName)> document, not a DeploymentReport."
    exit 1
}
#endregion

#region Parse alerts
# XPath on local names rather than PowerShell's XML properties: a report with
# no alerts has no <Alerts> element, or an empty one, and reading a missing
# element as a property throws under strict mode, where SelectNodes returns an
# empty list. Local names, because the report declares a default namespace.
$alertsPath = "*[local-name()='DeploymentReport']/*[local-name()='Alerts']/*[local-name()='Alert']"
$operationsPath = "*[local-name()='DeploymentReport']/*[local-name()='Operations']/*[local-name()='Operation']"

# Two alert shapes, and they are not parallel: a drop names the column in
# three-part bracketed form, a type change names it bare and brackets only the
# table. Both texts verified against sqlpackage 170.5.96 in September 2026. A
# bracketed name doubles any ] inside it, so a part is a run of anything else
# or ]]. Kept doubled, a captured part is ready to bracket again in the T-SQL
# below.
$part = '(?:[^\]]|\]\])+'
$dropPattern = 'The column \[(?<schema>' + $part + ')\]\.\[(?<table>' + $part + ')\]\.\[(?<column>' + $part + ')\] is being dropped'
$typePattern = 'The type for column (?<column>\S+) in table \[(?<schema>' + $part + ')\]\.\[(?<table>' + $part + ')\] is currently\s+(?<from>.+?)\s+but is being changed to\s+(?<to>.+?)\.\s'

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($alert in $reportXml.SelectNodes($alertsPath)) {
    foreach ($issue in $alert.SelectNodes("*[local-name()='Issue']")) {
        $text = $issue.GetAttribute('Value')
        if ($text -match $dropPattern) {
            $findings.Add([pscustomobject]@{
                Kind = 'DropColumn'
                Table = "[$($Matches['schema'])].[$($Matches['table'])]"
                Column = $Matches['column']
                Detail = 'column is being dropped'
            })
        } elseif ($text -match $typePattern) {
            $findings.Add([pscustomobject]@{
                Kind = 'ChangeType'
                Table = "[$($Matches['schema'])].[$($Matches['table'])]"
                Column = $Matches['column']
                Detail = "$($Matches['from'].Trim()) -> $($Matches['to'].Trim())"
            })
        } else {
            # Unrecognized text still counts as a finding. Microsoft can reword
            # these, and silently dropping one would turn a reworded alert into
            # a clean report. The alert's name goes with it, since some texts
            # mean nothing alone: a DataMotion alert is just the name of a table
            # the sync will rebuild (2026-10-01).
            $findings.Add([pscustomobject]@{
                Kind = 'Other'
                Table = $null
                Column = $null
                Detail = "$($alert.GetAttribute('Name')): $text"
            })
        }
    }
}

$operations = [System.Collections.Generic.List[object]]::new()
foreach ($operation in $reportXml.SelectNodes($operationsPath)) {
    foreach ($item in $operation.SelectNodes("*[local-name()='Item']")) {
        $operations.Add([pscustomobject]@{
            Name = $operation.GetAttribute('Name')
            Item = $item.GetAttribute('Value')
            Type = $item.GetAttribute('Type')
        })
    }
}
#endregion

#region Report
if ($operations.Count -eq 0 -and $findings.Count -eq 0) {
    Ok "no differences -- the project and $targetDatabase already agree."
    exit 0
}

if ($operations.Count -gt 0) {
    Step 'Changes this sync would make'
    foreach ($operation in $operations) {
        Info ('{0,-7} {1} ({2})' -f $operation.Name, $operation.Item, $operation.Type)
    }
}

if ($findings.Count -eq 0) {
    Write-Host ''
    Ok "no data-loss alerts -- $targetDatabase should accept this sync."
    exit 0
}

# Split flagged tables by whether they actually hold rows. Without this every
# empty table reads as a blocker, which is how a checker stops being trusted.
# Ordinal: under the warehouse's case-sensitive collation, [s].[T] and [s].[t]
# are two tables.
$tables = @($findings | Where-Object { $_.Table } | ForEach-Object { $_.Table } | Select-Object -Unique)
$rowCounts = [System.Collections.Generic.Dictionary[string, long]]::new([System.StringComparer]::Ordinal)
if ($tables.Count -gt 0) {
    if (Get-Command sqlcmd -ErrorAction SilentlyContinue) {
        # COUNT_BIG, because COUNT returns int: one table past 2,147,483,647
        # rows would fail the whole UNION ALL, and every alert would then count
        # as blocking. The name is also a string literal here, so a quote in it
        # is doubled.
        $selects = $tables | ForEach-Object { "SELECT '$($_.Replace("'", "''"))' AS TableName, COUNT_BIG(*) AS Cnt FROM $_" }
        $query = $selects -join ' UNION ALL '
        # sqlcmd reuses the cached az session, so no token is threaded here.
        # -b, because without it sqlcmd exits 0 on a T-SQL error, and a failed
        # count left every row count unknown without the warning below saying
        # why. The query names tables and holds no secret, so -Q is fine.
        $rowOutput = & sqlcmd -S $targetServer -d $targetDatabase --authentication-method ActiveDirectoryAzCli `
            -b -h -1 -W -s '|' -Q $query 2>&1
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $rowOutput) {
                # Anchor on the emitted bracketed name. The trailing "Statement
                # ID: ... | Query hash: ..." line also contains the separator,
                # so a naive split on '|' would parse it as a result row.
                if ([string]$line -match ('^(?<name>\[' + $part + '\]\.\[' + $part + '\])\|(?<rows>\d+)\s*$')) {
                    $rowCounts[$Matches['name']] = [long]$Matches['rows']
                }
            }
        } else {
            $rowOutput | ForEach-Object { Write-Host ([string]$_) }
            Warn 'could not read row counts; treating every alert as blocking.'
        }
    } else {
        Warn 'sqlcmd not found; treating every alert as blocking.'
    }
}

# Unknown row count means blocking. Being wrong in that direction costs a
# needless check; the other direction lets a failing sync through.
$blocking = @($findings | Where-Object { -not $_.Table -or -not $rowCounts.ContainsKey($_.Table) -or $rowCounts[$_.Table] -gt 0 })
$tolerated = @($findings | Where-Object { $_.Table -and $rowCounts.ContainsKey($_.Table) -and $rowCounts[$_.Table] -eq 0 })

if ($tolerated.Count -gt 0) {
    Step 'Data-loss alerts on empty tables (the sync will still succeed)'
    foreach ($finding in $tolerated) {
        Info "$($finding.Table).[$($finding.Column)] -- $($finding.Detail) (0 rows)"
    }
}

if ($blocking.Count -eq 0) {
    Write-Host ''
    Ok "no blocking findings -- every flagged table is empty, so $targetDatabase will accept this sync."
    exit 0
}

Step "BLOCKING: $($blocking.Count) change(s) $targetDatabase will refuse"
foreach ($finding in $blocking) {
    if ($finding.Kind -eq 'Other') {
        Fail $finding.Detail
        continue
    }
    $rows = if ($rowCounts.ContainsKey($finding.Table)) { "$($rowCounts[$finding.Table]) rows" } else { 'row count unknown' }
    Fail "$($finding.Table).[$($finding.Column)] -- $($finding.Detail) ($rows)"
}

Step "Run these against $targetDatabase BEFORE syncing"
Write-Host ''
Write-Host '  -- Capture anything you need from these columns first. Nothing else' -ForegroundColor Yellow
Write-Host '  -- is protecting this data, and none of it is recoverable.' -ForegroundColor Yellow
Write-Host ''

foreach ($finding in @($blocking | Where-Object { $_.Kind -eq 'DropColumn' })) {
    Write-Host "  ALTER TABLE $($finding.Table) DROP COLUMN [$($finding.Column)];" -ForegroundColor Yellow
}

foreach ($finding in @($blocking | Where-Object { $_.Kind -eq 'ChangeType' })) {
    Write-Host ''
    Write-Host "  -- $($finding.Table).[$($finding.Column)]: $($finding.Detail)" -ForegroundColor Yellow
    Write-Host '  -- Fabric Warehouse cannot narrow a column, even in preview, so there is' -ForegroundColor Yellow
    Write-Host '  -- no ALTER for this. Use the CTAS swap: create the table with the new' -ForegroundColor Yellow
    Write-Host '  -- shape, copy the rows, DROP the original, sp_rename the replacement,' -ForegroundColor Yellow
    Write-Host '  -- then re-add constraints and security. The swap destroys time-travel' -ForegroundColor Yellow
    Write-Host '  -- history and GRANT/DENY on the original table.' -ForegroundColor Yellow
}

foreach ($finding in @($blocking | Where-Object { $_.Kind -eq 'Other' })) {
    Write-Host ''
    Write-Host "  -- No automatic remedy for: $($finding.Detail)" -ForegroundColor Yellow
}

# The same endpoint, as whichever tool can reach it: local-cli's sql.sh where
# the endpoint came from .env, plain sqlcmd where it came from -Server.
if ($Server) {
    $runWith = "sqlcmd -S $targetServer -d $targetDatabase --authentication-method ActiveDirectoryAzCli -Q `"...`""
} else {
    $runWith = 'scripts/data/sql.sh'
    if ($script:EnvName) { $runWith += " -E $($script:EnvName)" }
    if ($entry) { $runWith += " -e $entry" }
    if ($Database) { $runWith += " -d $Database" }
    $runWith += ' -Q "..."'
}
Write-Host ''
Info 'Apply the statements live, then commit and sync -- the plan will then carry no drop.'
Info "Run them with: $runWith"
if (-not $Server) { Info '(That is local-cli''s sql.sh, at scripts/data/ where its README installs it.)' }
#endregion

exit 3
