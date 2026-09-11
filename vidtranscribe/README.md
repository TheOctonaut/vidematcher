# vidtranscribe

Transcribes video files to subtitles using [WhisperX](https://github.com/m-bain/whisperX) (faster-whisper + word-level alignment), running locally in a GPU-accelerated Docker container. Produces a Jellyfin-compatible `.srt` subtitle file plus a richer `.json` sidecar (word-level timestamps and confidence scores) for future tagging/metadata use.

## Why

- Runs fully locally on an NVIDIA GPU (no cloud API, no per-minute cost).
- Auto-detects spoken language (English/French/etc.) per file.
- Word-level timestamps in the JSON output enable future features (e.g. searching dialog, tagging scenes/characters) without re-transcribing.
- Skips files that already have subtitles, so it's safe to re-run over a whole library.

## Prerequisites

- **Docker Desktop** (Windows, WSL2 backend) with GPU support enabled.
- An NVIDIA GPU with enough VRAM for the chosen model (the default `turbo` model works well within 12GB VRAM).
- **Docker Desktop VM memory**: the default WSL2 VM memory limit (as low as 2GB on some installs) is not enough to reliably pull/build the CUDA base image — large image layers can hang indefinitely during extraction. Increase it in Docker Desktop → Settings → Resources → Memory (8GB+ recommended) before building.
- **Network drives (e.g. a Jellyfin library on a mapped drive)**: enable file sharing for that drive under Docker Desktop → Settings → Resources → File sharing, or the container will fail to mount it.
- A [Hugging Face](https://huggingface.co/) account/API token, set as the `HF_TOKEN` environment variable, used for the first-time model download. Not required for every run once models are cached.

## First-time setup

1. Build the Docker image (this downloads a large base image and installs PyTorch/WhisperX — can take a long time, especially on a slow connection):
   ```powershell
   .\build-vidtranscribe.ps1
   ```
2. Copy `options.json.example` to `options.json` and set `ModelsPath` to a folder where downloaded models should be cached (e.g. `C:/server/vidtranscribe/models`). This folder grows over time as models are downloaded but is reused across runs and files — do not delete it between runs.
3. Set the `HF_TOKEN` environment variable in your shell/profile with your Hugging Face API token.

## Usage

Transcribe a single file:

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies\Some Movie\Some Movie.mp4"
```

Transcribe all `.mp4` files directly inside a folder (not recursive; files with an existing subtitle are skipped):

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies\Some Movie"
```

Preview what would be processed without doing any work:

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies" -DryRun
```

Force a specific spoken language instead of auto-detecting (useful if you already know it, or to skip the language probe described below):

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies\Un Film\Un Film.mp4" -Language fr
```

Run unattended (no confirmation prompt), e.g. from a scheduled task:

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies" -NoConfirm
```

## Options

CLI arguments override `options.json`, which overrides script defaults. `ModelsPath` has no default and must be set via `-ModelsPath` or `options.json`.

| Setting | CLI flag | Default | Notes |
| --- | --- | --- | --- |
| `ModelsPath` | `-ModelsPath` | *(required)* | Folder used as the persistent Hugging Face/torch model cache. |
| `DockerImage` | `-DockerImage` | `vidtranscribe:latest` | Image built by `build-vidtranscribe.ps1`. |
| `Model` | `-Model` | `turbo` | WhisperX/faster-whisper model size (`turbo` is a good speed/accuracy balance for 12GB VRAM). |
| `ComputeType` | `-ComputeType` | `float16` | Passed through to WhisperX. |
| `Device` | `-Device` | `cuda` | Use `cpu` to force CPU transcription (much slower). |
| `Language` | `-Language` | *(auto-detect)* | ISO 639-1 code (e.g. `en`, `fr`). Forces language instead of auto-detecting. |
| `MaxFiles` | `-MaxFiles` | `0` (no limit) | In directory mode, caps how many eligible files are processed in one run. Files beyond the limit are left for a subsequent run. Has no effect on a single-file `-Path`. |
| `AutoTranslate` | `-NoTranslate` (to disable) | `true` | When the detected/forced source language isn't English, also runs WhisperX's built-in `--task translate` and writes an additional `Movie.en.srt`. Set `"AutoTranslate": false` in `options.json`, or pass `-NoTranslate`, to skip this. |

`-OptionsFile` selects an alternate options file. `-DryRun` previews without transcribing. `-NoConfirm` skips the confirmation prompt (for automation).

## Output files

For an input `Movie.mp4`, on success the script writes, next to the video:

- `Movie.<lang>.srt` — subtitle file in the detected/source language, e.g. `Movie.fr.srt`. Jellyfin picks this up automatically as an external subtitle (language-tagged) after a library scan.
- `Movie.vidtranscribe.json` — full WhisperX output: per-segment and per-word timestamps and confidence scores. Namespaced to avoid clashing with other tools' `.json` sidecars. Not used by Jellyfin directly; intended for future tagging/search features.
- `Movie.en.srt` — **only** when the source language isn't English and `AutoTranslate` is enabled (default). Produced by a second WhisperX pass using its built-in `--task translate` (Whisper's own speech-to-English-text translation, not a general-purpose text translator), using the already-known source language so it doesn't need to re-detect it. This roughly doubles processing time for non-English files, and is skipped entirely for English-source files (no redundant `Movie.en.srt` alongside `Movie.en.srt`).

If either primary destination file (`.srt` / `.vidtranscribe.json`) already exists, the file is left alone (not overwritten) and reported as failed for that file. If only the translated `Movie.en.srt` already exists (e.g. a previous run was interrupted after the primary output but before translation), translation is skipped for that file without affecting its overall success/failure status.

WhisperX's `--task translate` is a fixed built-in feature of the Whisper model itself (not a separate/swappable translation engine); it translates directly from audio to English text and is generally less precise than a dedicated text-to-text translation model, especially for idiom/slang-heavy dialogue. It was chosen here as the lowest-effort option to try first. A more precise option (translating the existing transcript with a dedicated model like `Helsinki-NLP/opus-mt-<lang>-en` or NLLB, preserving exact timestamps) is a possible future addition if translation quality proves insufficient.

### Translating subtitles left over from before `AutoTranslate` existed

Directory-mode scanning inspects any existing `Movie.<lang>.srt` next to a video (parsed from the filename's language tag) and classifies each file into one of:

- **No subtitle at all** - full transcription runs as normal (and, if `AutoTranslate` is on and the detected language isn't English, is followed immediately by translation).
- **A non-English subtitle exists, but no `Movie.en.srt`** - transcription is skipped entirely (the existing `.srt`/`.json` are left untouched) and only the missing `Movie.en.srt` is produced, using the language already encoded in the existing subtitle's filename. This is what lets an older `Movie.pt.srt` (created by a run before this feature existed, or with `-NoTranslate`) pick up its English translation on a later run without re-transcribing.
- **An English subtitle already exists** (`Movie.en.srt`, or the detected/source language was English) - fully skipped, as before.
- **An untagged `Movie.srt`** (no `.xx.srt` language code in the filename, e.g. from very old runs) - fully skipped; the language can't be safely inferred from the filename, so it's left alone rather than guessed at.

The final `SUMMARY|...` line reports these translate-only files separately via `translated_only=<count>`, distinct from `processed=<count>` (full transcriptions).

## Language auto-detection accuracy

WhisperX's built-in language auto-detection only looks at the raw first ~30 seconds of audio, with no confidence check. Films very rarely open with true silence there, but many start with a logo sting, music, or an otherwise dialogue-free scene - and some (especially longer, dialogue-sparse "artistic" films) have long wordless stretches anywhere in their runtime, not just the intro. If that first 30-second window has no real speech, WhisperX's guess can be arbitrary, and forcing a mismatched language during transcription is a known way to get garbled or wrong-script subtitle output (including verbatim hallucinated text, not just wrong-script noise).

To avoid this, whenever no `-Language` is forced (and the file isn't `TranslateOnly`), a cheap pre-check runs before the real transcription:

1. `ffmpeg`/`ffprobe`, plus WhisperX's own voice-activity-detection (VAD) model (run standalone via a small helper script, `vad_probe.py`), find where the file actually contains speech across its *entire* runtime - not just a fixed offset or percentage.
2. One genuine speech window (~45s) is picked from each third of the runtime (first/middle/last), each extracted with `ffmpeg` and run through a fast pass (`--model tiny --no_align`) just to read back the language WhisperX detects for it.
3. If two or three windows agree, that majority language is used for the real transcription. A genuine three-way split (all different) falls back to English if English was one of the three guesses - a fair default for this library, where short/ambiguous dialogue (e.g. brief or non-verbal audio) is disproportionately likely to actually be English even when a probe window misreads it as something else. If English wasn't among the guesses, or fewer than two windows could be probed at all (e.g. no speech found in a given third), the script falls back to WhisperX's normal full-file auto-detection (i.e. no worse than before this feature existed) and prints a note explaining why.

This adds up to three small `tiny`-model passes per file (a few seconds each) plus one lightweight VAD pass, which is negligible next to the main transcription pass. The container needs the repo's `vad_probe.py` mounted alongside the input/output volumes to run this - handled automatically by the script, nothing to configure.

### A second, independent bug: mislabeled output regardless of detection accuracy

Separately from the above, WhisperX's own CLI has a bug in its output writer: whenever `--language` isn't explicitly passed, it unconditionally overwrites the output JSON's `language` field with its internal default (`en`) right before saving - regardless of what language was actually detected or transcribed. This means that for **any** file transcribed with auto-detection (before this fix), the recorded language in `Movie.vidtranscribe.json` (and therefore the `Movie.<lang>.srt` filename itself) may say `en` even when the real detected/transcribed language was something else entirely, independent of whether the transcription itself was accurate.

This is now worked around: the true detected language is instead read from WhisperX's `Detected language: <code> (<confidence>)` log line (surfaced via `--log-level info`, which does not print any dialogue text), and used for both the probe and, when no language was forced and the probe didn't resolve one, the real transcription's own filename/sidecar. Files transcribed before this fix may still have an incorrect recorded language in their sidecar even if their transcript text itself was fine - see the recheck tooling below.

### Fixing already-transcribed files

Files transcribed before these fixes may have been mislabeled - either because they were genuinely transcribed under the wrong language (the first bug above), or because their recorded language is simply wrong regardless of transcript accuracy (the second bug above). To audit and repair an existing library without a full from-scratch redo:

```powershell
# Preview only - reports mismatches, changes nothing
.\vidtranscribe.ps1 -Path "Z:\Movies" -RecheckLanguage

# Deletes the affected subtitle(s)/sidecar for mismatched files only, so a
# normal run afterwards will reprocess just those files
.\vidtranscribe.ps1 -Path "Z:\Movies" -RecheckLanguage -FixMismatches
.\vidtranscribe.ps1 -Path "Z:\Movies" -NoConfirm
```

`-RecheckLanguage` runs the same VAD-based probe against every file that already has a `.vidtranscribe.json` sidecar, and compares it to the language that sidecar originally recorded. With `-FixMismatches`, a disagreement deletes the primary `Movie.<lang>.srt`, the `.vidtranscribe.json` sidecar, and (if the recorded language wasn't English) any derived `Movie.en.srt` translation - since a wrong source language also invalidates anything translated from it. This makes the file fall through cleanly to be picked up and fully retranscribed by a normal run. Files where the probe agrees with the recorded language, or where the probe itself fails, are left untouched. The final `SUMMARY|...` line reports `already_verified=`/`checked=`/`matched=`/`mismatched=`/`probe_failed=` counts.

**Caveat for files transcribed before the second (mislabeling) bug was fixed**: because those sidecars' recorded language is unreliable (frequently `en` regardless of the true language), the recheck will flag essentially every genuinely non-English auto-detected file as a mismatch and queue it for reprocessing - even in cases where the original transcript text happened to be correct and only its recorded label was wrong. This is a conservative but safe outcome (reprocessing a file that was already fine just repeats work), and it's the only reliable way to recover trustworthy metadata for those files without inspecting each transcript by hand.

### Skipping files already verified under the current probe logic

Every sidecar written or successfully rechecked stores a `vidtranscribe_probe_version` number alongside `language`, identifying which version of the probing logic produced or last confirmed that language. By default, `-RecheckLanguage` skips any file already stamped with the current version - so as the probing logic keeps improving (e.g. the move to 3-window majority voting), you never have to re-audit a file that's already been verified under today's logic, and can always tell which files still predate a given fix. The number of skipped files is reported both as a `Language recheck: N file(s) already verified...` line and an `already_verified=` count in the final summary.

To force a full re-probe regardless of any existing stamp (e.g. after a probing logic change you want to re-verify everything against), add `-ForceRecheck`:

```powershell
.\vidtranscribe.ps1 -Path "Z:\Movies" -RecheckLanguage -ForceRecheck
```

## Pre-caching alignment models

WhisperX downloads a per-language alignment model the first time it needs that language, and only then - not up front. For most languages this is a small (~360MB) download, but for some (e.g. Portuguese, Russian) it's a large (~1.2GB) Hugging Face download that can stall mid-transcription on a flaky connection, which looks like the whole run has hung.

If you know in advance which non-English languages you'll be transcribing, pre-download their alignment models with:

```powershell
.\precache-align-models.ps1 -Languages pt,ru,it,fr,de
```

This runs `whisperx.alignment.load_align_model()` directly inside the container **on the CPU** (never the GPU), so it's safe to run alongside a live GPU transcription batch without contention. It uses the same `ModelsPath`/`DockerImage` as `vidtranscribe.ps1` (from `options.json` by default, or override with `-ModelsPath`/`-DockerImage`), so the cached models are actually reused by later real runs.

## Console output

Each real WhisperX pass is run with `--verbose False` plus `--log-level info`, so normal runs print a `PROGRESS|...` line per file (start/complete), the final `SUMMARY|...` line, and WhisperX's own `INFO`-level log lines (e.g. `Detected language: fr (0.98)`, used to work around the mislabeling bug above) - but never per-segment transcript text, which stays suppressed regardless of `--log-level`. This was a deliberate choice: the actual dialog content isn't needed to see whether a run succeeded, and keeping it out of console/log output avoids incidentally surfacing potentially sensitive transcript text in shared terminals, screenshots, or saved logs.

## Known limitations

- **Mixed-language files**: WhisperX transcribes the whole file under a single detected/forced language assumption (see "Language auto-detection accuracy" above for how that language is chosen). Files that genuinely switch languages partway through will have degraded accuracy on the non-primary-language portions. Use `-Language` to at least guarantee the majority-language segments are treated correctly, and review manually for full accuracy.
- **No speaker diarization yet**: speaker labels (who said what) are not produced in this version. This would require an additional gated pyannote model (extra one-time download, modest processing overhead) and may be added later.
- **Auto-translation quality**: see the note above about Whisper's built-in translate task being less precise than a dedicated translation model.
- Only top-level `.mp4` files are scanned when given a directory (no recursion into subfolders).

## Suppressed container warnings

The container output intentionally suppresses two `pyannote.audio` warnings via `PYTHONWARNINGS` in the `Dockerfile` (placed *after* the slow `pip install` layer so changing it doesn't invalidate the Docker build cache). Both were investigated and judged not worth acting on; documenting the reasoning here so it isn't re-investigated later:

- **`torchcodec is not installed correctly...` (`UserWarning` from `pyannote.audio.core.io`)**: `torchcodec` is an optional, faster audio-decode backend for pyannote. It's not installed in this image, so pyannote falls back to its other audio-loading path. In this pipeline, WhisperX already decodes audio via `ffmpeg` (which is installed and working) and passes pyannote a pre-loaded in-memory waveform, so pyannote's torchcodec path is never actually used. Installing torchcodec would only silence the warning, not change behavior or speed.
- **`TensorFloat-32 (TF32) has been disabled...` (a `ReproducibilityWarning` from `pyannote.audio.utils.reproducibility`, which is itself a subclass of `UserWarning`)**: pyannote disables TF32 intentionally for deterministic/reproducible output. Re-enabling it could give a marginal speedup on the (already fast) voice-activity-detection step, at the cost of less consistent results run-to-run. Not worth the trade-off.

Both are suppressed the same way: `ignore::UserWarning:<module>`. Filtering by the base `UserWarning` category (rather than importing `ReproducibilityWarning` by its dotted class path) avoids a real gotcha hit while implementing this: `PYTHONWARNINGS` filters are parsed very early during Python's interpreter startup, before the venv's site-packages import context is fully settled — a filter referencing a custom warning class by dotted path (e.g. `pyannote.audio.utils.reproducibility.ReproducibilityWarning`) failed to resolve at that point and printed `Invalid -W option ignored: invalid module name: ...` on every single Python invocation in the container (harmless, but itself just more noise). Using the built-in `UserWarning` category sidesteps that.

One other noisy line **used to** appear here (now fixed, see "Checkpoint upgrade baked into the image" below): **"Lightning automatically upgraded your loaded checkpoint..."** — a one-time, per-run informational log from PyTorch Lightning about the bundled pyannote checkpoint's saved format version.

If the image is rebuilt (`build-vidtranscribe.ps1`) after a `whisperx`/`pyannote` version bump, re-check that these warning module paths still match — library internals could shift the module names.

## Checkpoint upgrade baked into the image

The pyannote VAD checkpoint bundled with `whisperx` (`whisperx/assets/pytorch_model.bin`) ships in an old Lightning checkpoint format. Without intervention, Lightning silently re-upgrades it in memory on every single run, printing `Lightning automatically upgraded your loaded checkpoint from v1.5.4 to v2.6.5...` and costing a small amount of time each time. The `Dockerfile` now runs Lightning's own `upgrade_checkpoint` utility once at build time so the fix is permanent in the image - the message and the repeated conversion cost are both gone from every run.

Two non-obvious things were needed to make this work in the build environment:

- **`--map-to-cpu`**: the Docker build stage has no GPU access (even though the final container runs with `--gpus all`), so the checkpoint must be converted with tensors mapped to CPU.
- **Forcing `torch.load(..., weights_only=False)`**: newer PyTorch defaults `torch.load` to `weights_only=True`, which rejects this checkpoint's pickled `omegaconf` config objects one class at a time (allowlisting them individually is a whack-a-mole). This is done by monkey-patching `torch.load` for the duration of the upgrade call. It's considered safe here because the checkpoint file comes from the `whisperx` package itself, installed via `pip install whisperx` in the same build stage moments earlier - not user-supplied or untrusted data.

If `whisperx` bumps its bundled checkpoint again in a future version (or Lightning's checkpoint format changes again), this step may start printing the "upgraded" message once more after a rebuild; re-apply the same approach if so.

## Not yet integrated into the dispatcher

This tool is currently standalone. It follows the repo's `SUMMARY|...`/`PROGRESS|...` output conventions so it can be wired into `viddispatch` later, but that integration has not been done yet.
