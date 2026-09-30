# Image Conversion Reference

Use Python with Pillow for all image format conversions. For install packages, see the python skill.

## Workflow

1. **Read source image** with metadata preservation
2. **Choose resampling filter** based on operation:
   - Downscaling: `Image.LANCZOS` (best quality, prevents aliasing)
   - Upscaling: `Image.LANCZOS` or `Image.BICUBIC`
   - No resize: No filter needed
3. **Handle color modes** appropriately:
   - JPEG: Convert to RGB (no alpha)
   - PNG: Keep RGBA if transparency exists
   - WebP: Supports both RGB and RGBA
4. **Set format-specific quality parameters**
5. **Preserve EXIF/metadata** when possible

## Example: Basic conversion

```python
from PIL import Image

def convert_image(src, dst, quality=95):
    img = Image.open(src)

    # Handle transparency for JPEG
    if dst.lower().endswith(('.jpg', '.jpeg')) and img.mode == 'RGBA':
        background = Image.new('RGB', img.size, (255, 255, 255))
        background.paste(img, mask=img.split()[3])
        img = background

    # Preserve EXIF if available
    exif = img.info.get('exif')
    save_kwargs = {'quality': quality}
    if exif:
        save_kwargs['exif'] = exif

    img.save(dst, **save_kwargs)
```

## Example: Resize with high quality

```python
from PIL import Image

def resize_image(src, dst, size, quality=95):
    img = Image.open(src)
    # LANCZOS prevents color banding and aliasing
    img = img.resize(size, Image.LANCZOS)
    img.save(dst, quality=quality)
```

## Quality Settings by Format

| Format | Quality Range  | Recommended      |
| ------ | -------------- | ---------------- |
| JPEG   | 1-100          | 85-95            |
| WebP   | 1-100          | 80-90            |
| PNG    | N/A (lossless) | compress_level=6 |
| AVIF   | 1-100          | 75-85            |

## Guardrails

- **Do**: Use `Image.LANCZOS` for any resize operation
- **Do**: Convert RGBA to RGB before saving as JPEG
- **Do**: Preserve EXIF data when converting between formats that support it
- **Don't**: Use `Image.NEAREST` or `Image.BILINEAR` for final output (causes pixelation/banding)
- **Don't**: Save JPEG with quality below 80 unless explicitly requested (visible artifacts)

## Dependencies

```bash
apt install python3-pil python3-pillow-heif
# For AVIF support
pip install --user pillow-avif-plugin
```

## Troubleshooting

- **Color banding**: Use LANCZOS resampling, increase bit depth
- **Transparency lost**: Check target format supports alpha
- **File too large**: Reduce quality parameter, try WebP
