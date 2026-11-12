/// <reference types="vite/client" />

import { cx } from "../utils";
import { fileNameExtension, fileTypeCandidates, mimeTypeLabel } from "./fileType";

// Each type is a colored artwork file, not a glyph. The artwork ships with the bundle (about 17 KB gzipped for all
// types) and draws inline, so a card shows its icon in its first frame, with no request to wait for. Inline, the
// page inherits the theme's custom properties (file-type-icon.css), where an `<img>` would not; the badge keeps its
// color.
const artworkByType: Record<string, string> = Object.fromEntries(
  Object.entries(
    import.meta.glob<string>("./assets/*.svg", {
      eager: true,
      import: "default",
      query: "?raw",
    })
  ).map(([path, svg]) => [
    path.slice("./assets/".length, -".svg".length),
    // The drawing inside the file's `<svg>` root, which the component draws itself.
    svg.slice(svg.indexOf(">") + 1, svg.lastIndexOf("</svg>")),
  ])
);

/** The types that have their own artwork, `none` (the blank document) included. */
export const fileTypesWithIcons = Object.keys(artworkByType);

/** MIME subtypes that spell a type with artwork another way. */
const typeAliases: Record<string, string> = {
  javascript: "js",
  markdown: "md",
  typescript: "ts",
};

interface FileTypeSource {
  fileName: string;
  mimeType?: string | undefined;
}

/** The first of the file's candidate types that has artwork. */
const artworkType = (file: FileTypeSource) =>
  fileTypeCandidates(file)
    .map((type) => typeAliases[type] ?? type)
    .find((type) => Object.hasOwn(artworkByType, type));

/**
 * The type a file card names: a caller's label, then the type its artwork shows, so the label and the icon agree;
 * a type without artwork falls back to the MIME type, then the extension.
 */
export const resolveFileType = ({
  typeLabel,
  ...file
}: FileTypeSource & { typeLabel?: string | undefined }) => {
  if (typeLabel?.trim()) return typeLabel.trim().toUpperCase();
  return (
    artworkType(file)?.toUpperCase() ??
    mimeTypeLabel(file.mimeType) ??
    fileNameExtension(file.fileName) ??
    "FILE"
  );
};

export interface FileTypeIconProps {
  className?: string;
  fileName: string;
  mimeType?: string | undefined;
}

/** A file's type as its colored document artwork; a type without artwork shows the blank document. */
export const FileTypeIcon = ({ className, fileName, mimeType }: FileTypeIconProps) => {
  const type = artworkType({ fileName, mimeType }) ?? "none";
  return (
    <svg
      aria-hidden
      className={cx("comma-file-type-icon shrink-0", className)}
      data-file-type={type}
      data-testid="file-type-icon"
      fill="none"
      // The bundle's own artwork files, never input.
      dangerouslySetInnerHTML={{ __html: artworkByType[type]! }}
      viewBox="0 0 24 24"
    />
  );
};
