"""Kokoro speech server for Jarvis Orb: the free on-device voice used when ElevenLabs is out.

Runs inside the private environment that scripts/setup-kokoro.sh creates. Loads the model once,
then answers JSON lines on stdin with JSON lines on stdout:

  in:  {"id": "1", "text": "Hello.", "voice": "bm_george", "speed": 1.0}
  out: {"id": "1", "wav": "<base64 16-bit WAV>"}   or   {"id": "1", "error": "..."}

The first line written is {"ready": true}. Exits when stdin closes.
"""

import base64
import io
import json
import os
import sys

import soundfile
from kokoro_onnx import Kokoro

HOME = os.path.expanduser("~/Library/Application Support/JarvisOrb/kokoro/models")


def reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def main():
    kokoro = Kokoro(os.path.join(HOME, "kokoro-v1.0.onnx"), os.path.join(HOME, "voices-v1.0.bin"))
    reply({"ready": True})
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        rid = request.get("id")
        try:
            voice = request.get("voice") or "bm_george"
            # British voices (b*) read best with British pronunciation.
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, rate = kokoro.create(request["text"], voice=voice, speed=float(request.get("speed") or 1.0), lang=lang)
            buffer = io.BytesIO()
            soundfile.write(buffer, samples, rate, format="WAV", subtype="PCM_16")
            reply({"id": rid, "wav": base64.b64encode(buffer.getvalue()).decode("ascii")})
        except Exception as error:  # report and keep serving
            reply({"id": rid, "error": str(error)})


if __name__ == "__main__":
    main()
