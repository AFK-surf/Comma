import { cx, FileIcon } from "@comma/ui";
import { driveFileKind, type DriveFile } from "./driveStore";
import { useDriveObjectUrl } from "./useDriveObjectUrl";

/**
 * An image file is its own icon: it shows its thumbnail — or its bytes,
 * when those are already here — where every other file shows the generic
 * glyph. An image with neither yet keeps the glyph until the list asks the
 * backend for a thumbnail; there is nothing to draw before that.
 */
export function DriveFileIcon({
  file,
  size = "md",
}: {
  file: DriveFile;
  /** `md` is the 24px list row; `sm` the 16px inline use in a dialog row. */
  size?: "md" | "sm";
}) {
  const thumbnailBlob =
    file.thumbnail ?? (driveFileKind(file) === "image" ? file.blob : undefined);
  const thumbnailUrl = useDriveObjectUrl(thumbnailBlob);
  const box = size === "sm" ? "size-4" : "size-6";
  if (thumbnailUrl) {
    return (
      <img
        alt=""
        className={cx("shrink-0 rounded-xs object-cover", box)}
        data-testid="drive-file-thumbnail"
        src={thumbnailUrl}
      />
    );
  }
  return <FileIcon aria-hidden className={cx("shrink-0 text-quaternary", box)} />;
}
