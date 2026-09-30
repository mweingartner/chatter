# Pinned dependency source

The root Swift package uses local paths for all 12 required packages in `Packages`. MLX's C++ and C submodules are already populated as ordinary source directories. No recursive clone or Git LFS download is needed.

`dependencies.json` records URLs, revisions, versions, and reference-only code. `Upstream-Package.resolved` preserves the original remote lock. Source/manifests are unmodified except removal of repository metadata, build caches, and Finder metadata. Upstream optional tooling/tests may list additional remote packages; those are outside Chatter's standard macOS build graph.

`Qwen3-TTS` is the official Apache-2.0 algorithm/training reference, not a Python runtime used by the app. Its dependencies are only needed if you separately choose to run its Python/CUDA tools.

`SHA256SUMS` records regular source files and `symlinks.json` records symlink targets. Paths are relative to the repository root. Update these when intentionally changing a snapshot. Preserve upstream license and attribution notices.
