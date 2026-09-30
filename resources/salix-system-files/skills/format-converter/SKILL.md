---
name: format-converter
description: Convert files between formats. Use for Document conversion, Image format conversion, and Audio/Video format conversion.
metadata:
  displayName: Convert Master
  icon: play.tv.fill
  color: pink
  placeholder: Upload a file to convert
---

# File Format Conversion

## Execution Environment

Run format conversion commands in the Group's Cloud VM (`cloud-vm`) by default. Find its device and environment IDs with `device.list` and `device.get`. Use `env.copy` to copy input files into it, including files from the user's computer, and to copy the results back to VFS. Run conversion commands on the user's own computer only when the user asks for that. If the Group has no connected Cloud VM, ask the user which connected computer to use.

## Workflow Decision

| Task                    | Tool            | Reference                                             |
| ----------------------- | --------------- | ----------------------------------------------------- |
| Document conversion     | pandoc          | [document-convert.md](references/document-convert.md) |
| Image format conversion | Python (Pillow) | [image-convert.md](references/image-convert.md)       |
| Audio/video conversion  | ffmpeg          | [av-convert.md](references/av-convert.md)             |

## Quick Reference

### Document Conversion

Read [`references/document-convert.md`](references/document-convert.md) for detailed workflow.

Key points:

- PDF generation: ALWAYS use `--pdf-engine=weasyprint` (lightweight, auto-installed)
- Pandoc supports markdown, HTML, PDF, DOCX, LaTeX, and many more formats

```bash
# PDF from markdown
pandoc input.md -o output.pdf --pdf-engine=weasyprint

# DOCX from HTML
pandoc input.html -o output.docx
```

### Image Conversion

Read [`references/image-convert.md`](references/image-convert.md) for detailed workflow.

Key points:

- Use `Image.LANCZOS` for any resize operation (prevents color banding/aliasing)
- Convert RGBA to RGB before saving as JPEG
- Preserve EXIF metadata when possible

```bash
# Dependencies
apt install python3-pil python3-pillow-heif
```

### Audio/Video Conversion

Read [`references/av-convert.md`](references/av-convert.md) for detailed workflow.

Key points:

- Use `-c copy` when only changing container format (fast, lossless)
- Use `flags=lanczos` in scale filters for best quality
- Use `-crf` for quality-based encoding

Check `ffmpeg` available before using it.
