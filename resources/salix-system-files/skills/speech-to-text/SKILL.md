---
name: speech-to-text
description: Transcribe audio or video files with Comma audio.transcribe.
metadata:
  displayName: Speech to Text
  icon: text.bubble
  color: teal
  visibility: visible
  placeholder: Upload an audio file to transcribe
---

# Speech to Text

Call `audio.transcribe` with the absolute path of an agent-visible audio or video file.
The tool accepts files up to 30 MiB and returns the transcript artifact path, duration, and chunk count.
Read that artifact to summarize or quote the recording. Deliver the artifact when the user requests the full transcript.
