export function twoPagePdf() {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 180] /Resources << /Font << /F1 7 0 R >> >> /Contents 4 0 R >>",
    "<< /Length 39 >>\nstream\nBT /F1 20 Tf 20 100 Td (Page One) Tj ET\nendstream",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 180] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
    "<< /Length 39 >>\nstream\nBT /F1 20 Tf 20 100 Td (Page Two) Tj ET\nendstream",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  ];
  let pdf = "%PDF-1.4\n";
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(pdf));
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(pdf);
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`)
    .join("");
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf);
}
