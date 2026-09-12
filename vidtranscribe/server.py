"""Persistent WhisperX worker server for vidtranscribe.ps1.

Runs as a single long-lived process inside one docker container (started
once per machine, reused across script invocations) instead of the previous
pattern of spawning a fresh `docker run --rm ... whisperx ...` process for
every VAD scan, language-probe clip, transcription, and translation. Each
fresh process previously reloaded every model (VAD, tiny probe, main
transcription model, alignment model) from disk into GPU memory from
scratch - measured at roughly 15-50 seconds of pure reload overhead per
file. This server loads each model once (lazily, on first use) and keeps it
resident in memory, so every request after the first pays no reload cost at
all.

Endpoints (JSON over HTTP, expected to be reachable only from localhost):
  GET  /health
      -> {"status": "ok", "model": "<name>", "translate_model": "<name>",
          "device": "<dev>", "compute_type": "<ct>"}

  POST /vad             {"file": "<container path>"}
      -> {"segments": [{"start": <sec>, "end": <sec>}, ...]}

  POST /probe_language  {"file": "<container path to a short clip>"}
      -> {"language": "<code>"}

  POST /transcribe      {"file": "<container path>", "language": "<code>"|null,
                          "output_dir": "<container path>"}
      -> {"success": true, "detected_language": "<code>"}
      Writes <basename>.srt / <basename>.json (plus the other whisperx
      "all"-format outputs) into output_dir, exactly like the whisperx CLI's
      default --output_format all. Uses --model (e.g. "turbo").

  POST /translate       {"file": "<container path>", "source_language": "<code>",
                          "output_dir": "<container path>"}
      -> {"success": true}
      Writes <basename>.srt (translated to English) into output_dir. Uses
      --translate_model (default "large-v3"), a separate/larger model from
      --model: distilled models like "turbo" transcribe well but have their
      decoder pruned in a way that specifically guts translate-task quality,
      so translation uses its own undistilled model instead.

All endpoints return a non-2xx status with {"error": "<message>"} on
failure, so the caller can treat any non-2xx response as equivalent to a
failed docker invocation.

A single global lock serializes all GPU-touching work: there is only one
GPU on this machine, so there is no benefit to (and real risk from) letting
requests overlap.
"""
import argparse
import json
import threading
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import torch
from whisperx.alignment import align, load_align_model
from whisperx.asr import load_model
from whisperx.audio import load_audio, SAMPLE_RATE
from whisperx.utils import get_writer
from whisperx.vads import Pyannote

parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--translate_model", default="large-v3")
parser.add_argument("--device", required=True)
parser.add_argument("--compute_type", required=True)
parser.add_argument("--port", type=int, default=8756)
CLI_ARGS = parser.parse_args()

_gpu_lock = threading.Lock()
_state = {
    "main_pipeline": None,
    "tiny_pipeline": None,
    "translate_pipeline": None,
    "vad_model": None,
    "align_models": {},
}


VAD_OPTIONS = {"chunk_size": 30, "vad_onset": 0.500, "vad_offset": 0.363}


def get_vad_model():
    if _state["vad_model"] is None:
        device = torch.device(CLI_ARGS.device) if CLI_ARGS.device == "cuda" else torch.device("cpu")
        _state["vad_model"] = Pyannote(device, token=None, **VAD_OPTIONS)
    return _state["vad_model"]


def get_main_pipeline():
    if _state["main_pipeline"] is None:
        _state["main_pipeline"] = load_model(
            CLI_ARGS.model, device=CLI_ARGS.device, compute_type=CLI_ARGS.compute_type, language=None,
        )
    return _state["main_pipeline"]


def get_tiny_pipeline():
    if _state["tiny_pipeline"] is None:
        _state["tiny_pipeline"] = load_model(
            "tiny", device=CLI_ARGS.device, compute_type=CLI_ARGS.compute_type, language=None,
        )
    return _state["tiny_pipeline"]


