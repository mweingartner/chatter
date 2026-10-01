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

Data defaults to `~/Library/Application Support/Chatter`; generated WAVs default to `~/Chatter/Audio`. Chatter-owned private directories and files use owner-only permissions. HTTP binds to loopback on port 18423. Explicitly enabled LAN access uses a separate TLS listener on port 18424. Legacy plaintext LAN settings migrate to local-only. Browser-origin requests are rejected. See the security decision below.

The native installer pins every model file by revision, byte size, and SHA-256, supports resumable downloads and repair, and reports failed integrity checks. Models are downloaded during setup, not copied from a developer's cache into the app. Apple supplies system transcription assets. No synthesis audio is sent to a cloud provider.

## Public packaging decision — 2026-09-30

**Outcome:** download one app archive and use it after model setup; clone one repository and compile with an installed Apple toolchain. Include only the Aiden/Ryan starter profiles and no personal voice data.

**Alternatives:** remote SwiftPM packages/submodules would keep the repository smaller but require additional checkouts. Vendoring pinned source costs approximately 130 MB of source but makes the standard dependency graph self-contained. Bundling roughly 15.6 GB of models would complicate release assets and updates; the user selected verified model downloads during setup.

**Decision:** vendor all 12 required Swift packages and populated MLX C/C++ source, preserve upstream manifests and licenses, and use root local-path overrides. Include the official Qwen reference source separately; its optional Python/CUDA training environment is not a runtime dependency. Apple's toolchain/system frameworks and optional editor/Ollama integrations remain external. Chatter original code is MIT; third-party code retains its licenses.

**Probe and acceptance:** resolve and compile from an empty scratch path, confirm all dependencies are local, run the complete tests, then launch the packaged app with isolated data and synthesize both shipped speakers through MCP. Any remote package resolution, missing resource bundle, custom profile in the archive, or helper depending on developer-installed libraries challenges the package.

**Publication:** publish a clean initial source snapshot, preserving earlier personal development history locally. Release source and ZIPs contain no user recordings, profiles, tokens, models, or diagnostic output. The initial binary is ad-hoc signed and unnotarized; trusted Developer ID signing remains a future release prerequisite for standard Gatekeeper acceptance. Revisit packaging if a required dependency changes license, an upstream graph adds dependencies, or signing credentials become available.

## Local-only listener compatibility

Network.framework rejects a fixed port supplied both in `requiredLocalEndpoint` and the explicit `NWListener` port on the tested macOS release. Local-only mode sets the loopback endpoint and constructs the listener without a second port argument. LAN mode uses a TLS wildcard listener on its separate explicit port. A four-case native probe and packaged-app loopback HTTP/MCP synthesis checks validate the distinction.

## Security hardening decision — 2026-10-01

**Outcome and acceptance:** existing local plugins continue working; a LAN client must verify the server identity and use its own revocable credential; incomplete unauthenticated connections must not monopolize the service. Accepted work stays durable and ordered, including after migration and restart.

**Alternatives:** an external reverse proxy would provide TLS but add a separate runtime and configuration dependency. Switching the existing port to TLS would break local integrations. Chosen: keep loopback HTTP and add opt-in native TLS on a second port. Security.framework generates/signs a local ECDSA identity; clients pin the SHA-256 certificate fingerprint and validate the certificate's validity. No certificate is silently trusted system-wide. The certificate lasts one year and can be replaced in Connections. Generic HTTPS clients must explicitly trust the certificate and use a matching certificate hostname; the portable bridge supports fingerprint pinning directly. Revisit if public DNS/CA-managed certificates are required.

**Authorization:** the existing owner-only administrator token is accepted only by the loopback listener. Client tokens contain 256 bits of randomness; only hashes are stored. The preferences panel supports 1–365-day expiry, read/speak/cancel permissions, all-voice or single-voice access, and immediate revocation. Jobs and retry keys are scoped by client ID. Revocation cancels that client's active work. An administrator on the Mac can still inspect all jobs. This is personal multi-client access, not OS-user isolation or a defense against malware running as the same user.

**Admission:** local and TLS listeners have separate pools; each allows 32 unauthenticated connections, at most four per source. Oldest unauthenticated connections are evicted to admit fresh attempts. Headers must complete in three seconds; idle connections expire after ten seconds, with a 120-second overall deadline. Authentication precedes body buffering. Authenticated connections are capped at 128 per listener; authenticated API requests are limited to 600 per minute per credential, with 60 new submissions per minute and a configurable per-client queue cap (default 100). No application-layer policy promises resistance to an attack saturating the host/network itself.

**Persistence and resources:** SQLite WAL with full synchronization replaces unbounded arrays of JSON receipts. Legacy receipts migrate individually, preserving IDs and retry keys; a source receipt is removed only after its database insert commits. An exclusive data-directory lock prevents two current app processes from draining the same queue. Indexed lookups resolve archived jobs and retry keys without loading all bodies. New pending payloads share a 64 MB budget, with an 8 MB per-receipt limit. Hydration is byte-bounded and reads the oldest active work first; legacy work can finish even if it exceeds the new pending budget. Default history retention is 30 days / 1,000 finished jobs; active jobs never expire. Exported WAVs are preserved by default. Users may opt into deleting original exported audio when its receipt expires; recordings and copies outside the output directory remain untouched. Already preserved exports whose receipts have expired can be removed manually from the output folder.

The default storage budget is 20 GB, with a 1 GB minimum free-space reserve plus conservative scratch space for the next job. Generated-file counts are capped at 10,000. Job audio defaults to 30 minutes maximum and generation to 60 minutes; both are configurable with hard upper bounds. The engine enforces output frames and the parent enforces wall-clock time. Audio downloads stream in 64 KiB chunks from one validated file descriptor. Limits reject work explicitly; retries using a retained requestID remain idempotent even when the queue is full. Expired receipts no longer guarantee deduplication.

**Privacy and containment:** files are private from creation; private data-directory modes are repaired, and arbitrary chosen output-folder permissions are left unchanged. Imports have a 512 MB staging limit, a pre-decode 180-second reference limit, and a decoded-frame cap. The engine runs under a macOS process policy denying network access and writes outside media/cache/temp directories. The parent stages recordings and publishes exports. This uses the system sandbox-exec facility, not full App Sandbox entitlements; cache/temp and system-service access remain necessary. Revisit isolation when macOS removes that facility or a required service needs broader access. Model launch verification caches inode, size, mtime, ctime and expected hash; any changed model is rehashed against the pinned manifest. This detects changed/corrupt files, not an attacker with write access to both models and the integrity cache.

**Distribution:** production packaging fails without a Developer ID Application identity and notarization profile; a separate explicit development mode creates local artifacts. CI checks vendored hashes, runtime-data exclusions, dependency advisories and tests, and emits a CycloneDX inventory. Signing credentials are external prerequisites; an ad-hoc development signature is never described as notarization.

**Evidence:** unit tests cover identity validation, wrong-pin rejection, migration, owner-scoped retries, expiry/revocation, retained exports, model-cache invalidation and audio bounds. Executed sandbox probes verify blocked credential reads, writes outside permitted directories, and loopback connections, with allowed-operation controls. Policy paths use POSIX realpath because Foundation may normalize /private/var to /var and silently prevent sandbox rules from matching. Packaged-app probes verified authenticated HTTPS and negative controls, cross-client isolation, per-client capacity and a legitimate request surviving 128 incomplete connections. Real Ryan narration and Ryan/Aiden dialogue produced private PCM24 WAVs with byte-identical streamed downloads; Connections and General preferences were reviewed live. Detailed local test artifacts remain outside the public repository.
