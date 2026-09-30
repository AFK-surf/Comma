import { cx } from "@comma/ui";

/**
 * How much of a name's end stays visible when it has to lose its middle.
 * Twelve characters carry the extension plus the discriminating tail of the
 * common patterns — "at 10.47.png", "take-2.wav", "v3-final.mp4" — which is
 * what tells two similar names apart once their shared prefix is gone.
 */
const TAIL_CHARS = 12;

/** The extension as Finder would read it: none for dotfiles or a trailing dot. */
function extensionLength(name: string) {
  const dot = name.lastIndexOf(".");
  return dot <= 0 || dot === name.length - 1 ? 0 : name.length - dot;
}

/**
 * Splits a file name into the part that may ellipsize and the part that must
 * not. The tail is the last {@link TAIL_CHARS} characters, never more than
 * half the name (so a short name still loses its middle rather than its
 * start) and never less than the extension (which always survives).
 */
export function splitDriveFileName(name: string) {
  const tailLength = Math.max(
    extensionLength(name),
    Math.min(TAIL_CHARS, Math.floor(name.length / 2))
  );
  return {
    head: name.slice(0, name.length - tailLength),
    tail: name.slice(name.length - tailLength),
  };
}

/**
 * A file name that loses its middle rather than its end, the way Finder
 * truncates: "Screenshot 2026-08-29 at 10.47.png" narrows to
 * "Screenshot 20…at 10.47.png". No measurement is needed — the flex row
 * ellipsizes the head and the tail simply refuses to shrink. At full width the
 * two halves sit flush and read as one word.
 */
export function DriveFileName({
  className,
  name,
}: {
  className?: string;
  name: string;
}) {
  const { head, tail } = splitDriveFileName(name);
  return (
    <span
      className={cx("flex min-w-0 items-baseline overflow-hidden", className)}
      title={name}
    >
      {/* Only the head shrinks. Letting the tail give even a fraction of a
          pixel would ellipsize it too ("at 10.47.p…"), so it is rigid, and the
          head keeps a few characters plus its ellipsis; past that point the
          row clips the tail rather than trading it for a second ellipsis. */}
      {/* `whitespace-pre`, not nowrap: each half is its own flex item, so a
          space at the seam ("…08-29 " + "at 10.47.png") sits at a box edge
          and nowrap would collapse it into "08-29at". */}
      {/* The 4ch floor is what keeps an ellipsized head readable, but `ch` is
          the width of a zero — wider than four lowercase letters — so on a
          short head it would pad the seam open ("Sha  red"). A head that short
          has nothing to ellipsize, so it goes without the floor. */}
      <span
        className={cx(
          "overflow-hidden text-ellipsis whitespace-pre",
          head.length > TAIL_CHARS / 2 && "min-w-[4ch]"
        )}
      >
        {head}
      </span>
      {tail ? <span className="shrink-0 whitespace-pre">{tail}</span> : null}
    </span>
  );
}
