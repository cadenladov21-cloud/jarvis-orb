#!/bin/zsh
# Installs Kokoro, the free on-device voice Jarvis falls back to when ElevenLabs is out of credits.
# Everything goes into ~/Library/Application Support/JarvisOrb/kokoro (a private Python
# environment plus ~340 MB of model files); nothing else on the Mac is touched. Safe to re-run.
#
# kokoro-onnx (MIT) runs the Kokoro-82M model (Apache 2.0) with onnxruntime, no PyTorch.
set -euo pipefail

home="$HOME/Library/Application Support/JarvisOrb/kokoro"
python="${PYTHON:-/opt/homebrew/bin/python3.12}"
release="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1"

[[ -x "$python" ]] || { echo "Needs Python 3.10–3.13 (set PYTHON=/path/to/python3)"; exit 1; }
mkdir -p "$home/models"

if [[ ! -x "$home/venv/bin/python" ]]; then
  "$python" -m venv "$home/venv"
fi
"$home/venv/bin/pip" install --quiet --upgrade pip
"$home/venv/bin/pip" install --quiet "kokoro-onnx==0.6.0" "soundfile==0.13.1"

for file in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [[ ! -s "$home/models/$file" ]]; then
    echo "Downloading $file…"
    curl --fail --location --silent --show-error -o "$home/models/$file.part" "$release/$file"
    mv "$home/models/$file.part" "$home/models/$file"
  fi
done

ls -lh "$home/models"
"$home/venv/bin/python" -c "import kokoro_onnx, soundfile; print('kokoro-onnx ready')"
