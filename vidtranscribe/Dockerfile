FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/models/huggingface \
    XDG_CACHE_HOME=/models/cache \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip python3-venv ffmpeg \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --upgrade pip \
    && pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128 \
    && pip install whisperx

ENV PYTHONWARNINGS="ignore::UserWarning:pyannote.audio.core.io,ignore::UserWarning:pyannote.audio.utils.reproducibility"

# The pyannote VAD checkpoint bundled with whisperx is saved in an old Lightning checkpoint
# format. Lightning silently re-upgrades it in memory on every single run (printing a message
# suggesting this exact command), costing a small amount of time each run. Upgrading it once
# here, at build time, makes the fix permanent in the image and removes both the repeated
# cost and the message. --map-to-cpu is required because the Docker build environment has no
# GPU access, even though the final container will run with --gpus all. weights_only is forced
# to False because this checkpoint's pickled config (omegaconf) isn't on PyTorch's default
# allowlist; this is safe here since the file itself came from the whisperx package we just
# pip installed in this same build - no less trusted than the code that package already runs.
RUN python -c "\
import torch; \
_orig_load = torch.load; \
torch.load = lambda *a, **kw: _orig_load(*a, **{**kw, 'weights_only': False}); \
import sys; \
sys.argv = ['upgrade_checkpoint', '--map-to-cpu', '/opt/venv/lib/python3.12/site-packages/whisperx/assets/pytorch_model.bin']; \
from lightning.pytorch.utilities.upgrade_checkpoint import main; \
main()" \
    && rm -f /opt/venv/lib/python3.12/site-packages/whisperx/assets/pytorch_model.bin.backup

ENTRYPOINT ["whisperx"]
