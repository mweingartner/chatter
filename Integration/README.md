# Chatter connections

Chatter must be running on an Apple Silicon Mac. It serves an authenticated API and MCP on port 18423 by default. Requests queue durably in order. The plugin contains no credentials or model weights.

## ChatGPT Work on this Mac / Codex

The local plugin is named **chatter**, displayed as **Chatter**. It contains the speech MCP connection and a skill for narration, including coordination with Remotion and handoff to Borumi. In ChatGPT Work or Codex on this Mac, enable Chatter from the personal marketplace in the plugin directory, then start a new chat to load its tools. The stdio bridge locates this Mac's token and current port automatically. No cloud speech provider or tunnel is required for this local Work workflow.

Example request: “Use Chatter to save this narration in Ryan's voice at pace 1.0, then add it to my Borumi project.” The skill discovers saved voices and their capabilities, queues full-quality WAV output, waits for completion, and uses the measured file duration for the editor handoff. Qwen recorded clones inherit delivery from their reference recordings; instruction-based tones such as optimistic are available for built-in and designed voices. Borumi must be running and its MCP tools available in that chat. The plugin neither installs nor configures Borumi.

The eight tools are `chatter_status`, `chatter_capabilities`, `chatter_voices`, `chatter_tones`, `chatter_speak`, `chatter_dialogue`, `chatter_job`, and `chatter_cancel`. For media work, use `mode: "save"`; completed `chatter_job` results include `path`, `duration`, `audioURL`, and the accepted request. `chatter_dialogue` accepts a cast mapping actors to saved voices and ordered turns, then produces one WAV with per-turn actor timings. Voice setup remains in the native Chatter app.

If an existing chat lists only six tools or omits `language`/`instruction`, refresh the installed plugin and start a new chat. The bridge forwards the running app's schema; an old chat can retain an older discovery snapshot. Both `plugin.json` and `.codex-plugin/plugin.json` must carry the same version/cachebuster when publishing an update, because hosts may select either manifest. Verify the installed transport with `scripts/chatter-tools.sh verify plugin --bridge /absolute/plugin/path/scripts/launch-mcp.sh --voice Ryan --output /absolute/report.json`. This creates a short saved track and checks current schemas, capabilities and WAV format. It uses Natural for clones and Optimistic plus a separate instruction for supported voices.

Root `plugin.json` and `mcp.json` provide the portable Agent Plugins package. Install the `chatter` folder as a local plugin on another Mac. The relative launch command resolves inside the installed plugin cache, with no installation-specific path embedded. The included `.codex-plugin/plugin.json` and `.mcp.json` provide Codex/Claude compatibility packaging. For Claude Code, use its local-plugin installation flow; for generic clients, use the stdio instructions below.

OpenAI's [plugin packaging guide](https://developers.openai.com/plugins/build/plugins) documents personal marketplaces for Work and Codex in the ChatGPT desktop app. The installed transport is checked independently of the conversation: an already-running chat does not hot-load newly installed tools. See [the verification record](../docs/VERIFICATION.md) for the exact tested boundary.

## Remotion workflow

Enable both plugins in a local chat and use a prompt such as:

> Use @chatter and @remotion to create a detailed overview of an enterprise automation platform, its value to Platform Engineer, Security Engineer and Financial Controller, with an example stack use case for each. Use an optimistic tone.

The [included workflow](chatter/skills/chatter/references/remotion.md) guides research, a source-backed storyboard, scene-by-scene narration in the default saved voice, and Remotion composition. It preserves the three distinct personas and separates documented product capabilities from proposed architecture or illustrative examples. A private strategy document still needs to be available to support claims about its contents.

Chatter remains the narration provider when both plugins are named. The packaged handoff script stages completed WAVs into the Remotion project and writes `chatter-narration.json` with actual audio durations, frame placement, voice, tone and pace. A reusable `ChatterNarration.tsx` component consumes that manifest. The agent runs these steps; the user need not manually move audio files or calculate durations. Existing narration can be reused on visual-only revisions, and the resulting project can render without Chatter running once its WAVs are staged.

The handoff also retains available Qwen language, delivery instruction, quality, voice configuration, model, reference IDs and warnings. Dialogue scenes retain the cast, per-turn controls and validated post-pace turn timings in seconds and scene-relative frames. These are additive schema-version-1 fields; earlier single-speaker manifests and components remain compatible. Turn timing is for actor graphics and scene alignment, not word-level captions. Requested tone metadata must be interpreted alongside voice capabilities and warnings.

Remotion's [Audio component](https://www.remotion.dev/docs/media/audio), [static files](https://www.remotion.dev/docs/staticfile) and [sequences](https://www.remotion.dev/docs/sequence) supply the three primary implementation references. Integration checks cover a three-scene local render; they do not claim that the full example video has been authored or that a fresh Work chat has invoked both plugins.

## Any stdio MCP client (including Claude Desktop)

Add a server with command `/Applications/Chatter.app/Contents/MacOS/chatter-mcp` and no arguments. It is a signed native executable; no Python or other runtime is required. The plugin's `scripts/launch-mcp.sh` finds it automatically.

For another computer, add environment variables:

- `CHATTER_URL=https://chatter-host.local:18424` (or its LAN IP)
- `CHATTER_TOKEN_FILE=/absolute/path/to/private-token-file`
- `CHATTER_TLS_SHA256=<64 hexadecimal characters verified in Chatter Connections>`

Create a scoped client token using Chatter → Connections. The local administrator token is not accepted on the LAN listener. Verify the certificate fingerprint on the host Mac before copying it into the client configuration. Store it in a local file readable only by that account (`chmod 600`). `CHATTER_TOKEN` is supported as an environment variable when the client securely manages it. Never put the token in a URL or commit it.

## Streamable HTTP MCP

URL `https://HOST:18424/mcp`; Authorization header `Bearer CLIENT_TOKEN`. Use the fingerprint-aware bridge unless the native HTTP client can explicitly verify/trust the generated certificate. Never disable certificate verification. JSON responses, stateless sessions, and protocol versions 2025-03-26, 2025-06-18, 2025-11-25. The server returns 405 to GET because it does not offer a persistent SSE notification channel. Tools return job IDs promptly instead of keeping model generation inside an HTTP request.

Browser/mobile ChatGPT is outside this local Work setup. It needs a separately registered reachable MCP connection, as described in OpenAI's [ChatGPT connection guide](https://developers.openai.com/plugins/deploy/connect-chatgpt). The local plugin does not expose Chatter publicly.

LAN access uses Chatter's native HTTPS listener and a scoped client credential. Verify and configure the certificate fingerprint shown in Connections; the bridge rejects remote plaintext HTTP. Chatter rejects browser Origin requests and does not enable CORS.
