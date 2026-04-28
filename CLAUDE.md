# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is (and isn't)

This is a **binaries-only redistribution repo**. Nothing here is compiled — `scripts/build-release.ps1` pulls Whisper.net's upstream `Whisper.net.Runtime.*` NuGet packages, extracts the win-x64 native files, and republishes them as GitHub Release assets with a `manifest.json` inventory. There is no `.csproj`, no test project, no library code.

The README is the canonical document for **what** this repo provides (variants, manifest schema, license stack, consumer lifecycle). This CLAUDE.md covers **how to work in the repo** — release mechanics, single-source-of-truth files, common pitfalls.

## Repository layout

```
fieldcure-whisper-runtimes/
├── README.md                   ← consumer-facing spec (manifest format, license, lifecycle)
├── RELEASENOTES.md             ← per-release changelog. Workflow extracts `## <tag>` section as release body.
├── NOTICE                      ← third-party redistribution notices (Whisper.cpp, NVIDIA, Vulkan loader)
├── LICENSE                     ← MIT for repo content (scripts, schema)
├── scripts/
│   └── build-release.ps1       ← repackager: nupkg → assets/ + manifest.json
└── .github/workflows/
    └── release.yml             ← triggers on `v*` tag push or workflow_dispatch
```

## Release flow

1. Bump the variant inventory in `scripts/build-release.ps1` if upstream `Whisper.net` changed its file layout. Otherwise just call the script with the new version.
2. Add a `## v<X.Y.Z>` section to `RELEASENOTES.md` (newest first). The workflow **fails** if the section is missing.
3. Push tag `v<X.Y.Z>`. The Windows runner restores the upstream nupkgs, repacks, computes SHA-256s, and publishes a GitHub Release. The `## v<X.Y.Z>` section is extracted to a temp file and used as `--notes-file`.
4. Verify: `gh release view v<X.Y.Z>` and `curl -sLI https://github.com/fieldcure/fieldcure-whisper-runtimes/releases/download/v<X.Y.Z>/manifest.json`.

For a **dry run** without publishing, use `workflow_dispatch` with `publish=false`. The job still builds artifacts and uploads them as workflow artifacts (downloadable from the run page) so you can inspect the manifest before tagging.

For a **local rehearsal** (no GitHub interaction):

```powershell
.\scripts\build-release.ps1 -WhisperNetVersion 1.9.0 -Output .\out
```

Outputs land under `.\out\` (`manifest.json` + `assets/` + `_work/` restore cache, all gitignored).

## Variant inventory — single source of truth

The `$variants` table near the top of `scripts/build-release.ps1` declares **which upstream package ships which files for which variant on which RID**, plus driver-version policies (`MinDriverVersion`). All other behavior — asset filenames, manifest URLs, cache layout — is derived. If upstream restructures (file added / removed / renamed for a Whisper.net release), edit this table only.

Asset filenames are namespaced as `<variant>-<rid>-<filename>` because GitHub Release assets are flat per-release and `whisper.dll` appears in all three variants. The manifest's `name` field stays the bare filename so the consumer caches files at `runtimes/<variant>/<rid>/<name>`.

## NVIDIA redist policy

When (and only when) a future Whisper.net version actually bundles NVIDIA CUDA redistributables (`cudart64_*.dll`, `cublas*.dll`, `cublasLt*.dll`) inside its nupkg:

1. Add those filenames to the `cuda` variant's `Files` array in the script.
2. The script must mark them with `nvidiaRedist = $true` in the manifest entry. The current script does **not** emit this field; extend it before adding such files.
3. Update `NOTICE` with the matching CUDA Toolkit EULA Attachment A version.
4. Note in the release-notes `### Migration` block that consumers will see a one-line stderr attribution on first download.

The v1.9.0 release does NOT redistribute NVIDIA binaries — upstream `Whisper.net.Runtime.Cuda.Windows` 1.9.0 doesn't ship them. The consumer expects them resolved from the host's CUDA Toolkit install.

## Manifest schema contract

`schemaVersion = 1` is the only schema understood by the consumer (`FieldCure.DocumentParsers.Audio` v0.3.x — see `WhisperRuntimeManifest.Parse`). Backwards-incompatible changes (renaming a top-level field, changing the variant→rid→files nesting) require:

- Bump `schemaVersion` in this repo's emitter
- Add the new schema parser in the consumer (matching deserializer)
- Ship the consumer change first; only then publish a manifest emitting the new version
- Old releases keep schemaVersion 1; CDN-served `manifest.json` is immutable per release

The schema is documented in detail in README.md (§ "Manifest format"). Changes there must stay in sync with the script's emitter and the consumer's parser.

## PowerShell compatibility

The build script must run on **both Windows PowerShell 5.1 and PowerShell 7+**: 5.1 for ad-hoc local invocation on developer machines that haven't installed pwsh 7, 7+ for the GitHub Actions runner. Specifically:

- No `#requires -Version 7.0` directive.
- Avoid pwsh 7-only operators: `??`, `?.`, `?:` ternary.
- Use `[System.IO.File]::WriteAllText(..., (New-Object System.Text.UTF8Encoding $false))` for BOM-free UTF-8 output. `Set-Content -Encoding utf8` writes a BOM in 5.1.
- Read text files that may contain non-ASCII (RELEASENOTES.md, etc.) with `Get-Content -Encoding utf8` to override 5.1's default ANSI codepage.

## Related repositories

- [`fieldcure/fieldcure-document-parsers`](https://github.com/fieldcure/fieldcure-document-parsers) — `FieldCure.DocumentParsers.Audio`, the primary consumer. The download/verify/activate logic lives in `src/DocumentParsers.Audio/Runtime/`.
- [`fieldcure/fieldcure-mcp-rag`](https://github.com/fieldcure/fieldcure-mcp-rag) — transitive consumer via `FieldCure.DocumentParsers.Audio`.
- [`whisper.net`](https://github.com/sandrohanea/whisper.net) — upstream .NET bindings; source of the nupkgs we repackage.
- [`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) — upstream C++ inference engine; source of the native binaries.
