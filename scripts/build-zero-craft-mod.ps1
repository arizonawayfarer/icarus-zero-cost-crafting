[CmdletBinding()]
param(
    [string]$GameRoot = "C:\Program Files (x86)\Steam\steamapps\common\Icarus\Icarus",
    [string]$Version = "1.0.2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DataPakPath {
    param(
        [string]$Root
    )

    $candidatePaths = @(
        (Join-Path $Root "Content\Data\data.pak"),
        (Join-Path $Root "Icarus\Content\Data\data.pak")
    )

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Could not find Icarus data.pak under '$Root'."
}

function Get-DataPakNames {
    param(
        [byte[]]$Bytes
    )

    $text = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetString($Bytes)
    $matches = [regex]::Matches($text, "(?:DataTableMetadata|D_[A-Za-z0-9_]+)\.json")
    return @(
        $matches |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -ne "DataTableMetadata.json" }
    )
}

function Read-DataPakBlock {
    param(
        [byte[]]$Bytes,
        [int]$Offset
    )

    $storedSize = [BitConverter]::ToUInt64($Bytes, $Offset + 8)
    $version = [BitConverter]::ToUInt32($Bytes, $Offset + 24)

    if ($version -eq 1) {
        $chunkCount = [BitConverter]::ToUInt32($Bytes, $Offset + 48)
        $headerSize = [BitConverter]::ToUInt32($Bytes, $Offset + 52)
        $output = [System.IO.MemoryStream]::new()
        $chunkStart = $Offset + $headerSize

        for ($i = 0; $i -lt $chunkCount; $i++) {
            $chunkEnd = $Offset + [BitConverter]::ToUInt32($Bytes, $Offset + 60 + ($i * 16))
            $chunkLength = $chunkEnd - $chunkStart
            $chunkBytes = [byte[]]::new($chunkLength)
            [Array]::Copy($Bytes, $chunkStart, $chunkBytes, 0, $chunkLength)

            $input = [System.IO.MemoryStream]::new($chunkBytes)
            $stream = [System.IO.Compression.ZLibStream]::new($input, [System.IO.Compression.CompressionMode]::Decompress)
            try {
                $stream.CopyTo($output)
            }
            finally {
                $stream.Dispose()
                $input.Dispose()
            }

            $chunkStart = $chunkEnd
        }

        try {
            $text = [System.Text.Encoding]::UTF8.GetString($output.ToArray()).TrimStart([char]0)
        }
        finally {
            $output.Dispose()
        }

        return @{
            Size = [int]($headerSize + $storedSize)
            Text = $text
        }
    }

    $headerSize = 0x35
    $text = [System.Text.Encoding]::UTF8.GetString($Bytes, $Offset + $headerSize, [int]$storedSize).TrimStart([char]0)

    return @{
        Size = [int]($headerSize + $storedSize)
        Text = $text
    }
}

function Get-DataPakTables {
    param(
        [string]$DataPakPath,
        [string[]]$Names
    )

    $bytes = [System.IO.File]::ReadAllBytes($DataPakPath)
    $fileNames = Get-DataPakNames -Bytes $bytes
    $nameIndex = @{}

    foreach ($name in $Names) {
        $index = [Array]::IndexOf($fileNames, $name)
        if ($index -lt 0) {
            throw "Could not find '$name' in $DataPakPath."
        }

        $nameIndex[$index] = $name
    }

    $maxIndex = [int](($nameIndex.Keys | Measure-Object -Maximum).Maximum)
    $tables = @{}
    $offset = 0

    for ($fileIndex = 0; $fileIndex -le $maxIndex; $fileIndex++) {
        $block = Read-DataPakBlock -Bytes $bytes -Offset $offset

        if ($nameIndex.ContainsKey($fileIndex)) {
            $tables[$nameIndex[$fileIndex]] = $block.Text
        }

        $offset += $block.Size
    }

    return $tables
}

function New-DefaultsZeroCostOperations {
    $steps = [System.Collections.ArrayList]::new()
    [void]$steps.Add([ordered]@{
        op = "replace"
        path = "/Inputs/0/Count"
        value = 0
    })
    [void]$steps.Add([ordered]@{
        op = "replace"
        path = "/ResourceInputs/0/RequiredUnits"
        value = 0
    })

    $operations = [System.Collections.ArrayList]::new()
    [void]$operations.Add($steps)
    return ,$operations
}

