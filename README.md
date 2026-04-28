# fieldcure-whisper-runtimes

Pre-built Whisper.net native runtime binaries for FieldCure's audio transcription pipeline.

## What this is

This repository hosts pre-packaged native binaries for [Whisper.net](https://github.com/sandrohanea/whisper.net) — the inference engine used by [`FieldCure.DocumentParsers.Audio`](https://github.com/fieldcure/fieldcure-document-parsers) for audio-to-text transcription.

Binaries are organized into three runtime variants:

| Variant  | Platform | Purpose                                            |
|----------|----------|----------------------------------------------------|
| `cpu`    | win-x64  | CPU-only fallback (no GPU required)                |
| `cuda`   | win-x64  | NVIDIA GPU acceleration (CUDA 12.x)                |
| `vulkan` | win-x64  | Cross-vendor GPU acceleration via Vulkan           |

A `manifest.json` per release describes each variant's file set, sizes, and SHA-256 hashes.

## Why this exists

`FieldCure.DocumentParsers.Audio` v0.3 onwards downloads GPU runtime binaries on demand rather than bundling them in the NuGet package. Two reasons:

1. **NuGet package size cap.** nuget.org enforces a 250 MB limit per package. Whisper's CUDA + Vulkan native runtimes alone exceed 120 MB; bundling them would prevent shipping downstream consumers like `FieldCure.Mcp.Rag` (a `dotnet tool` that also depends on cross-platform Sqlite ~127 MB) under the cap.
2. **Pay-for-what-you-use.** Most installations run on CPU only, or on a single GPU vendor. Runtime download means each host fetches only the variant it can actually use.

This repo is the canonical source those consumers fetch from.

## Repository structure

```
fieldcure-whisper-runtimes/
├── README.md                    (this file)
├── LICENSE                      (MIT, applies to repo content/scripts)
├── NOTICE                       (third-party redistribution notices)
├── manifest-schema.json         (JSON Schema for manifest.json — optional)
├── scripts/
│   └── build-release.ps1        (extracts and packages Whisper.net.Runtime.* nupkgs)
└── .github/workflows/
    └── release.yml              (runs build-release.ps1, publishes a Release)
```

Actual binaries live under [GitHub Releases](https://github.com/fieldcure/fieldcure-whisper-runtimes/releases), one release per Whisper.net version.

## Manifest format

Each release contains a `manifest.json`:

```json
{
  "schemaVersion": 1,
  "whisperNetRuntimeVersion": "1.9.0",
  "variants": {
    "cpu": {
      "win-x64": [
        { "name": "whisper.dll",          "url": "...", "sha256": "...", "bytes": 0 },
        { "name": "ggml-base-whisper.dll","url": "...", "sha256": "...", "bytes": 0 },
        { "name": "ggml-cpu-whisper.dll", "url": "...", "sha256": "...", "bytes": 0 },
        { "name": "ggml-whisper.dll",     "url": "...", "sha256": "...", "bytes": 0 }
      ]
    },
    "cuda": {
      "minDriverVersion": 12000,
      "win-x64": [
        { "name": "whisper.dll",           "url": "...", "sha256": "...", "bytes": 0 },
        { "name": "ggml-cuda-whisper.dll", "url": "...", "sha256": "...", "bytes": 0 },
        { "name": "cudart64_12.dll",       "url": "...", "sha256": "...", "bytes": 0, "nvidiaRedist": true },
        { "name": "cublas64_12.dll",       "url": "...", "sha256": "...", "bytes": 0, "nvidiaRedist": true },
        { "name": "cublasLt64_12.dll",     "url": "...", "sha256": "...", "bytes": 0, "nvidiaRedist": true }
      ]
    },
    "vulkan": {
      "win-x64": [
        { "name": "whisper.dll",             "url": "...", "sha256": "...", "bytes": 0 },
        { "name": "ggml-vulkan-whisper.dll", "url": "...", "sha256": "...", "bytes": 0 }
      ]
    }
  }
}
```

Field semantics:

- **`schemaVersion`** — manifest schema version. Bumped only when fields change in a backwards-incompatible way.
- **`whisperNetRuntimeVersion`** — the Whisper.net version this manifest's binaries were built against. Consumers should verify their Whisper.net dependency matches.
- **`variants.<flavor>.<rid>`** — array of files needed for that variant on that runtime ID.
- **`variants.cuda.minDriverVersion`** — minimum NVIDIA driver version in CUDA integer format (e.g. `12000` = CUDA 12.0, requiring driver R525+). Consumers should gate `cuda` activation on detected driver version ≥ this value.
- **`nvidiaRedist: true`** — flags files redistributed under [NVIDIA CUDA Toolkit EULA Attachment A](https://docs.nvidia.com/cuda/eula/). Consumers must preserve license notices when distributing or logging these files (a stderr line on first download is the recommended pattern).

## Versioning

Release tags track the Whisper.net version they were built against:

- `v1.9.0` → built against `Whisper.net.Runtime` 1.9.0
- `v1.10.0` → built against `Whisper.net.Runtime` 1.10.0 (when released)

A patch update to Whisper.net (e.g. 1.9.1) typically reuses the same native binaries; a new manifest tag is cut only if the binaries actually change.

## How consumers use this

`FieldCure.DocumentParsers.Audio` v0.3+ implements the consumer side. The lifecycle:

1. **Detect** — inspect host environment (CUDA/Vulkan driver presence, RAM, cores).
2. **Select** — pick the best available variant given driver presence and `minDriverVersion` from the manifest.
3. **Provision** — if the variant's binaries are not already cached at `%LOCALAPPDATA%\FieldCure\WhisperRuntimes\`, download them from this repo's Releases. Hashes verified against `manifest.json` before files commit to the cache.
4. **Activate** — set `Whisper.net`'s `RuntimeOptions.LibraryPath` to the cache directory and proceed with transcription.

Consumer-side details (cache layout, atomic writes, concurrency, environment overrides) are documented in the [`FieldCure.DocumentParsers.Audio`](https://github.com/fieldcure/fieldcure-document-parsers) README.

## Air-gapped / offline use

Set `FIELDCURE_WHISPER_RUNTIME_DIR` to a pre-staged directory containing the manifest and binaries (same layout as the online cache). The consumer skips all network calls and treats the directory as authoritative.

```
FIELDCURE_WHISPER_RUNTIME_DIR=D:\offline\whisper-runtimes
└── runtimes\
    ├── win-x64\         (cpu)
    ├── cuda\win-x64\
    └── vulkan\win-x64\
```

The manifest must also be present at `<override>\manifest.json` for hash verification.

## Building from source

The native binaries hosted here come directly from the upstream `Whisper.net.Runtime.*` NuGet packages — **repackaged, not rebuilt**. The `scripts/build-release.ps1` script:

1. Restores `Whisper.net.Runtime`, `Whisper.net.Runtime.Cuda`, `Whisper.net.Runtime.Vulkan` at the target version.
2. Extracts win-x64 native files from each.
3. Computes SHA-256 hashes.
4. Generates `manifest.json`.
5. Stages files for Release upload.

To build locally (for verification):

```powershell
pwsh ./scripts/build-release.ps1 -WhisperNetVersion 1.9.0 -Output ./out
```

The actual GitHub Release is created via the `.github/workflows/release.yml` workflow when a maintainer pushes a version tag.

## License

This repository's own content (scripts, manifest format, README) is licensed under [MIT](LICENSE).

The hosted native binaries are redistributed from upstream sources under their respective licenses:

- **Whisper.net** native binaries — [MIT](https://github.com/sandrohanea/whisper.net/blob/main/LICENSE.md)
- **whisper.cpp / ggml** binaries — [MIT](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE)
- **NVIDIA CUDA Toolkit redistributables** (`cudart64_*.dll`, `cublas*.dll`, `cublasLt*.dll`) — redistributed under [NVIDIA CUDA Toolkit EULA Attachment A](https://docs.nvidia.com/cuda/eula/). Original NVIDIA license terms apply; see [NOTICE](NOTICE).
- **Vulkan loader** — [Apache-2.0 / MIT](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/LICENSE.txt)

See [NOTICE](NOTICE) for full attributions and required redistribution notices.

## Related projects

- [`fieldcure-document-parsers`](https://github.com/fieldcure/fieldcure-document-parsers) — `FieldCure.DocumentParsers.Audio`, the primary consumer.
- [`fieldcure-mcp-rag`](https://github.com/fieldcure/fieldcure-mcp-rag) — consumes Audio for KB indexing of audio files.
- [`fieldcure-assiststudio`](https://github.com/fieldcure/fieldcure-assiststudio) — WinUI 3 chat application; for v1.0 onwards, consumes audio via provider-native paths (Gemini 1.5+, gpt-4o-audio) rather than transcription.
- [`whisper.net`](https://github.com/sandrohanea/whisper.net) — upstream .NET bindings for whisper.cpp.

---

Maintained by [FieldCure Co., Ltd.](https://github.com/fieldcure)

