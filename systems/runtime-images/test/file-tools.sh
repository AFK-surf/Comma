#!/usr/bin/env sh
set -eu

# Run against a locally built Cloud VM image (the Cloudflare Sandbox or the
# station image), without network. Each preinstalled file tool must handle the
# kind of file a Task receives: a phone video, a PDF with Chinese text, an
# archive, and Office documents.
image="${1:?usage: file-tools.sh IMAGE}"
docker run --rm --network none --entrypoint sh "$image" -eu -c '
cd "$(mktemp -d)"

# A 2 s HEVC video with an AAC track, as a phone records it.
ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc=size=320x240:rate=30:duration=2 \
  -f lavfi -i sine=frequency=440:duration=2 -c:v libx265 -tag:v hvc1 -c:a aac -shortest video.mp4
ffprobe -v error -show_entries stream=codec_type -of csv=p=0 video.mp4 | sort | tr "\n" " " | grep -q "audio video"
ffmpeg -hide_banner -loglevel error -i video.mp4 -vf fps=1 -frames:v 2 frame%02d.jpg
ffmpeg -hide_banner -loglevel error -i video.mp4 -vn -ac 1 -ar 16000 audio.wav
test -s frame01.jpg && test -s frame02.jpg && test -s audio.wav
file --brief --mime-type video.mp4 | grep -q "^video/mp4$"
echo "ffmpeg: read a phone video, extracted frames and 16 kHz audio"

# A PDF with Chinese text from reportlab; poppler renders it with the
# preinstalled Noto CJK fonts.
fc-list :lang=zh family | grep -q "Noto Sans CJK"
python3 - <<PY
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
pdfmetrics.registerFont(UnicodeCIDFont("STSong-Light"))
c = canvas.Canvas("doc.pdf")
c.setFont("STSong-Light", 18)
c.drawString(72, 720, "合同编号 A-42")
c.save()
PY
pdftotext doc.pdf - | grep -q "合同编号 A-42"
pdftoppm -png -r 50 doc.pdf page && test -s page-1.png
python3 - <<PY
import pdfplumber, pypdf
with pdfplumber.open("doc.pdf") as pdf:
    assert "合同编号 A-42" in pdf.pages[0].extract_text()
assert "合同编号 A-42" in pypdf.PdfReader("doc.pdf").pages[0].extract_text()
PY
echo "pdf: poppler, pdfplumber and pypdf read Chinese text"

# Archives: zip, 7z and tar, each opened by the tool a Task reaches for.
mkdir in && echo hello >in/a.txt
(cd in && zip -q ../a.zip a.txt && 7z a -bd -bso0 ../a.7z a.txt && tar -czf ../a.tar.gz a.txt)
for archive in a.zip a.7z a.tar.gz; do
  rm -rf out && mkdir out && bsdtar -xf "$archive" -C out && cmp in/a.txt out/a.txt
done
rm -rf out && unzip -q a.zip -d out && cmp in/a.txt out/a.txt
rm -rf out && 7z x -bd -bso0 -oout a.7z && cmp in/a.txt out/a.txt
echo "archives: bsdtar, unzip and 7z extract zip, 7z and tar.gz"

# Office documents written and read back.
python3 - <<PY
import docx, openpyxl, pptx
from PIL import Image
d = docx.Document(); d.add_paragraph("季度报告"); d.save("a.docx")
assert docx.Document("a.docx").paragraphs[0].text == "季度报告"
wb = openpyxl.Workbook(); wb.active["A1"] = 42; wb.save("a.xlsx")
assert openpyxl.load_workbook("a.xlsx").active["A1"].value == 42
p = pptx.Presentation(); s = p.slides.add_slide(p.slide_layouts[5]); s.shapes.title.text = "Q3"; p.save("a.pptx")
assert pptx.Presentation("a.pptx").slides[0].shapes.title.text == "Q3"
assert Image.open("frame01.jpg").size == (320, 240)
PY
echo "office: python-docx, openpyxl, python-pptx and Pillow"
'
