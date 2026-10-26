# Chatter 3.3.1 — recorded voices finish what they say

- Recorded voices no longer stop partway through a reply. At Responsive and Balanced quality, the smaller speech model sometimes never ended a sentence: it kept generating near-silence until it hit its limit, and the job failed with "Generation reached its frame budget", leaving the rest unspoken. JARVIS failed this way on about half of its replies. The usual cause was a recording that ends in a long silence: a voice continues from the end of its recording, so every sentence started inside that silence. Chatter now trims each recording's edges again when it prepares the voice, ignoring clicks and short noise that kept the silence in place. A sentence that still runs on is noticed after 10 seconds instead of 20 and generated again, up to three times, before the job fails. At Responsive quality, where the sentence has already played, Chatter keeps what was said and goes on to the next sentence instead of repeating it.
- At Responsive quality, the sound decoder no longer counts part of its output twice where its 0.8-second chunks join.

# Chatter 3.3.0 — accented voices

- Designing a voice with an accent or dialect now leads to a voice that has it. Qwen voice design can't produce accents, so when a description asks for one (for example "a slight Indian accent", "Scottish dialect" or "Indian English"), Chatter offers two ways to start a recorded voice from a speaker who has it:
  - **From a macOS voice:** pick an installed macOS voice in that accent (the best match for the described gender comes first) and Chatter makes a recorded voice from it in a few seconds. The voice sounds like that macOS speaker. Indian, British, Scottish, Irish, Australian, South African and American English are recognised; add more voices in System Settings › Accessibility › Spoken Content. Apple's license limits macOS voices to personal, non-commercial use, so don't publish or share audio made with such a voice.
  - **From a recording:** record or import 10–30 seconds of a real person with the accent, who agreed to it, for the most natural result.
- Downloaded macOS voices (such as Aman and Tara, and every premium voice) are offered, and the whole reference passage is recorded.
- The offer appears both while designing a voice and in an existing designed voice's settings. "Create designed voice anyway" keeps the old behaviour.

# Chatter 3.2.3 — speech engine robustness fixes from upstream

- The speech engine takes three Qwen3-TTS fixes from upstream MLX-Audio Swift. Codec decoding and the talker's position encoding no longer use an MLX indexing path that hands Metal empty data, which stopped the engine whenever Metal's API validation, a developer setting, was on. Each streamed audio chunk is now finished before the decoder moves on to the next. Generated audio is bit-for-bit the same as in 3.2.2.

# Chatter 3.2.2 — `?wait=` reads decimal seconds only

- `?wait=N` now accepts N only as a decimal number of seconds, such as `5`, `2.5` or `3e1`. Hex values such as `0x1E` are rejected with the usual `wait` message. Before, whether a hex value was accepted depended on the Swift version Chatter was built with.

# Chatter 3.2.1 — designed voices follow their descriptions

- Designed voices now use the VoiceDesign model's published generation settings: the model reads the whole passage before speaking, with temperature 0.9 and no top-p cut. A description such as "a mature adult male" now gives the same kind of voice every time; before, the same description could come out noticeably higher or lower from one sentence to the next.
- Qwen voice design cannot produce accents: a requested accent comes out as standard American English. Chatter now says so when a description mentions an accent, both while you design the voice and as a warning on its jobs, and no longer suggests describing an accent. For an accent, create a recorded voice from a reference recording in that accent; cloning carries it.
- Tone instructions use the right article ("Speak with an optimistic delivery").

# Chatter 3.2.0 — render mode for voice clients

- New `render` mode generates speech silently at the requested quality (Responsive, Balanced or Studio) for a client to download. Nothing plays on the Mac, nothing is exported to the output folder, and the audio is deleted about 10 minutes after it is generated, archived or not. Voice assistants no longer have to use `save`, which always renders at Studio quality.
- `?wait=true` on `POST /v1/speech` and `GET /v1/jobs/{id}` returns the finished receipt in the same request (up to 30 seconds), instead of polling.
- Cancelling a render or save job no longer stops audio playing on the Mac, and starting one no longer interrupts a recording preview or replay. Only `play` jobs control playback.

# Chatter 3.1.1 — clean recorded-voice edges

- Recorded (cloned) voices no longer start every sentence with a sound like a microphone switching on. Qwen continues the reference recording's room tone for a few frames before the first word and after the last; that room tone now becomes silence, with a short fade into the first word and out of the last. Quiet opening consonants such as "f", "s", "th" and "h" are kept. Durations and timing are unchanged; voices that already begin and end in silence, such as the built-in speakers, sound the same.

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
