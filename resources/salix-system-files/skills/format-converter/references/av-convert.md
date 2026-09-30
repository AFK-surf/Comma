# Audio/Video Conversion Reference

Use ffmpeg for all audio and video format conversions.

## Basic Syntax

```bash
ffmpeg -i input.ext [options] output.ext
```

## Common Video Conversions

```bash
# MP4 (H.264) - universal compatibility
ffmpeg -i input.mkv -c:v libx264 -crf 23 -preset medium -c:a aac -b:a 192k output.mp4

# WebM (VP9) - web optimized
ffmpeg -i input.mp4 -c:v libvpx-vp9 -crf 30 -b:v 0 -c:a libopus -b:a 128k output.webm

# MKV - container change only (fast)
ffmpeg -i input.mp4 -c copy output.mkv

# GIF from video
ffmpeg -i input.mp4 -vf "fps=10,scale=320:-1:flags=lanczos" -loop 0 output.gif
```

## Common Audio Conversions

```bash
# MP3 (high quality)
ffmpeg -i input.wav -c:a libmp3lame -q:a 2 output.mp3

# AAC
ffmpeg -i input.wav -c:a aac -b:a 256k output.m4a

# FLAC (lossless)
ffmpeg -i input.wav -c:a flac output.flac

# OGG Vorbis
ffmpeg -i input.mp3 -c:a libvorbis -q:a 6 output.ogg
```

## Quality Control

| Codec  | Parameter | Range | Recommended          |
| ------ | --------- | ----- | -------------------- |
| H.264  | -crf      | 0-51  | 18-23 (lower=better) |
| H.265  | -crf      | 0-51  | 22-28                |
| VP9    | -crf      | 0-63  | 30-35                |
| MP3    | -q:a      | 0-9   | 0-2 (lower=better)   |
| Vorbis | -q:a      | 0-10  | 5-7 (higher=better)  |

## Extract Audio from Video

```bash
# Extract as MP3
ffmpeg -i video.mp4 -vn -c:a libmp3lame -q:a 2 audio.mp3

# Extract as original codec (fast)
ffmpeg -i video.mp4 -vn -c:a copy audio.aac
```

## Resize Video

```bash
# Scale to 1080p, maintain aspect ratio
ffmpeg -i input.mp4 -vf "scale=-1:1080:flags=lanczos" -c:a copy output.mp4

# Scale to width 1280, auto height
ffmpeg -i input.mp4 -vf "scale=1280:-2:flags=lanczos" -c:a copy output.mp4
```

## Guardrails

- **Do**: Use `-c copy` when only changing container format (fast, lossless)
- **Do**: Use `flags=lanczos` in scale filters for best quality
- **Do**: Use `-crf` for quality-based encoding (consistent quality)
- **Don't**: Re-encode unnecessarily (quality loss each time)
- **Don't**: Use very low CRF values (huge files, diminishing returns)
- **Only if**: Use `-preset veryslow` when file size is critical and time is not

## Dependencies

```bash
apt install ffmpeg
```

## Troubleshooting

- **No audio**: Add `-c:a` codec specification
- **File won't play**: Try `-c:v libx264 -c:a aac` for maximum compatibility
- **Sync issues**: Add `-async 1` or use `-vsync cfr`
