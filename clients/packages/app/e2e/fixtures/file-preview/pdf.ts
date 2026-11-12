export function twoPagePdf() {
  return pdfWithPages(["Page One", "Page Two"]);
}

/** A PDF of 240 x 180 pt pages, each with its label at x 20 on baseline 100. */
export function pdfWithPages(labels: string[]) {
  // Objects 1 and 2 are the catalog and the page tree; each page and its contents follow, then the font.
  const font = 3 + labels.length * 2;
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    `<< /Type /Pages /Kids [${labels.map((_, index) => `${3 + index * 2} 0 R`).join(" ")}] /Count ${labels.length} >>`,
    ...labels.flatMap((label, index) => {
      const stream = `BT /F1 20 Tf 20 100 Td (${label}) Tj ET`;
      return [
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 180] /Resources << /Font << /F1 ${font} 0 R >> >> /Contents ${4 + index * 2} 0 R >>`,
        `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`,
      ];
    }),
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
