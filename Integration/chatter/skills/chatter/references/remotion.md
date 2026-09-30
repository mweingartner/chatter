# Chatter + Remotion

Use this workflow when the user asks for Chatter narration in a Remotion video, including prompts that mention both `@chatter` and `@remotion`. Load the installed Remotion skill for composition, preview and rendering guidance. Chatter supplies the voice track; Remotion supplies the video. The user's named Chatter provider takes precedence over other TTS providers in generic Remotion examples. Do not request an ElevenLabs/OpenAI key or substitute another narrator for this workflow.

## From a brief to a narrated storyboard

For a request to author a video, research and write the script before requesting speech. Preserve supplied final scripts exactly. Keep factual sources and visual directions outside the spoken `text`. For an explanatory video, give each scene a stable ID, title, narrative purpose, spoken text, proposed visual and source links. An optimistic brief is not a reason to turn uncertain strategy claims into promises.

Resolve the saved voice with `chatter_voices`. If the user omits a voice, use the ready voice marked `isDefault`; if no usable default exists, ask which saved voice to use while continuing the storyboard. Omit `sampleID` to use the full configured voice set. Set the requested pace or 1.0 by default. Keep voice, tone and pace in the storyboard so revisions preserve delivery.

Check `chatter_capabilities` and the voice's `supportsInstructions` before promising a tone. Built-in and designed Qwen voices accept `tone: "optimistic"` and freeform delivery instructions. Recorded clones inherit delivery from their recordings: explicit instructions are rejected, and a legacy non-natural tone returns a warning instead of controlling emotion. Explain this limitation for a named cloned voice; never silently substitute another voice. Keep the requested tone in the storyboard as creative intent when the model cannot apply it.

### Example: Enterprise automation and three personas

The prompt “Use @chatter and @remotion to create a detailed overview of an enterprise automation platform, its value to Platform Engineer, Security Engineer and Financial Controller, with an example stack use case for each. Use an optimistic tone.” requests a research-backed video, not just three narrated title cards.

Resolve what the proposed platform refers to using user-provided strategy material and current primary vendor sources. Distinguish currently available product capabilities, a proposed target architecture, and illustrative workflows. If a referenced private strategy document is unavailable, ask for its source location while researching independently; do not claim to have read it or invent its contents. Identify product roles and integrations from evidence rather than assuming a collection of products is an already integrated stack. Record sources and uncertainty in the storyboard and final transcript.

Cover the strategy and stack first, then give each named persona its own goal, current problem, concrete workflow, responsibilities/approval points, result and measurable success criteria. Suitable use-case directions to substantiate with sources include:

| Persona | Candidate walkthrough | Outcome to explain without inventing metrics |
| --- | --- | --- |
| Platform Engineer | Provision or change an application environment under policy, verify health, and handle a failed change | Time to deliver, reliability, toil and a usable developer experience |
| Security Engineer | Detect a policy violation, prioritize it with context, approve remediation, and collect evidence | Exposure duration, remediation confidence and audit readiness |
| Financial Controller | Trace technology spend to owners and business activity, assess variance, and review an optimization proposal | Explainable allocation, forecasting, budget controls and evidence of realized value |

These are planning directions, not claims that the vendor currently implements every step. Preserve **Financial Controller** as a distinct financial-governance persona; do not silently replace it with an engineering manager or generic FinOps engineer. Give an optimistic but evidence-qualified synthesis. Choose a runtime proportional to “detailed,” and state the intended duration instead of silently compressing the brief into a short promo.

## Speech generation and a durable handoff