function New-ZeroCostOperationsForRow {
    param(
        [hashtable]$Row
    )

    $steps = [System.Collections.ArrayList]::new()

    if ($Row.ContainsKey("Inputs")) {
        for ($i = 0; $i -lt $Row.Inputs.Count; $i++) {
            [void]$steps.Add([ordered]@{
                op = "replace"
                path = "/Inputs/$i/Count"
                value = 0
            })
        }
    }

    if ($Row.ContainsKey("QueryInputs")) {
        for ($i = 0; $i -lt $Row.QueryInputs.Count; $i++) {
            [void]$steps.Add([ordered]@{
                op = "replace"
                path = "/QueryInputs/$i/Count"
                value = 0
            })
        }
    }

    if ($Row.ContainsKey("ResourceInputs")) {
        for ($i = 0; $i -lt $Row.ResourceInputs.Count; $i++) {
            [void]$steps.Add([ordered]@{
                op = "replace"
                path = "/ResourceInputs/$i/RequiredUnits"
                value = 0
            })
        }
    }

    if ($steps.Count -eq 0) {
        return $null
    }

    $operations = [System.Collections.ArrayList]::new()
    [void]$operations.Add($steps)
    return ,$operations
}

function New-ZeroCostPatch {
    param(
        [string]$Target,
        [object[]]$Rows,
        [bool]$PatchDefaults = $true
    )

    $patches = @()

    if ($PatchDefaults) {
        $patches += @{
            op = "alter"
            row = $null
            patches = New-DefaultsZeroCostOperations
        }
    }

    foreach ($row in $Rows) {
        $operations = New-ZeroCostOperationsForRow -Row $row
        if ($null -eq $operations) {
            continue
        }

        $patches += @{
            op = "alter"
            row = $row.Name
            patches = $operations
        }
    }

    return @{
        schema_version = 1
        type = "DataTable"
        target = $Target
        data = @{
            patches = $patches
        }
    }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$modSourceDir = Join-Path $repoRoot "mod"
$buildRoot = Join-Path $repoRoot "build"
$stageDir = Join-Path $buildRoot "ZeroCraftCosts"
$distDir = Join-Path $repoRoot "dist"
$dataPakPath = Get-DataPakPath -Root $GameRoot

$tableNames = @(
    "D_ExtractorRecipes.json",
    "D_ProcessorRecipes.json"
)

$tables = Get-DataPakTables -DataPakPath $dataPakPath -Names $tableNames
$extractorTable = $tables["D_ExtractorRecipes.json"] | ConvertFrom-Json -AsHashtable
$processorTable = $tables["D_ProcessorRecipes.json"] | ConvertFrom-Json -AsHashtable

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$modInfoPath = Join-Path $modSourceDir "mod.info"
$stageModInfoPath = Join-Path $stageDir "mod.info"
$modInfo = Get-Content -LiteralPath $modInfoPath -Raw | ConvertFrom-Json -AsHashtable
$modInfo["version"] = $Version
$modInfo | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $stageModInfoPath -Encoding utf8

$processorPatch = New-ZeroCostPatch -Target "Crafting/D_ProcessorRecipes.json" -Rows $processorTable.Rows
$extractorPatch = New-ZeroCostPatch -Target "Crafting/D_ExtractorRecipes.json" -Rows $extractorTable.Rows -PatchDefaults $false

$processorPatchPath = Join-Path $stageDir "processor-zero-cost.patch"
$zipPath = Join-Path $distDir "zero-craft-costs-$Version.zip"

$processorPatch | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $processorPatchPath -Encoding utf8
if ($extractorPatch.data.patches.Count -gt 0) {
    $extractorPatchPath = Join-Path $stageDir "extractor-zero-cost.patch"
    $extractorPatch | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $extractorPatchPath -Encoding utf8
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force

Write-Output "Built mod: $zipPath"
Write-Output "Processor recipes patched: $($processorPatch.data.patches.Count)"
Write-Output "Extractor recipes patched: $($extractorPatch.data.patches.Count)"
