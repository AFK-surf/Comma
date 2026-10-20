#!/usr/bin/env python3
"""Generate the app's original one-second 440/480 Hz PCM ringback asset."""

import math
from pathlib import Path
import struct
import wave


def generate(destination: Path) -> None:
    sample_rate = 16_000
    frames = sample_rate
    fade_frames = sample_rate * 20 // 1_000
    pcm = bytearray()
    for i in range(frames):
        envelope = min(1.0, i / fade_frames, (frames - 1 - i) / fade_frames)
        signal = sum(math.sin(2 * math.pi * hz * i / sample_rate) for hz in (440, 480))
        pcm.extend(struct.pack("<h", round(0.22 * 32767 * signal * envelope)))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm)


if __name__ == "__main__":
    generate(Path(__file__).resolve().parents[1] / "app/src/main/res/raw/ringback.wav")
