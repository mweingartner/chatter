# Chatter 3.1.0 — security hardening

- Local HTTP remains on loopback for existing Mac integrations. LAN access is now opt-in HTTPS on a separate port with a verifiable certificate fingerprint. Existing plaintext LAN settings are disabled during migration.
- Named client credentials have permissions, optional voice restrictions, expiration, revocation, and isolated job access. The master credential works only on the local listener.
- Authentication precedes body buffering, with bounded connection pools, request deadlines, client rate limits, and per-client queue limits.
- Indexed SQLite receipts replace per-job JSON storage. Pending payloads, retained history, audio storage, generation time, and audio duration have limits. Exported WAVs are preserved unless automatic export deletion is explicitly enabled.
- Private data and new WAV files use owner-only permissions. Audio downloads stream from a validated file, and imports are size-checked before decoding.
- The inference helper runs with a process policy that blocks networking and restricts file access. Changed model files are rechecked against pinned SHA-256 hashes before loading.
- Production packaging now requires Developer ID signing and successful notarization. Dependency/advisory checks, an SBOM, and security regression tests run in GitHub Actions.

No notarized 3.1.0 binary has been published from this machine: its Developer ID distribution identity and notarization credentials are not configured. The existing 3.0.2 public download predates these changes. Local development builds remain available with explicit `--development` packaging.

## Chatter 3.0.2 — initial public release

Native Swift/MLX Qwen3-TTS speech for Apple Silicon, macOS 26 or later.

- Aiden and Ryan are the only starter voices; custom recordings and profiles are never included.
- Studio WAV output, expressive built-in voices, voice design, recorded-voice conditioning, and multi-actor dialogue.
- Authenticated local/LAN HTTP and MCP, durable FIFO queue, and a portable plugin with Remotion narration handoff.
- All required Swift/native dependency source is vendored in the repository. Runtime helpers and Metal resources are bundled in the app; no Python installation is needed.
- Model setup downloads approximately 15.6 GB with resume and hash verification.

Download the macOS arm64 ZIP, extract it, and move Chatter.app to Applications. Open the app from the menu bar, then choose Speech engine → Download / repair models. Existing libraries are preserved when upgrading.

This release is ad-hoc signed and is NOT Apple-notarized. macOS may require System Settings → Privacy & Security → Open Anyway after the initial launch attempt. Do not disable system-wide security protections. An Intel Mac is not supported.

Verify downloads with `shasum -a 256 -c SHA256SUMS` in the directory containing all listed release files. Chatter original code is MIT; third-party licenses remain in force and are included in the app/source.
