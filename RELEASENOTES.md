# Release Notes

Per-release notes for [fieldcure-whisper-runtimes](https://github.com/fieldcure/fieldcure-whisper-runtimes).
The release workflow extracts the section matching the published tag and uses it as
the GitHub Release body.

Format: one `## <tag>` section per release, newest first. Inside each section the
content is free-form Markdown — keep it consumer-facing (what files, what changed,
known caveats). Build/internal noise belongs in commit messages, not here.

---

## v1.9.0

First populated release. Repackages **Whisper.net 1.9.0** native binaries for FieldCure
consumers (`FieldCure.DocumentParsers.Audio` v0.3+, transitively
`FieldCure.Mcp.Rag` v2.4+).

### Variants (win-x64)

| Variant  | Files | Total size | Notes |
| -------- | ----- | ---------- | ----- |
| `cpu`    | 4     | ~1.6 MB    | CPU-only fallback, always usable. |
| `cuda`   | 5     | ~75 MB     | NVIDIA GPU (CUDA 12.x). `minDriverVersion = 12000` (driver R525+). Requires the host to have a CUDA runtime installed — this release does **not** redistribute `cudart64_*.dll` or `cublas*.dll`. |
| `vulkan` | 5     | ~49 MB     | Cross-vendor GPU via Vulkan. No driver-version policy. |

Per-file SHA-256 hashes and exact byte counts are authoritative in `manifest.json`.

### Asset naming

Release assets are flat per-release on GitHub, so files that share an upstream
filename across variants (e.g. `whisper.dll`) are uploaded with a
`<variant>-<rid>-` prefix:

```
cpu-win-x64-whisper.dll
cuda-win-x64-whisper.dll
vulkan-win-x64-whisper.dll
...
```

Manifest entries keep the **bare** filename in `name`, so consumers cache them
under `runtimes/<variant>/<rid>/whisper.dll` per the v0.3 cache layout.

### Source packages

Repackaged as-is, no recompilation:

- `Whisper.net.Runtime` 1.9.0 → `cpu/win-x64`
- `Whisper.net.Runtime.Cuda.Windows` 1.9.0 → `cuda/win-x64`
- `Whisper.net.Runtime.Vulkan` 1.9.0 → `vulkan/win-x64`

### Consumer compatibility

This release populates the URL pinned by
`GitHubReleasesWhisperRuntimeProvisioner.DefaultManifestUrl` in
`FieldCure.DocumentParsers.Audio` v0.3.x. Existing v0.3 consumer NuGets begin
provisioning successfully on first audio transcription once this release is live;
no consumer-side update required.
