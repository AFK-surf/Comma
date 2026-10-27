#!/usr/bin/env python3
"""Check a recorded earlier-message reply flight for vertical overshoot.

Requires ffmpeg and ffprobe. Select a clip from swipe release through rest, before
closing the reply. Give the first line's rectangle at rest, in screen points:
  python3 check-reply-motion.py video.mp4 24.1 25.2 --text-rect 30 395 155 15
"""
import argparse
import json
import math
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("video")
parser.add_argument("start", type=float)
parser.add_argument("end", type=float)
parser.add_argument("--text-rect", type=int, nargs=4, required=True, metavar=("X", "Y", "W", "H"))
parser.add_argument("--screen-width", type=int, default=420)
args = parser.parse_args()
if not (0 <= args.start < args.end <= args.start + 3 and 0 < args.screen_width <= 1024):
    parser.error("Use a clip of at most 3 seconds and a screen width of at most 1024 points")
info = json.loads(subprocess.check_output([
    "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
    "-of", "json", args.video,
]))["streams"][0]
width = args.screen_width
height = round(info["height"] * width / info["width"])
x, resting, tw, th = args.text_rect
if not (0 <= x < x + tw <= width and 0 <= resting < resting + th <= height and height <= 4096):
    parser.error("Text rectangle must fit inside the scaled video")
# Decode from the beginning: seeking some simctl recordings produces stale keyframe
# contents even when the returned presentation timestamps are in the requested clip.
raw = subprocess.check_output([
    "ffmpeg", "-v", "error", "-i", args.video, "-vf",
    f"trim=start={args.start}:end={args.end},setpts=PTS-STARTPTS,fps=60,scale={width}:{height}",
    "-f", "rawvideo", "-pix_fmt", "gray", "-",
])
size = width * height
if len(raw) < size * 8 or len(raw) % size:
    parser.error("Need at least eight complete video frames")
frames = [memoryview(raw)[i:i + size] for i in range(0, len(raw), size)]

def crop(frame, y):
    return b"".join(frame[row * width + x:row * width + x + tw] for row in range(y, y + th))

reference = crop(frames[-1], resting)
n = len(reference)
reference_sum = sum(reference)
reference_variance = sum(v * v for v in reference) - reference_sum ** 2 / n
if reference_variance / n < 25:
    parser.error("The reference rectangle must contain readable text")
samples = []
for index, frame in enumerate(frames):
    best = (-1, resting)
    for y in range(max(0, resting - 20), min(height - th, resting + 30) + 1):
        pixels = crop(frame, y)
        total = sum(pixels)
        variance = sum(v * v for v in pixels) - total ** 2 / n
        if variance <= 0:
            continue
        dot = sum(a * b for a, b in zip(pixels, reference)) - total * reference_sum / n
        score = dot / math.sqrt(variance * reference_variance)
        if score > best[0]:
            best = (score, y)
    # Normalized correlation follows the same text through the backdrop crossfade.
    if best[0] >= 0.985:
        samples.append(best[1])
        print(f"{args.start + index / 60:.3f} y={best[1]} correlation={best[0]:.3f}")
if len(samples) < 8 or max(samples[-5:]) - min(samples[-5:]) > 1:
    parser.error("Need eight readable frames and a settled endpoint")
overshoot = max(samples) - resting
print(f"Maximum overshoot: {overshoot} pt")
if overshoot > 2:
    raise SystemExit("FAIL: Reply moves past its resting position and returns by more than 2 pt")
if len({y for y in samples if resting - 20 <= y < resting - 2}) < 2:
    raise SystemExit("FAIL: Need visible motion into the resting position, not only a fade or jump")
print("PASS")
