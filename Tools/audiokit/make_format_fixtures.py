"""Regenerate public format fixtures using mathematical tones, never speech recordings.

Optional developer tool: Python 3, NumPy, and FFmpeg.
None of these dependencies is needed to build, test, or run Chatter.
"""
from pathlib import Path
import json
import subprocess
import numpy as np
import wave

out = Path(__file__).resolve().parents[2] / 'Tests/ChatterAudioKitTests/Fixtures'
rate = 48_000
t = np.arange(4 * rate) / rate
# Distinct stereo channels exercise downmixing; smooth amplitude varies over the probe.
envelope = 0.65 + 0.35 * np.sin(2 * np.pi * 0.5 * t) ** 2
left = envelope * (0.12 * np.sin(2*np.pi*220*t) + 0.05 * np.sin(2*np.pi*880*t))
right = envelope * (0.09 * np.sin(2*np.pi*330*t) + 0.04 * np.sin(2*np.pi*1320*t))
samples = np.floor(np.stack([left,right],axis=1).reshape(-1) * 8388608).astype('<i4')
packed = samples.view(np.uint8).reshape(-1,4)[:,:3].tobytes()
with wave.open(str(out / 'probe.wav'), 'wb') as wav:
    wav.setnchannels(2); wav.setsampwidth(3); wav.setframerate(rate); wav.writeframes(packed)
formats = {
    'mp3': ['-c:a','libmp3lame','-b:a','192k'],
    'm4a': ['-c:a','aac','-b:a','192k'],
    'aac': ['-c:a','aac','-b:a','192k'],
    'flac': ['-c:a','flac'],
    'aiff': ['-c:a','pcm_s24be'],
    'caf': ['-c:a','pcm_s24le'],
    'ogg': ['-c:a','vorbis','-strict','-2','-b:a','192k'],
    'opus': ['-c:a','libopus','-b:a','128k'],
}
for ext,options in formats.items():
    subprocess.run(['ffmpeg','-nostdin','-v','error','-y','-i',str(out/'probe.wav'),
                    '-map_metadata','-1',*options,str(out/f'probe.{ext}')],check=True)
expected = {}
for ext in ['wav',*formats]:
    # Independent FFmpeg decode includes ADTS priming, like AVFoundation.
    raw=subprocess.check_output(['ffmpeg','-nostdin','-v','error','-i',str(out/f'probe.{ext}'),
                                 '-ac','1','-ar','44100','-f','f32le','-'])
    # FFmpeg uses a sqrt(2) stereo downmix; Chatter averages the channels.
    data=np.frombuffer(raw,dtype='<f4') / np.sqrt(2); source='ffmpeg/average-downmix'
    expected[ext]={'length':len(data),'rms':float(np.sqrt(np.mean(data.astype(np.float64)**2))), 'source':source}
(out/'formats_expected.json').write_text(json.dumps(expected,indent=2)+'\n')
print('Created nine synthetic format probes; no voice data used.')
