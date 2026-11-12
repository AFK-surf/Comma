// A device type's case as Xcode keeps one (/Library/Developer/DeviceKit/Chrome/<id>.devicechrome), made by a test in a
// temporary folder: a grey case 100×200 points with a black opening 80×180 in its middle, a power button on its right, and
// the device type's framebuffer mask of that opening. Apple's own files are never in this repository.
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// A real one-page PDF of `w`×`h` points drawn by `content` (PDF operators), as sips can draw it.
function realPdf(w: number, h: number, content: string): Buffer {
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] /Contents 4 0 R >>`,
    `<< /Length ${content.length} >>\nstream\n${content}\nendstream`,
  ];
  let out = "%PDF-1.4\n";
  const at: number[] = [];
  objects.forEach((o, i) => {
    at.push(out.length);
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${at.map((n) => `${String(n).padStart(10, "0")} 00000 n \n`).join("")}`;
  out += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, "latin1");
}

/// The case as `phone8` under `root` (the chrome's folder), and a device type's bundle (`bundlePath`) whose resources
/// (`bundle`) have its mask, `Mask`.
export function compositeCase(): { root: string; bundle: string; bundlePath: string } {
  const root = mkdtempSync(join(tmpdir(), "sim-chrome-"));
  const dir = join(root, "phone8.devicechrome/Contents/Resources");
  const bundlePath = join(root, "iPhone 8.simdevicetype");
  const bundle = join(bundlePath, "Contents/Resources");
  mkdirSync(dir, { recursive: true });
  mkdirSync(bundle, { recursive: true });
  writeFileSync(join(dir, "Body.pdf"), realPdf(100, 200, "0.5 g 0 0 100 200 re f 0 g 10 10 80 180 re f"));
  writeFileSync(join(dir, "Power.pdf"), realPdf(4, 30, "0.3 g 0 0 4 30 re f"));
  writeFileSync(join(bundle, "Mask.pdf"), realPdf(240, 540, "0 g 0 0 240 540 re f"));
  writeFileSync(
    join(dir, "chrome.json"),
    JSON.stringify({
      images: { composite: "Body", devicePadding: { left: 0, right: 6, top: 0, bottom: 0 } },
      inputs: [{ name: "power", image: "Power", anchor: "right", align: "leading", offsets: { normal: { x: -2, y: 40 }, rollover: { x: 1, y: 40 } }, usagePage: 12, usage: 48 }],
    }),
  );
  return { root, bundle, bundlePath };
}
