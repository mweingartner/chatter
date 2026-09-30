# Chatter

A native macOS speech studio and always-available HTTP/MCP service, powered by **Qwen3-TTS on Apple Silicon**. Speak in a saved voice, create a multi-actor conversation, or export studio WAV narration for a video. Speech generation runs locally, in Swift and MLX, without Python.

[Download Chatter](https://github.com/mweingartner/chatter/releases/latest) · [API](docs/API.md) · [Connect an AI client](Integration/README.md) · [Build and release](docs/BUILDING.md)

## Install

1. Download `Chatter-3.0.2-macOS-arm64.zip` from [Releases](https://github.com/mweingartner/chatter/releases), unzip, and drag **Chatter.app** into **Applications**.
2. Open Chatter. This initial public release is **ad-hoc signed, not notarized**. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** after attempting to open it. See [Apple's instructions](https://support.apple.com/en-us/102445). No system-wide security setting needs to be disabled.
3. Open Chatter from the menu bar. In **Speech engine**, select **Download / repair models**. Setup downloads approximately **15.6 GB** from Hugging Face, verifies pinned SHA-256 hashes, and starts the engine. Downloads resume if interrupted.
4. **Aiden and Ryan** are the only included saved voices. Select one in Studio and play speech or save a WAV. Add your own recordings through **Your voices** whenever you like.

Requires **Apple Silicon and macOS 26 or later**. Allow at least 20 GB of free disk space for model setup. Memory and latency depend on the model, recording length, and Mac; 16 GB or more is recommended, but minimum-memory hardware has not been qualified. First-use system transcription assets may also need downloading. Launch-at-login and LAN serving are enabled by default and can be changed in Preferences.

## What it does

- **Voice recording and import:** guided scripts, multiple takes, reviewed transcripts, recording-health checks, and all enabled samples combined into one reference. No sample is silently dropped. Original recordings stay intact.
- **Expression:** Aiden and Ryan accept natural-language directions and 33 curated tone presets. Recorded clones inherit delivery from their samples; Qwen Base does not support tone instructions. Voice design creates a speaker from a description.
- **Dialogue:** map actors to voices, write `Actor: words` lines, set pace and turn gaps, then play or export one combined WAV with turn timings.
- **Studio audio:** native **24 kHz mono, 24-bit PCM WAV**, pitch-preserving pace from 0.5–2×, punctuation pauses, and short fades at passage boundaries to prevent clicks. Saved jobs always use Studio quality.
- **Responsive playback:** stream audio as it is generated, or choose Balanced/Studio buffering. The engine stays available in a supervised helper process.
- **Automation:** authenticated HTTP and MCP on port **18423**, a native stdio bridge, and a portable Chatter plugin. Accepted jobs are persisted in FIFO order; queue capacity is 1,000 by default and configurable up to 10,000. Full queues return explicit retry guidance.
- **Video narration:** the plugin stages completed WAVs and measured timings for Remotion; Borumi and other editors can use the same audio. Video editors are optional and separately installed.

Voice setup uses reference conditioning, not model-weight training. Chatter can export reviewed datasets for Qwen's separate CUDA fine-tuning workflow. A generated voice design can vary across runs; save an approved sample as a recorded voice when you need a stable reference.

## One repository, local dependencies

All required Swift packages and native MLX source are included under `Vendor/Packages`, including populated C/C++ dependencies. A normal clone or GitHub source ZIP is enough; there are **no Git submodules, Git LFS objects, or package downloads** for the standard build. Versions and upstream revisions are recorded in [Vendor/dependencies.json](Vendor/dependencies.json).

```sh
git clone https://github.com/mweingartner/chatter.git
cd chatter
swift test
scripts/build-app.sh
```

Building requires Xcode with Swift 6.2 or newer and the macOS 26 SDK or newer. Apple supplies Xcode, macOS frameworks, and Metal; these are not redistributable project dependencies. The official Qwen Python repository is included as a reference under `Vendor/Qwen3-TTS`; Chatter neither runs it nor requires its Python dependencies. Model weights download during setup. Optional Ollama pronunciation suggestions require a separately installed Ollama service; speech does not require it.

## Privacy and connections

The repository and release include **only Aiden and Ryan preset definitions**, with no custom voice recordings, transcripts, saved profiles, API tokens, or generated narration. New installs receive their own token. Existing voice libraries are preserved, including intentionally empty ones.

Voice data and models live in `~/Library/Application Support/Chatter`; saved audio defaults to `~/Chatter/Audio`. Preferences controls the output folder, network access, token, and startup. Synthesis and transcription run locally. HTTP authentication is intended for a trusted LAN; use a private HTTPS proxy on an untrusted network. The plugin does not create a public tunnel.

For any local stdio MCP client, use `/Applications/Chatter.app/Contents/MacOS/chatter-mcp` as the server command. See [connection examples and plugin setup](Integration/README.md).

## License

Chatter's original code and documentation are **[MIT licensed](LICENSE)**, copyright © 2026 Michael Weingartner. Third-party components retain their own MIT, Apache-2.0, and other included notices; the root license does not relicense them. See [NOTICE](NOTICE), [third-party notices](docs/THIRD_PARTY_NOTICES.md), and [the native Qwen port](docs/QWEN_PORT.md). Downloaded model weights retain their upstream licenses.
