import type { ReactNode } from "react";

/**
 * A sentence with a filesystem path in it, where the path reads as one token
 * in the primary ink:
 * a line ending moves the whole path down rather than splitting "~/Comma
 * Drive/Folder" from "A". Offering a break after each separator was tried and
 * rejected — the browser takes the earliest break that fits, so the path
 * split at a slash even when it would have fit whole on the next line.
 */
export function DriveInlinePath({
  path,
  sentence,
}: {
  path: string;
  sentence: string;
}): ReactNode {
  const at = sentence.indexOf(path);
  if (at === -1) return sentence;
  return (
    <>
      {sentence.slice(0, at)}
      {/* The path is the one concrete thing in the sentence, so it carries
          the primary ink while the sentence around it stays description grey. */}
      <span className="whitespace-nowrap text-primary">{path}</span>
      {sentence.slice(at + path.length)}
    </>
  );
}
