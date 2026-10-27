import {
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { keepAppLocalizations } from "../scripts/app-localizations";

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true });
});

describe("keepAppLocalizations", () => {
  it("leaves no localization empty, and keeps what one already holds", () => {
    const resources = mkdtempSync(join(tmpdir(), "comma-app-localizations-"));
    roots.push(resources);
    for (const locale of ["de", "zh_CN", "fr"])
      mkdirSync(join(resources, `${locale}.lproj`));
    writeFileSync(join(resources, "fr.lproj", "Localizable.strings"), '"a" = "b";\n');
    writeFileSync(join(resources, "app.asar"), "");

    keepAppLocalizations(resources);

    expect(readdirSync(join(resources, "de.lproj"))).toEqual(["InfoPlist.strings"]);
    expect(readdirSync(join(resources, "zh_CN.lproj"))).toEqual(["InfoPlist.strings"]);
    expect(readdirSync(join(resources, "fr.lproj"))).toEqual(["Localizable.strings"]);
    expect(
      readFileSync(join(resources, "de.lproj", "InfoPlist.strings"), "utf8")
    ).toMatch(/^\/\*.*\*\/\n$/);
  });
});