1. Use `chatter_tones` to validate an instruction-capable voice's tone. Call `chatter_speak` per scene with `mode: "save"`, the chosen voice, pace and supported tone. Use stable unique request IDs and retain the returned job IDs in the project. Save output uses the full-precision model and 24 kHz mono 24-bit WAV.
2. Keep a project-local `chatter-handoff.json` containing the scene order and job IDs. Save it after each acceptance so interrupted work can resume without repeating speech. Poll `chatter_job` to completion. Treat a full queue as backpressure: wait and retry the same unaccepted request rather than dropping a scene. For changed words or delivery, generate only the changed scenes with new request IDs.
3. Run the packaged `scripts/chatter-tools.sh remotion` using its actual installed plugin path (it runs Chatter's native `chatter-tools`). It retrieves audio through Chatter's authenticated endpoint, supports the same local/LAN connection settings as the MCP bridge, validates each WAV, and stages copies in the Remotion project's `public/chatter/` folder. It never submits new speech or edits video source files.

Input example (replace the job IDs with real receipts):

```json
{
  "fps": 30,
  "tailSeconds": 0.2,
  "scenes": [
    {"id": "platform-use-case", "title": "Platform Engineer", "jobID": "<completed Chatter job ID>"},
    {"id": "security-use-case", "title": "Security Engineer", "jobID": "<completed Chatter job ID>"},
    {"id": "controller-use-case", "title": "Financial Controller", "jobID": "<completed Chatter job ID>"}
  ]
}
```

```sh
/absolute/plugin/path/scripts/chatter-tools.sh remotion chatter-handoff.json --project /absolute/remotion/project
```

If the launcher cannot find Chatter, set `CHATTER_TOOLS_BIN` to `chatter-tools` inside Chatter.app. Add `--wait-seconds 600` to wait for already submitted work. A timeout leaves those jobs alone: resume the same handoff. A failed/cancelled job requires diagnosis before a replacement request. The existing manifest stays intact when preparation fails. Original Chatter WAVs remain in the user's configured output folder.

The helper writes `chatter-narration.json` at the project root. Each scene contains a relative `src`, verified SHA-256, actual `durationSeconds`, `audioFrames`, `from`, `durationInFrames`, tone, voice, pace and spoken text. It also retains available language, instruction, quality, voice configuration, reference sample IDs, engine/model and warnings. The manifest remains schema version 1 with additive metadata, so existing narration components keep working. Requested tones are not evidence that the model applied them; preserve capability warnings. Timing comes from the WAV's sample count. Audio frames round up; configurable tail silence adds breathing room. The manifest and served assets contain no bearer tokens, authenticated API links or host-specific source paths. It uses integer FPS (1–120); restage the handoff when changing FPS.

For a scene with several actors, use `chatter_dialogue` with an explicit cast and ordered turns. Each turn may specify its own supported tone, language and instruction. The scene is one durable queue job and one WAV. The helper preserves `dialogue` (cast, turns and original gap setting) and validates `dialogueTiming` against the script and final WAV. Timings contain actor, cast voice, model, start and duration in seconds after pace, plus scene-relative `from` and `durationInFrames`. Add the scene's `from` for placement on the full composition timeline. Frame intervals cover the turn by rounding its start down and end up; exact seconds remain authoritative. Use the cast for multiple voices, not the legacy scene-level `voice` field, which identifies the first actor. These are turn boundaries, not word-aligned captions. The helper stages one combined WAV and leaves speaker graphics to the composition.

## Remotion composition

Copy the packaged `assets/remotion/ChatterNarration.tsx` into the project and use it in the main composition. It renders `Audio` from `@remotion/media` with `staticFile(scene.src)` and frame-aligned `Sequence`s. Import the generated manifest and use its `fps` and `durationInFrames` on the registered `Composition`. Match `@remotion/*` package versions to the project's Remotion version.

```tsx
import narration from '../chatter-narration.json';
import {ChatterNarration} from './ChatterNarration';

// Inside the video's component, alongside the scene visuals:
<ChatterNarration manifest={narration} />
```

Build the visual scenes with Remotion's normal composition workflow, placing them at each manifest scene's `from` for its `durationInFrames`. For multi-scene videos, keep scene components separately editable. Keep audio at playback rate 1: Chatter already applied the requested pace. Do not use an absolute host WAV path or put Chatter's token/API URL in React or a browser. This local asset handoff lets the project render later without a running speech service.

Do not shorten narration to fit guessed scene durations or overlap narration merely to accommodate a visual transition. Extend visual holds/tails or adjust the storyboard. If captions are requested, align them to the final WAV; scene timing alone is not word alignment. Use actual transcription/alignment output and correct recognition mistakes against the source script.

## Verification and delivery

Preview the first scene, every persona section and the final scene. Verify that all narration scenes exist, the chosen tone/voice is recorded, scene boundaries follow the audio, and nothing is cut off. When rendering is within the user's request, render locally and check the encoded result for complete audio/video decode, duration, audio presence, legible text and representative frames. A generated WAV, open Studio preview or failed render is not a finished video.

Deliver the requested video/preview, editable project, original WAVs, transcript and source notes as appropriate. If Chatter is unavailable, keep the storyboard and queued IDs, report the specific problem, and continue independent visual work; do not silently use cloud TTS. This workflow requires both plugins loaded in a local ChatGPT Work/Codex chat. Browser/mobile reachability is a separate connection.

Implementation references (three primary Remotion sources): [local assets](https://www.remotion.dev/docs/staticfile), [frame placement](https://www.remotion.dev/docs/sequence), and [Audio](https://www.remotion.dev/docs/media/audio).
