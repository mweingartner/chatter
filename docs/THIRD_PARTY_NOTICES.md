# Third-party notices

Chatter original code is licensed under the root MIT license. That license does **not** replace the licenses of bundled components or downloaded models. Source attributions remain in place. Complete license texts are copied into `docs/licenses`, which ships inside the app.

| Component | License | Provenance |
|---|---|---|
| MLX-Audio-Swift Qwen/codec port | MIT, © 2025 Prince Canuma | `Sources/Qwen3Speech`, `Sources/Qwen3CodecSupport`; see [port record](QWEN_PORT.md) |
| Qwen3-TTS reference and speaker frontend | Apache-2.0 | `Vendor/Qwen3-TTS`; modified Swift frontend in `QwenSpeakerMel.swift` |
| MLX Swift, MLX Swift LM, MLX, MLX C | MIT | `Vendor/Packages/mlx-swift`, `mlx-swift-lm`, populated native source |
| Swift Transformers, Swift Hugging Face, Swift Jinja | Apache-2.0 | Corresponding `Vendor/Packages` directories |
| Swift Collections, Swift Numerics, Swift Syntax | Apache-2.0 with Swift Runtime Library Exception | Corresponding `Vendor/Packages` directories |
| Swift Crypto, Swift ASN.1 | Apache-2.0 (see component notices) | Includes attributed BoringSSL and test-vector code |
| EventSource | MIT | © Mattt |
| yyjson | MIT | © Yao Yuan |
| fmt, nlohmann/json | MIT | MLX Swift's native support source |
| metal-cpp | Apache-2.0 | MLX Swift's Apple Metal C++ headers |

Exact package versions, revisions, and original repository URLs are in [the dependency manifest](../Vendor/dependencies.json). The immutable vendored snapshot includes all source-level notices, including third-party test and documentation content. Additional copied notices are under `licenses/vendor`.

## Models

Qwen3-TTS model releases use Apache-2.0. The app downloads converted checkpoints from `mlx-community/Qwen3-TTS-12Hz-{0.6B-Base-8bit,1.7B-Base-bf16,1.7B-CustomVoice-bf16,1.7B-VoiceDesign-bf16}` at immutable revisions recorded in `ModelInstaller.swift`. Copies of their model cards and provenance are in `licenses/models`; their declared Apache-2.0 license text is included in `licenses/Qwen3-TTS-LICENSE`. Weights are not distributed in the repository or app archive. Aiden and Ryan reference built-in CustomVoice speaker IDs; no personal speech data is included.

## Other software

Apple frameworks/toolchains retain Apple's terms and are supplied by macOS/Xcode. Ollama, Remotion, Borumi, and AI clients are optional external integrations and are not bundled or relicensed by this project. The included Qwen Python reference can support external fine-tuning, but its separate Python/CUDA environment is not part of Chatter's native build.

Licensing/distribution decisions were checked against three primary policy sources: [MIT](https://opensource.org/license/mit), [Apache-2.0 section 4](https://www.apache.org/licenses/LICENSE-2.0), and [GitHub release documentation](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases), in addition to the actual included upstream license files/model cards.
