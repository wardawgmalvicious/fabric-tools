#Requires -Version 7.0
<#
.SYNOPSIS
Strips Fabric-injected metadata from a Jupyter notebook.

.DESCRIPTION
Rewrites a .ipynb in place so only language-related metadata survives.
Removes notebook-level dependencies (bound lakehouse/warehouse/environment),
a365ComputeOptions, sessionKeepAliveTimeout, nteract, and spark_compute
(which carries compute_id / session_options). At the cell level, resets
outputs and execution_count, drops every per-cell metadata key except the
ones on the allowlist, and normalizes `source` to the array-of-strings form
Fabric's notebook importer requires.

Idempotent - running twice on the same file is a no-op.

.PARAMETER Paths
One or more notebook paths to scrub.

.EXAMPLE
pwsh -File .githooks/scrub-fabric-notebook.ps1 integration/nb_salesforce_ingest.ipynb
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
  [string[]]$Paths
)

$ErrorActionPreference = 'Stop'

# Notebook-level metadata keys to keep. Fabric's import uses `microsoft.language`
# to pick the cell language, so we retain it.
$AllowedTopLevelMeta = @('language_info', 'kernel_info', 'microsoft')

# Per-cell metadata keys to keep. `microsoft` holds the cell-language tag that
# Fabric needs to route %%sql / %%pyspark correctly.
$AllowedCellMeta = @('microsoft')

function ConvertTo-OrderedMetadata {
  param($Source, [string[]]$Allowed)
  $out = [ordered]@{}
  if ($null -eq $Source) { return $out }
  foreach ($k in $Allowed) {
    if ($Source.Contains($k)) { $out[$k] = $Source[$k] }
  }
  return $out
}

function ConvertTo-SourceLines {
  <#
    Normalizes a cell's `source` to array-of-strings form. Jupyter accepts a
    bare string, but Fabric's uploadNotebook / createArtifact rejects it with
    `400 Bad Request` + `pbi.error.exceptionCulprit: 1` and no further detail.
    Cells authored programmatically (rather than round-tripped through Fabric)
    are the usual source of the bare-string form.

    Splits after each newline and keeps it, so joining the result reproduces
    the input exactly - the text is never altered, only re-shaped. Already
    normalized arrays round-trip unchanged, keeping the scrubber idempotent.

    Every `return` uses the comma operator - without it PowerShell unrolls a
    single-element array to a scalar and an empty one to $null, which would
    re-emit exactly the bare-string (or null) source we are here to prevent.
  #>
  param($Source)

  if ($null -eq $Source) { return , @() }
  $text = if ($Source -is [string]) { $Source } else { -join $Source }
  if ($text.Length -eq 0) { return , @() }

  $lines = [regex]::Matches($text, '[^\n]*\n|[^\n]+') | ForEach-Object { $_.Value }
  return , @($lines)
}

function ConvertTo-ScrubbedCell {
  param($Cell)
  $type = $Cell['cell_type']
  $cellMeta = ConvertTo-OrderedMetadata -Source $Cell['metadata'] -Allowed $AllowedCellMeta

  # Match existing Jupyter/Fabric key ordering so diffs stay minimal.
  $out = [ordered]@{}
  $out['cell_type'] = $type
  if ($type -eq 'code') { $out['execution_count'] = $null }
  if ($Cell.Contains('id')) { $out['id'] = $Cell['id'] }
  $out['metadata'] = $cellMeta
  if ($type -eq 'code') { $out['outputs'] = @() }
  $out['source'] = ConvertTo-SourceLines -Source $Cell['source']
  return $out
}

$changedAny = $false

foreach ($p in $Paths) {
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Error "Notebook not found: $p"
    exit 1
  }

  $absolute = (Resolve-Path -LiteralPath $p).Path
  $original = Get-Content -LiteralPath $absolute -Raw
  $nb = $original | ConvertFrom-Json -AsHashtable -Depth 100

  $scrubbed = [ordered]@{}
  $scrubbed['cells'] = @($nb['cells'] | ForEach-Object { ConvertTo-ScrubbedCell -Cell $_ })
  $scrubbed['metadata'] = ConvertTo-OrderedMetadata -Source $nb['metadata'] -Allowed $AllowedTopLevelMeta
  if ($nb.Contains('nbformat')) { $scrubbed['nbformat'] = $nb['nbformat'] }
  if ($nb.Contains('nbformat_minor')) { $scrubbed['nbformat_minor'] = $nb['nbformat_minor'] }

  $rewritten = ($scrubbed | ConvertTo-Json -Depth 100) + "`n"

  if ($rewritten -ne $original) {
    [System.IO.File]::WriteAllText(
      $absolute,
      $rewritten,
      [System.Text.UTF8Encoding]::new($false)
    )
    Write-Output "scrubbed: $p"
    $changedAny = $true
  }
}

if (-not $changedAny) { Write-Output "clean: no changes needed" }
