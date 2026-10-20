// The trees the core makes of the Markdown the Android app's tests show (`ChatMessage.markdown`), so those tests read
// the core's own parse and the app never parses Markdown itself.
//
//   node --experimental-strip-types scripts/android-markdown-fixtures.ts
//
// Each key of apps/android/app/src/test/resources/markdown/trees.json is a message's text, or `parts:` and its parts as
// JSON (a message with Task chips or cards in it); its value is made again here (a new key goes in with any value,
// null say, and gets its tree).
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { messageMarkdown } from "../src/markdown/message.ts";

const file = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../../apps/android/app/src/test/resources/markdown/trees.json"
);
const kept = JSON.parse(readFileSync(file, "utf8")) as Record<string, unknown>;
const trees = Object.fromEntries(
  Object.keys(kept)
    .toSorted()
    .map((key) => [
      key,
      messageMarkdown(
        key.startsWith("parts:")
          ? (JSON.parse(key.slice("parts:".length)) as Parameters<
              typeof messageMarkdown
            >[0])
          : [{ kind: "markdown", text: key }]
      ),
    ])
);
writeFileSync(file, `${JSON.stringify(trees, null, 1)}\n`);
