#!/bin/bash
# Reproducible MI-GAN -> Core ML (fp16). Run from anywhere. Needs uv, git.
set -euo pipefail
cd "$(dirname "$0")"
[ -d .venv ] || uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python torch torchvision coremltools numpy pillow gdown
mkdir -p vendor models out
[ -d vendor/MI-GAN ] || git clone --depth 1 https://github.com/Picsart-AI-Research/MI-GAN vendor/MI-GAN
[ -d vendor/MI-GAN-CoreML ] || git clone --depth 1 https://github.com/tatsuya-ogawa/MI-GAN-CoreML vendor/MI-GAN-CoreML  # reference only; its export.sh is NOT run
# official weights (Google Drive folder from MI-GAN README; MIT, see vendor/MI-GAN/LICENSE-WEIGHTS)
[ -f vendor/weights/migan_512_places2.pt ] || .venv/bin/python -I -m gdown --folder \
  "https://drive.google.com/drive/folders/1xNtvN2lto0p5yFKOEEg9RioMjGrYM74w" -O vendor/weights
for r in 512 256; do
  .venv/bin/python -I convert_migan.py "$PWD/vendor/MI-GAN/lib/model_zoo/migan_inference.py" \
    "$PWD/vendor/weights/migan_${r}_places2.pt" $r "$PWD/models/MIGAN_${r}.mlpackage"
done
