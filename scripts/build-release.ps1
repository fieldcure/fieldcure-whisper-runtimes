<#
.SYNOPSIS
  Repackages Whisper.net.Runtime.* nupkgs (cpu / cuda / vulkan, win-x64) into the
  asset set + manifest.json that this repository publishes via GitHub Releases.

  Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.DESCRIPTION
  Performs no compilation. Pulls the upstream Whisper.net.Runtime nupkgs at the
  pinned version, extracts the win-x64 native binaries, computes SHA-256 hashes
  and byte counts, and emits:

    <Output>/
      manifest.json                              -- to be uploaded as a release asset
      assets/
        cpu-win-x64-<file>.dll                   -- one asset per cpu file
        cuda-win-x64-<file>.dll                  -- one asset per cuda file
        vulkan-win-x64-<file>.dll                -- one asset per vulkan file

  Asset filenames are prefixed by `<variant>-<rid>-` so they remain unique within
  a single GitHub Release. The manifest's `name` field stays the bare upstream
  filename so consumers (`GitHubReleasesWhisperRuntimeProvisioner`) cache them
  correctly under `runtimes/<variant>/<rid>/`.

  After running this script, upload everything in <Output>/assets and the
  manifest.json itself to a GitHub Release tagged v<WhisperNetVersion>:

      gh release create v$WhisperNetVersion `
          (Get-ChildItem $Output\assets) `
          $Output\manifest.json `
          --title "Whisper.net runtime $WhisperNetVersion" `
          --notes-file release-notes.md

.PARAMETER WhisperNetVersion
  Whisper.net.Runtime version to repackage (e.g. "1.9.0").

.PARAMETER Output
  Output directory. Will be created. Existing contents are NOT cleared — pass a
  fresh directory or delete the previous one first.

.PARAMETER ReleaseTag
  GitHub Release tag the manifest URLs should point at. Defaults to
  "v$WhisperNetVersion". Override only when staging a pre-release tag.

.PARAMETER ReleaseRepo
  GitHub `owner/repo` slug used to build asset URLs. Defaults to
  "fieldcure/fieldcure-whisper-runtimes". Override for forks / dry runs.

.PARAMETER NuGetSource
  NuGet feed to restore from. Defaults to nuget.org.

.EXAMPLE
  pwsh ./scripts/build-release.ps1 -WhisperNetVersion 1.9.0 -Output ./out

.NOTES
  Windows runtime packages currently shipped by Whisper.net 1.9.0 do NOT include
  NVIDIA redistributable DLLs (cudart64_*.dll, cublas*.dll). Activation of the
  cuda variant therefore requires the host to have a working CUDA runtime
  installed (driver R525+ for CUDA 12.x). If a future Whisper.net release bundles
  NVIDIA redist binaries, extend the variant block with `nvidiaRedist = $true`
  entries; the manifest schema and the consumer-side provisioner already handle
  that flag.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WhisperNetVersion,

    [Parameter(Mandatory)]
    [string]$Output,

    [string]$ReleaseTag,

    [string]$ReleaseRepo = "fieldcure/fieldcure-whisper-runtimes",

    [string]$NuGetSource = "https://api.nuget.org/v3/index.json"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not $ReleaseTag) {
    $ReleaseTag = "v$WhisperNetVersion"
}

# --- Variant inventory ---------------------------------------------------------
# Single source of truth for which upstream package ships which files for which
# variant on which RID. Keep this aligned with whisper.net's nupkg layout for the
# pinned $WhisperNetVersion. If upstream restructures, edit this table only.
$variants = @(
    [ordered]@{
        Variant         = "cpu"
        PackageId       = "Whisper.net.Runtime"
        Rid             = "win-x64"
        SourceSubpath   = "build/win-x64"
        Files           = @(
            "whisper.dll",
            "ggml-base-whisper.dll",
            "ggml-cpu-whisper.dll",
            "ggml-whisper.dll"
        )
        MinDriverVersion = $null
    },
    [ordered]@{
        Variant         = "cuda"
        PackageId       = "Whisper.net.Runtime.Cuda.Windows"
        Rid             = "win-x64"
        SourceSubpath   = "build/win-x64"
        Files           = @(
            "whisper.dll",
            "ggml-base-whisper.dll",
            "ggml-cpu-whisper.dll",
            "ggml-cuda-whisper.dll",
            "ggml-whisper.dll"
        )
        # Driver R525+ (CUDA 12.0) — encoded in cuDriverGetVersion integer form.
        MinDriverVersion = 12000
    },
    [ordered]@{
        Variant         = "vulkan"
        PackageId       = "Whisper.net.Runtime.Vulkan"
        Rid             = "win-x64"
        SourceSubpath   = "build/win-x64"
        Files           = @(
            "whisper.dll",
            "ggml-base-whisper.dll",
            "ggml-cpu-whisper.dll",
            "ggml-vulkan-whisper.dll",
            "ggml-whisper.dll"
        )
        MinDriverVersion = $null
    }
)

# --- Helpers -------------------------------------------------------------------
function Resolve-NupkgPath {
    param([string]$PackageId, [string]$Version, [string]$RestoreRoot)

    # NuGet lowercases the package id segment of the cache path.
    $idLower = $PackageId.ToLowerInvariant()
    $candidate = Join-Path $RestoreRoot "$idLower/$Version"
    if (-not (Test-Path $candidate)) {
        throw "Restore did not produce $candidate. Did the package id or version change upstream?"
    }
    return $candidate
}

