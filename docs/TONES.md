# Qwen delivery tones

Chatter exposes 33 curated natural-language presets for Qwen 1.7B CustomVoice and VoiceDesign. These are instructions, not spoken control tags. `natural` adds no instruction. `GET /v1/tones` and `chatter_tones` discover exact IDs. For multi-actor dialogue, tones can be set per turn. Qwen interprets the words and separate instructions directly; Chatter no longer runs Ollama to annotate speech. Optional Ollama pronunciation suggestions remain on the Pronunciations page. Use normal prose in `text`, and use `instruction` for direction rather than adding emotion tags.

Recorded voices use Qwen Base, which inherits reference delivery and does not support instruction conditioning. The UI hides inapplicable controls; legacy tone requests return a warning and explicit unsupported instructions fail. Never promise a particular emotional intensity or voice likeness without listening.

| Group | API ID | Delivery intent |
|---|---|---|
| Natural | `natural` | Use the voice’s natural delivery without an added tone cue. |
| Positive | `cheerful` | Bright, friendly and upbeat. |
| Positive | `optimistic` | Hopeful, encouraging and positive. |
| Positive | `excited` | Enthusiastic and animated. |
| Positive | `confident` | Self-assured and certain. |
| Positive | `grateful` | Express appreciation and thanks. |
| Positive | `proud` | A sense of achievement and satisfaction. |
| Supportive | `warm` | Gentle, welcoming and caring. |
| Supportive | `friendly` | Approachable, conversational delivery. |
| Supportive | `calm` | Relaxed and composed. |
| Supportive | `empathetic` | Acknowledge another person’s feelings with care. |
| Supportive | `reassuring` | Steady, comforting encouragement. |
| Supportive | `apologetic` | A sincere expression of regret. |
| Firm & focused | `stern` | Firm and authoritative. |
| Firm & focused | `serious` | Measured, focused and thoughtful. |
| Firm & focused | `determined` | Resolved and committed. |
| Firm & focused | `professional` | Clear, polished presentation. |
| Reflective | `curious` | Engaged, questioning and interested. |
| Reflective | `reflective` | Contemplative and considered. |
| Reflective | `nostalgic` | A wistful recollection of the past. |
| Reflective | `sad` | Subdued and sorrowful. |
| Reflective | `bored` | Low interest and little enthusiasm. |
| Intense | `angry` | Forceful, with audible displeasure. |
| Intense | `frustrated` | Impatient or exasperated. |
| Intense | `nervous` | Uneasy or hesitant. |
| Intense | `worried` | Concerned about what may happen. |
| Intense | `scared` | Fearful and apprehensive. |
| Intense | `surprised` | An unexpected realization or reaction. |
| Intense | `sarcastic` | Dry irony; results depend strongly on the words. |
| Delivery | `whisper` | A soft, whispered delivery. |
| Delivery | `soft` | Quiet and gentle, with a normally voiced delivery. |
| Delivery | `urgent` | A hurried sense of immediacy; pace remains separately adjustable. |
| Delivery | `shouting` | Raised, forceful delivery. |


The official [Qwen usage examples](https://github.com/QwenLM/Qwen3-TTS#custom-voice) and [model report](https://arxiv.org/abs/2601.15621) support instruction conditioning for the designated models. Chatter's preset catalog is a convenience interface, not an exhaustive model vocabulary or a guarantee of distinct perceptual output. Historical Fish studies are archived separately and do not validate Qwen behavior.
