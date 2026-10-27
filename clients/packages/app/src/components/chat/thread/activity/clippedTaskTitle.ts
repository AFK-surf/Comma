// The Router writes Task titles. A long one must not stretch the status bubble.
const TASK_TITLE_MAX_CHARACTERS = 40;

const graphemeSegmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });

// Clip by grapheme so a flag, skin-tone or ZWJ emoji is never cut in half.
export function clippedTaskTitle(title: string) {
  const characters = Array.from(
    graphemeSegmenter.segment(title.replace(/\s+/g, " ").trim()),
    ({ segment }) => segment
  );
  return characters.length > TASK_TITLE_MAX_CHARACTERS
    ? `${characters.slice(0, TASK_TITLE_MAX_CHARACTERS - 1).join("")}…`
    : characters.join("");
}
