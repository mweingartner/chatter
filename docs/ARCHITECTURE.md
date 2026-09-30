# Chatter architecture

## Runtime boundary

Chatter is a native Swift macOS menu-bar application. Its UI, HTTP/MCP server, persistence, and durable FIFO queue remain independent of MLX. A separately supervised `chatter-engine` owns the serialized GPU inference lane, Qwen models, codec, speaker encoder, and bounded conditioning caches. A versioned JSON command/event protocol connects app and helper. GPU/helper failures become job failures and restart recovery rather than terminating the HTTP service.

Accepted requests freeze voice configuration and are persisted before acknowledgment. Speech and an entire multi-actor dialogue each occupy one queue position. Stable request IDs support safe retries; cancellation and explicit capacity errors prevent silent drops. Receipts retain requested controls, warnings, actual model/profile, and audio timing.

## Voices and quality

Recorded voices use Qwen Base: 0.6B 8-bit for Responsive/Balanced and 1.7B BF16 for Studio. Built-in speakers and voice design use their respective 1.7B BF16 models at every quality level. Responsive streams codec chunks; Balanced/Studio buffer passages. Save always forces Studio. The fast model remains resident; other profiles use idle and memory-pressure release, with an optional keep-warm setting.

All enabled recorded takes form one deterministic composite reference, with short silence and exact transcripts. Conditioning is cached by content, transcript, language, and model. A single-take override remains available; references over 180 seconds fail visibly. This is conditioning, not fine-tuning. Recording-health metrics describe the signal, not speaker identity fidelity.

Qwen Base inherits its reference delivery and cannot accept tone instructions. CustomVoice and VoiceDesign support separate natural-language instructions and tone presets. Unsupported explicit instructions fail; legacy non-natural clone tones return a warning. No substitute speaker is silently chosen. Pronunciation mappings affect spoken words while receipts retain the original script. Optional Ollama suggestions never automatically annotate synthesis text.

A fresh library contains exactly two public preset profiles: **Aiden and Ryan**. Existing libraries, deliberately empty libraries, and damaged files are never overwritten by starter data. The wider Qwen capability catalog remains available for users who explicitly add another built-in voice. Custom recordings and personal profiles are not distributed.

## Audio and editor handoff

Audio is native 24 kHz mono with 24-bit PCM WAV export. Pitch-preserving pace is applied once. An 8 ms raised-cosine envelope at each passage edge removes discontinuities without changing duration or reference recordings. Streaming retains 192 tail samples at 24 kHz; internal codec chunk boundaries receive no extra fades. Playback schedules native-rate buffers for continuous output mixing.

Dialogue returns post-pace turn timing. Remotion staging validates count, actor order, non-overlap, and WAV bounds before replacing a manifest. Scene durations derive from PCM sample counts, with integer-frame ceiling for ends. Handoffs preserve applicable Qwen controls and warnings without copying credentials or full engine/reference objects containing host paths. Editors consume staged WAVs without needing Chatter at render time.

## Local data and model installation

Data defaults to `~/Library/Application Support/Chatter`; generated WAVs default to `~/Chatter/Audio`. Directories and bearer-token files use owner-only permissions. The app defaults to authenticated local/LAN access on port 18423; Preferences can disable LAN access. Browser-origin requests are rejected. Transport is HTTP for a trusted LAN; TLS belongs in an explicitly configured private proxy when needed.

The native installer pins every model file by revision, byte size, and SHA-256, supports resumable downloads and repair, and reports failed integrity checks. Models are downloaded during setup, not copied from a developer's cache into the app. Apple supplies system transcription assets. No synthesis audio is sent to a cloud provider.

## Public packaging decision — 2026-09-30

**Outcome:** download one app archive and use it after model setup; clone one repository and compile with an installed Apple toolchain. Include only the Aiden/Ryan starter profiles and no personal voice data.

**Alternatives:** remote SwiftPM packages/submodules would keep the repository smaller but require additional checkouts. Vendoring pinned source costs approximately 130 MB of source but makes the standard dependency graph self-contained. Bundling roughly 15.6 GB of models would complicate release assets and updates; the user selected verified model downloads during setup.

**Decision:** vendor all 12 required Swift packages and populated MLX C/C++ source, preserve upstream manifests and licenses, and use root local-path overrides. Include the official Qwen reference source separately; its optional Python/CUDA training environment is not a runtime dependency. Apple's toolchain/system frameworks and optional editor/Ollama integrations remain external. Chatter original code is MIT; third-party code retains its licenses.

**Probe and acceptance:** resolve and compile from an empty scratch path, confirm all dependencies are local, run the complete tests, then launch the packaged app with isolated data and synthesize both shipped speakers through MCP. Any remote package resolution, missing resource bundle, custom profile in the archive, or helper depending on developer-installed libraries challenges the package.

**Publication:** publish a clean initial source snapshot, preserving earlier personal development history locally. Release source and ZIPs contain no user recordings, profiles, tokens, models, or diagnostic output. The initial binary is ad-hoc signed and unnotarized; trusted Developer ID signing remains a future release prerequisite for standard Gatekeeper acceptance. Revisit packaging if a required dependency changes license, an upstream graph adds dependencies, or signing credentials become available.

## Local-only listener compatibility

Network.framework rejects a fixed port supplied both in `requiredLocalEndpoint` and the explicit `NWListener` port on the tested macOS release. Local-only mode sets the loopback endpoint and constructs the listener without a second port argument. LAN mode retains the wildcard listener on its explicit port. A four-case native probe and packaged-app loopback HTTP/MCP synthesis checks validate the distinction.