function Restore-WhisperPackages {
    param(
        [string[]]$PackageIds,
        [string]$Version,
        [string]$Source,
        [string]$WorkDir
    )

    $projectDir = Join-Path $WorkDir "_restore"
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

    $references = ($PackageIds | ForEach-Object {
        "    <PackageReference Include=`"$_`" Version=`"$Version`" />"
    }) -join "`n"

    $csproj = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <OutputType>Library</OutputType>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
    <RestorePackagesPath>$WorkDir/packages</RestorePackagesPath>
  </PropertyGroup>
  <ItemGroup>
$references
  </ItemGroup>
</Project>
"@
    Set-Content -Path (Join-Path $projectDir "_restore.csproj") -Value $csproj -Encoding utf8

    Write-Host "[restore] dotnet restore @ $Version (source=$Source)"
    & dotnet restore (Join-Path $projectDir "_restore.csproj") --source $Source | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet restore failed (exit $LASTEXITCODE)"
    }

    return (Join-Path $WorkDir "packages")
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}

# --- Main ----------------------------------------------------------------------
$Output = (New-Item -ItemType Directory -Force -Path $Output).FullName
$assetsDir = New-Item -ItemType Directory -Force -Path (Join-Path $Output "assets")
$workDir = New-Item -ItemType Directory -Force -Path (Join-Path $Output "_work")

Write-Host "Whisper.net version : $WhisperNetVersion"
Write-Host "Release tag         : $ReleaseTag"
Write-Host "Release repo        : $ReleaseRepo"
Write-Host "Output              : $Output"

$packageIds = $variants | ForEach-Object { $_.PackageId } | Sort-Object -Unique
$restoreRoot = Restore-WhisperPackages `
    -PackageIds $packageIds `
    -Version $WhisperNetVersion `
    -Source $NuGetSource `
    -WorkDir $workDir

$manifestVariants = [ordered]@{}

foreach ($v in $variants) {
    $variantName = $v.Variant
    $rid         = $v.Rid
    $packageDir  = Resolve-NupkgPath -PackageId $v.PackageId -Version $WhisperNetVersion -RestoreRoot $restoreRoot
    $sourceRoot  = Join-Path $packageDir $v.SourceSubpath

    if (-not (Test-Path $sourceRoot)) {
        throw "Expected source folder missing: $sourceRoot (package $($v.PackageId) v$WhisperNetVersion)."
    }

    Write-Host ""
    Write-Host "[$variantName/$rid] from $($v.PackageId) -> $sourceRoot"

    $fileEntries = @()
    foreach ($fileName in $v.Files) {
        $sourcePath = Join-Path $sourceRoot $fileName
        if (-not (Test-Path $sourcePath)) {
            throw "Missing expected file '$fileName' in $sourceRoot. Upstream layout may have changed for $WhisperNetVersion."
        }

        # Each release asset must have a unique filename across the whole release.
        $assetName = "$variantName-$rid-$fileName"
        $assetPath = Join-Path $assetsDir $assetName
        Copy-Item -Path $sourcePath -Destination $assetPath -Force

        $sha256 = Get-Sha256Hex -Path $assetPath
        $bytes  = (Get-Item $assetPath).Length
        $url    = "https://github.com/$ReleaseRepo/releases/download/$ReleaseTag/$assetName"

        Write-Host ("  + {0,-30} {1,12:N0} bytes  sha256={2}" -f $fileName, $bytes, $sha256.Substring(0, 12))

        $fileEntries += [ordered]@{
            name   = $fileName
            url    = $url
            sha256 = $sha256
            bytes  = $bytes
        }
    }

    $variantBlock = [ordered]@{}
    if ($null -ne $v.MinDriverVersion) {
        $variantBlock["minDriverVersion"] = $v.MinDriverVersion
    }
    $variantBlock[$rid] = $fileEntries

    $manifestVariants[$variantName] = $variantBlock
}

$manifest = [ordered]@{
    schemaVersion              = 1
    whisperNetRuntimeVersion   = $WhisperNetVersion
    variants                   = $manifestVariants
}

$manifestPath = Join-Path $Output "manifest.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 10
# BOM-free UTF-8: Windows PowerShell 5.1's `Set-Content -Encoding utf8` writes a
# BOM which JsonDocument tolerates but downstream tools (curl/jq) sometimes choke
# on. Use the .NET API directly for portable behavior across 5.1 and 7+.
[System.IO.File]::WriteAllText(
    $manifestPath,
    $manifestJson,
    (New-Object System.Text.UTF8Encoding $false))

Write-Host ""
Write-Host "Wrote manifest: $manifestPath"
Write-Host "Assets staged : $assetsDir"
Write-Host ""
Write-Host "Next step (manual publish):"
Write-Host "  gh release create $ReleaseTag (Get-ChildItem `"$assetsDir`" | % FullName) `"$manifestPath`" ``"
Write-Host "      --title `"Whisper.net runtime $WhisperNetVersion`" ``"
Write-Host "      --notes-file ..\RELEASENOTES.md   # or extract just the matching section"
Write-Host ""
Write-Host "Or push the tag to trigger .github/workflows/release.yml — it extracts the"
Write-Host "matching `"## $ReleaseTag`" section from RELEASENOTES.md automatically."
