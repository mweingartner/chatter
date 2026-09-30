# Synthetic audio test fixtures

No speech recordings are distributed here. `probe.*` contains four seconds of deterministic stereo sine waves (220/880 Hz on the left, 330/1320 Hz on the right) with a slow amplitude envelope. Regenerate these files and their independent FFmpeg decoder measurements with `Tools/audiokit/make_format_fixtures.py`.

`prepare_source.wav` is a 330 Hz tone with deterministic LCG noise and quiet padding. `resample_in_*.wav` are generated chirps plus tones; expected arrays were computed by SciPy. `pcm24_*` contains explicit quantization edge cases, with golden output from libsndfile. Recording-health golden measurements use the signals mirrored in `TestSupport.swift`. Transcript strings are arbitrary test labels, not transcriptions of speech.

These generated signals are part of Chatter under its MIT license. Real transcription is an optional test accepting the user's local recording through an environment variable; no personal fixture is checked in.
