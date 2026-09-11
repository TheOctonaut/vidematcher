"""Standalone VAD-only helper used by vidtranscribe.ps1's language probe.

Runs WhisperX's own pyannote-based voice-activity detector directly (much
cheaper than a full transcription pass) against an input audio/video file and
prints the resulting speech segments as JSON to stdout: a list of
{"start": <seconds>, "end": <seconds>} objects, sorted by start time. Used to
find a genuine speech-containing window for language identification instead
of guessing a fixed offset, which is unreliable for content with long
wordless stretches (music, ambient sound, silence) anywhere in the runtime,
not just the opening.
"""
import json
import sys

import torch
from whisperx.audio import load_audio, SAMPLE_RATE
from whisperx.vads import Pyannote

if len(sys.argv) != 2:
    print("usage: vad_probe.py <input_file>", file=sys.stderr)
    sys.exit(2)

input_file = sys.argv[1]

device = torch.device("cuda") if torch.cuda.is_available() else torch.device("cpu")
vad_options = {"chunk_size": 30, "vad_onset": 0.500, "vad_offset": 0.363}
vad_model = Pyannote(device, token=None, **vad_options)

audio = load_audio(input_file, sr=SAMPLE_RATE)
waveform = Pyannote.preprocess_audio(audio)
raw_segments = vad_model({"waveform": waveform, "sample_rate": SAMPLE_RATE})
segments = Pyannote.merge_chunks(
    raw_segments,
    vad_options["chunk_size"],
    onset=vad_options["vad_onset"],
    offset=vad_options["vad_offset"],
)

result = [{"start": round(float(s["start"]), 3), "end": round(float(s["end"]), 3)} for s in segments]
result.sort(key=lambda s: s["start"])
print(json.dumps(result))
