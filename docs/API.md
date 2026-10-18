# Chatter 3 API

All routes require `Authorization: Bearer TOKEN`. Read tokens without printing or logging them. Local access is `http://127.0.0.1:18423`; the local administrator token is accepted only there. LAN access is disabled by default. Enable it in Connections to serve `https://HOST:18424`, verify the displayed certificate SHA-256 fingerprint, and create an expiring client token. The portable plugin accepts `CHATTER_TLS_SHA256`; it refuses plaintext remote URLs. Browser Origin requests are rejected.

Each client has read/speak/cancel scopes and optional voice restrictions. Clients can retrieve or cancel only their own jobs; inaccessible jobs return 404. Expired/revoked tokens return 401; missing REST permissions return 403. MCP tool permission failures use the normal `isError` result. Client secrets are shown once; only their hashes are persisted. The local administrator can inspect all jobs. Revocation cancels the client's active requests.

Local and LAN listeners use different ports and separate connection pools. TLS 1.2 or later is required. The generated certificate is valid for one year: use Replace LAN identity and update client fingerprints before expiry. Do not bypass certificate verification. Generic HTTPS clients can explicitly trust an exported certificate and connect using its `localhost` hostname through a local tunnel; use the fingerprint-aware plugin for direct LAN connections.

Limits: 2 MB HTTP bodies, 16 KiB headers, 100,000 UTF-8 bytes of speech, 600 requests/minute per credential, 60 new jobs/minute per scoped client, and a default 100 queued jobs/client. Queue and rate refusal returns 429 with Retry-After. Storage/unavailability refusal returns 503. A valid retained requestID retry returns the original job before submission-capacity checks. Retry keys are scoped by client ID. The global FIFO queue defaults to 1,000 active jobs.

Defaults: maximum audio 30 minutes/job, maximum generation 60 minutes/job, storage budget 20 GB, and at least 1 GB disk reserve plus working space. These limits are configurable in General preferences. History retains up to 1,000 finished jobs for 30 days, including archived jobs. Active jobs do not expire. WAVs are preserved unless automatic deletion is enabled. Copy narration outside the output directory for permanent retention when using automatic deletion. After a receipt expires, its audio route and retry key are no longer available.

## Discovery

`GET /v1/health` (also `/v1/status`) returns readiness, warm profiles, queue depth/capacity, engine and sample format. `GET /v1/capabilities` returns voice kinds, languages, nine built-in speakers, instruction support, reference limit, dialogue limits and the model/buffering policy for each quality level. `GET /v1/voices` returns saved IDs, type, configuration and enabled references. `GET /v1/tones` returns the 33 curated delivery presets.

## Speech

`POST /v1/speech`:

```json
{"voice":"Ryan","text":"Hello. This runs locally.","mode":"save","pace":1.0,"language":"English","tone":"natural","requestID":"intro-v1"}
```

Required `voice` is a unique saved ID/name; `text` is up to 100,000 UTF-8 bytes. `mode` is `play` (default), `save` or `render`. Pace is 0.5–2.0. Optional `quality` is responsive/balanced/studio; play and render use it (or the live quality when omitted), and save always uses studio. Optional `sampleID` selects one recording instead of the enabled set. `language` overrides the profile. `instruction` is a natural-language direction up to 2,000 UTF-8 bytes, supported only by built-in or designed voices. Non-natural `tone` on a recorded voice returns a warning; explicit unsupported instructions fail with 400. A designed voice whose description asks for an accent returns a warning: Qwen voice design cannot produce accents, so use a recorded voice made from a reference in that accent. Inspect capabilities instead of assuming all voices support every control.

Qwen receives plain text plus separate tone/instruction fields directly. Chatter does not annotate speech with Ollama or load an auxiliary language model before generation. Old expression switches and `expressive` fields no longer enable a review. Previously accepted plans remain readable for restart compatibility. Leading parenthesized/bracketed delivery notes are separated from spoken text. Recorded clones do not receive delivery instructions. Dialogue uses explicit per-turn controls and does not run automatic expression review. Pronunciation mappings continue to apply at synthesis time.

### Render mode

`"mode":"render"` generates audio for a client to download, at the requested quality, without playing anything on the Mac or exporting a WAV to the output folder. The audio is available from `audioURL` for 10 minutes after it is generated (`renderRetentionSeconds` in capabilities) and deleted within about a minute after that, including for archived jobs; the receipt stays and no longer offers `audioURL`. Retrying with the same `requestID` after that returns the receipt without audio, so ask again with a new `requestID`. Render is for single-voice speech; dialogue accepts play or save. A render's audio matches `play` at the same quality, and the job never starts, stops or waits for the Mac's playback.