def get_translate_pipeline():
    # The distilled "turbo" model (large-v3-turbo) used for the main
    # transcribe pass has its decoder pruned from 32 layers down to 4 -
    # great for transcription speed, but that pruning specifically guts its
    # translate-task quality (translation needs more decoder capacity than
    # plain same-language transcription). A separate, undistilled model is
    # used just for the /translate endpoint so transcription keeps its
    # turbo speed while translation actually works.
    if _state["translate_pipeline"] is None:
        _state["translate_pipeline"] = load_model(
            CLI_ARGS.translate_model, device=CLI_ARGS.device, compute_type=CLI_ARGS.compute_type, language=None,
        )
    return _state["translate_pipeline"]


def get_align_model(language_code):
    if language_code not in _state["align_models"]:
        _state["align_models"][language_code] = load_align_model(language_code, CLI_ARGS.device)
    return _state["align_models"][language_code]


def do_vad(file_path):
    vad_model = get_vad_model()
    audio = load_audio(file_path, sr=SAMPLE_RATE)
    waveform = Pyannote.preprocess_audio(audio)
    raw_segments = vad_model({"waveform": waveform, "sample_rate": SAMPLE_RATE})
    segments = Pyannote.merge_chunks(
        raw_segments, VAD_OPTIONS["chunk_size"], onset=VAD_OPTIONS["vad_onset"], offset=VAD_OPTIONS["vad_offset"],
    )
    result = [{"start": round(float(s["start"]), 3), "end": round(float(s["end"]), 3)} for s in segments]
    result.sort(key=lambda s: s["start"])
    return {"segments": result}


def do_probe_language(file_path):
    pipeline = get_tiny_pipeline()
    audio = load_audio(file_path, sr=SAMPLE_RATE)
    result = pipeline.transcribe(audio, task="transcribe")
    return {"language": result["language"]}


def do_transcribe(file_path, language, output_dir):
    pipeline = get_main_pipeline()
    audio = load_audio(file_path, sr=SAMPLE_RATE)
    result = pipeline.transcribe(audio, task="transcribe", language=language)
    detected_language = result["language"]

    align_model, align_metadata = get_align_model(detected_language)
    aligned = result
    if align_model is not None and len(result["segments"]) > 0:
        aligned = align(
            result["segments"], align_model, align_metadata, audio, CLI_ARGS.device,
            interpolate_method="nearest", return_char_alignments=False,
        )
    aligned["language"] = detected_language

    writer = get_writer("all", output_dir)
    writer_args = {"highlight_words": False, "max_line_count": None, "max_line_width": None}
    writer(aligned, file_path, writer_args)

    return {"success": True, "detected_language": detected_language}


def do_translate(file_path, source_language, output_dir):
    pipeline = get_translate_pipeline()
    audio = load_audio(file_path, sr=SAMPLE_RATE)
    result = pipeline.transcribe(audio, task="translate", language=source_language)
    result["language"] = "en"

    writer = get_writer("srt", output_dir)
    writer_args = {"highlight_words": False, "max_line_count": None, "max_line_width": None}
    writer(result, file_path, writer_args)

    return {"success": True}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args_):
        pass

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "model": CLI_ARGS.model,
                "translate_model": CLI_ARGS.translate_model,
                "device": CLI_ARGS.device,
                "compute_type": CLI_ARGS.compute_type,
            })
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception as exc:
            self._send_json(400, {"error": f"invalid request body: {exc}"})
            return

        try:
            with _gpu_lock:
                if self.path == "/vad":
                    result = do_vad(body["file"])
                elif self.path == "/probe_language":
                    result = do_probe_language(body["file"])
                elif self.path == "/transcribe":
                    result = do_transcribe(body["file"], body.get("language"), body["output_dir"])
                elif self.path == "/translate":
                    result = do_translate(body["file"], body["source_language"], body["output_dir"])
                else:
                    self._send_json(404, {"error": "not found"})
                    return
            self._send_json(200, result)
        except Exception as exc:
            traceback.print_exc()
            self._send_json(500, {"error": str(exc)})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", CLI_ARGS.port), Handler)
    print(f"vidtranscribe worker listening on port {CLI_ARGS.port} (model={CLI_ARGS.model}, translate_model={CLI_ARGS.translate_model}, device={CLI_ARGS.device}, compute_type={CLI_ARGS.compute_type})", flush=True)
    server.serve_forever()
