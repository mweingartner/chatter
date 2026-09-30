# Chatter 3.0.2 — initial public release

Native Swift/MLX Qwen3-TTS speech for Apple Silicon, macOS 26 or later.

- Aiden and Ryan are the only starter voices; custom recordings and profiles are never included.
- Studio WAV output, expressive built-in voices, voice design, recorded-voice conditioning, and multi-actor dialogue.
- Authenticated local/LAN HTTP and MCP, durable FIFO queue, and a portable plugin with Remotion narration handoff.
- All required Swift/native dependency source is vendored in the repository. Runtime helpers and Metal resources are bundled in the app; no Python installation is needed.
- Model setup downloads approximately 15.6 GB with resume and hash verification.

Download the macOS arm64 ZIP, extract it, and move Chatter.app to Applications. Open the app from the menu bar, then choose Speech engine → Download / repair models. Existing libraries are preserved when upgrading.

This release is ad-hoc signed and is NOT Apple-notarized. macOS may require System Settings → Privacy & Security → Open Anyway after the initial launch attempt. Do not disable system-wide security protections. An Intel Mac is not supported.

Verify downloads with `shasum -a 256 -c SHA256SUMS` in the directory containing all listed release files. Chatter original code is MIT; third-party licenses remain in force and are included in the app/source.