### Waiting for the result

Add `?wait=true` to `POST /v1/speech` or `GET /v1/jobs/{id}` to hold the reply until the job is completed, failed or cancelled, for at most 30 seconds (`maximumWaitSeconds`); `?wait=N` waits at most N seconds. A submission that finished in time returns 200 with the final receipt; otherwise it returns 202 with the receipt as it stands, and the client continues with `GET /v1/jobs/{id}?wait=true`. A credential may hold 8 waiting requests at once; further requests answer immediately.

## Quality levels

| Level | Recorded voices | Built-in / designed voices | Playback |
|---|---|---|---|
| Responsive | 0.6B Base, 8-bit | 1.7B CustomVoice / VoiceDesign, BF16 | Short generated chunks |
| Balanced | Same 0.6B Base, 8-bit | Same 1.7B model | Complete generated passages |
| Studio | 1.7B Base, BF16 | Same 1.7B model | Complete generated passages |
| Save WAV | 1.7B Base, BF16 | Same 1.7B model | File export |

All levels output native 24 kHz mono, 24-bit PCM. BF16 describes model weights, not WAV bit depth. Balanced is a buffering choice, not an intermediate model. All save requests force Studio even when a lower live quality is supplied. See `qualities` and `saveQuality` in capabilities.

## Multi-actor dialogue

`POST /v1/dialogue`:

```json
{
  "cast":{"Host":"Ryan","Expert":"Aiden"},
  "turns":[
    {"actor":"Host","text":"How can we help?","language":"English"},
    {"actor":"Expert","text":"Together, we can make it happen.","tone":"optimistic","instruction":"Sound warm and engaged."}
  ],
  "gapSeconds":0.4,"pace":1.0,"mode":"save","requestID":"conversation-v1"
}
```

Cast values must name voices already saved in Chatter. Limits: 20 actors, 500 turns, 100,000 total spoken UTF-8 bytes. Turn spacing is 0–10 seconds before the global pace adjustment. Per-turn language/tone override the optional global values. Each turn can have its own instruction. Actor labels are metadata, not spoken text. Cloning, built-in and designed voices may be mixed.

The entire dialogue is one durable FIFO job; other clients cannot interleave its turns. Voice settings and reference transcripts are frozen when accepted. `mode: "play"` accepts `quality` and plays on the host Mac: Responsive streams chunks as they are generated; Balanced and Studio buffer passages. `mode: "save"` always produces a studio WAV. Playback can contain extra generation or model-switching waits; it is not guaranteed gapless real-time synthesis. Completion includes one WAV plus `dialogueTiming`: actor, actual `modelID`, start and duration in seconds after pace adjustment. Turn durations exclude the following gap. Final WAV duration is authoritative for editor timing.

## Jobs and reliability

Both POST routes return HTTP 202 with a persistent receipt. Poll `GET /v1/jobs/{id}` until completed, failed or cancelled; `GET /v1/jobs` lists recent jobs. Completed receipts include `path`, `duration`, model/profile, sample format, warnings and `audioURL`. `GET /v1/jobs/{id}/audio` retrieves the WAV with the same authentication. `DELETE /v1/jobs/{id}` cancels it: a running job stops at its next generated frame, so the queue moves on promptly. Only cancelling a `play` job stops the Mac's playback; cancelling a render or save leaves anything playing alone. Local paths refer to the Chatter host.

One job generates/plays at a time. Default pending capacity is 1,000, configurable up to 10,000. Full queues return 429 with `Retry-After: 5`; network connection limits return 503. Reuse `requestID` or the `Idempotency-Key` header only for identical retries. Accepted jobs are durably saved before acknowledgment; no pending jobs are silently evicted. Restart recovery preserves order.

Output: native 24 kHz mono 24-bit PCM WAV. File names are generated by the app; API callers cannot select arbitrary paths. Maximum body 2 MB. Cloning sets are capped at 180 seconds including inter-take spacing; use shorter clean sets for latency. More reference audio does not necessarily improve likeness.

## MCP

POST JSON-RPC to `/mcp`, or launch the bundled `chatter-mcp` stdio bridge. Tools: `chatter_status`, `chatter_capabilities`, `chatter_voices`, `chatter_tones`, `chatter_speak`, `chatter_dialogue`, `chatter_job`, `chatter_cancel`. Tool schemas advertise supported inputs; initialize negotiates protocol versions. Submission acknowledges a queue entry, never finished audio. HTTP 405 for GET `/mcp` is intentional: no SSE subscription is offered.
