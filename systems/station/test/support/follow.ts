// What a fake program writes down (a fake adb's calls, a device's states), followed by a test that waits on it.
import { watch, writeFileSync } from "node:fs";

/// Calls `changed` after each change to these files (each made, empty, if it is not there yet), until the function it
/// returns is called. A change is told on the loop's next turn, not inside the watch's event: on macOS a file's watch
/// (kqueue) is one-shot and armed again only once its event's callback returns, so a test that looked inside it would
/// miss a write landing between its look and the re-arm and wait forever (two adb calls at once: 20 in 2,000 times
/// here, 0 told on the next turn). A directory's watch (FSEvents) misses writes too (5 in 2,000), so files are
/// watched, not their directory.
export function follow(paths: string[], changed: () => void): () => void {
  let told = false;
  const tell = () => {
    if (told) return;
    told = true;
    // ast-grep-ignore: ts-test-timer -- the loop's next turn, after the watch is armed again; not a time.
    setImmediate(() => {
      told = false;
      changed();
    });
  };
  const watchers = paths.map((path) => {
    writeFileSync(path, "", { flag: "a" });
    return watch(path, tell);
  });
  return () => {
    for (const watcher of watchers) watcher.close();
  };
}
