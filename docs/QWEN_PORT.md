# Native Qwen port and validation

The runtime vendors only Qwen3TTS and its codec prerequisites from `Blaizzy/mlx-audio-swift` commit `01dec7c9bdce3088a6b6b7ab9f2e403458195efb` (MIT), rather than linking all of MLX-Audio's models. The official algorithm/reference repository is QwenLM/Qwen3-TTS at `022e286b98fbec7e1e916cb940cdf532cd9f488e`. Swift package pins are MLX 0.31.4, MLX-LM 3.31.4 and Transformers 1.3.4: a compatible set verified on this Mac. This replaces the old 0.32.2-only Fish dependency graph.

Chatter modifications:

- Local-only model loading; no runtime repository download or deletion of damaged directories. Installer verifies immutable file hashes separately.
- Missing tokenizer, codec or speaker weights fail visibly instead of using uninitialized components.
- Synchronous generation on the dedicated engine worker; external cancellation checked per frame; throwing chunk callback propagates disk and cancellation failures.
- Logs use stderr; stdout is exclusively the engine JSON protocol.
- A generation that reaches its frame budget without EOS fails rather than returning clipped success. The bound is larger than the upstream text heuristic, capped at 2,048 frames per passage.
- Speaker analysis corrected to the official Qwen frontend: periodic Hann, reflection padding 384, magnitude sqrt(real²+imag²+1e-9), 128 Slaney mel filters, natural log with 1e-5 floor. The upstream Swift helper used a Whisper-style normalized log-power representation. Numerical comparison with PyTorch/librosa over a deterministic 24 kHz fixture: shape 93×128, mean absolute error 0.00008452, maximum 0.004114 (FFT differences near the floor). This is frontend parity, not full model-output parity.
- Removed the upstream object-identity audio cache: freed array addresses can be reused for another speaker. Chatter alone caches conditioning by content, transcript, language and model.
- Recorded-voice conditioning combines all enabled takes with short silence and their exact transcripts. Content/model/language keys and a bounded cache avoid repeating reference encoding. No takes are silently omitted.
- Types distinguish Base cloning from instruction-capable CustomVoice/VoiceDesign. Leading delivery notes are separated from words. Dialogue serializes frozen actor configurations as one durable job and returns post-pace turn timings.

The native implementation retains the upstream licenses. Public packaging verification is recorded in [VERIFICATION.md](VERIFICATION.md). Performance depends on hardware, reference duration, and resident models; no latency guarantee is implied by an upstream GPU benchmark.
