// A CLI login in a Task's sandbox: its command runs in a terminal here, and the person's step is on a card in the Task.
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { Logins } from "../src/logins/tool.ts";
import { Fibers } from "../src/ops/fibers.ts";

const root = mkdtempSync(join(tmpdir(), "logins-"));
const home = join(root, "home");
const bin = join(root, "fake-cli");
const go = join(root, "go");
const previous = process.env.HOME;

// Says a device code and a page, as gh does; once the person has confirmed, writes its login and ends.
const CLI = `#!/bin/sh
echo "First copy your one-time code: ABCD-1234"
echo "Open this URL to continue in your web browser: https://example.test/login/device"
while [ ! -e "${go}" ]; do sleep 0.05; done
mkdir -p "$HOME/.config/fake-cli"
echo token-from-login > "$HOME/.config/fake-cli/auth"
echo "Logged in"
`;

before(() => {
  mkdirSync(home);
  writeFileSync(bin, CLI);
  chmodSync(bin, 0o755);
  process.env.HOME = home;
});

after(() => {
  process.env.HOME = previous;
  rmSync(root, { recursive: true, force: true });
});

function setup(personMs?: number, running = true) {
  const told: string[] = [];
  let heard: (text: string) => void = () => {};
  let carded: () => void = () => {};
  const cardUp = new Promise<void>((resolve) => (carded = resolve));
  const cards: Record<string, unknown>[] = [];
  let kept: string | null = null;
  const logins = new Logins(
    {
      offered: () => true,
      call: async (_session, tool, args) => {
        assert.equal(tool, "oauth.login_card");
        cards.push(args);
        carded();
        // The person confirms once the card is up, unless the test says when.
        if (args.ended === undefined && personMs === undefined) writeFileSync(go, "");
        return { content: "{}" };
      },
      keep: async (_session, _program, archive) => {
        kept = archive;
        return { kept: true };
      },
      restore: async () => (kept === null ? {} : { archive: kept }),
      running: () => running,
      notify: async (_session, text) => {
        told.push(text);
        heard(text);
      },
    },
    new Fibers("test"),
    join(root, "data"),
    personMs,
  );
  const notified = new Promise<string>((resolve) => (heard = resolve));
  return { logins, cards, cardUp, kept: () => kept, told, notified, tool: logins.tools()[0]! };
}

test("a device-code login puts up a card, waits for the person, and keeps what it wrote for the next sandbox", async () => {
  rmSync(go, { force: true });
  const { logins, cards, kept, tool, told: notices } = setup();
  const told = await tool.run("s1", { command: [bin], reason: "push code", fresh: true });

  assert.equal(cards[0]!.code, "ABCD-1234");
  assert.equal(cards[0]!.url, "https://example.test/login/device");
  assert.equal(cards[0]!.reason, "push code");
  assert.equal(cards.at(-1)!.ended, "done", told);
  assert.match(told, /It finished/);
  // What its agent is told holds neither the code nor the page.
  assert.doesNotMatch(told, /ABCD-1234|example\.test/);
  assert.notEqual(kept(), null);
  // Its call said how it ended, so nothing else tells its agent.
  assert.deepEqual(notices, []);

  // A new sandbox: the disk is gone, and the next login of that person puts it back, with no card.
  rmSync(join(home, ".config"), { recursive: true });
  const before = cards.length;
  const again = await tool.run("s2", { command: [bin], reason: "push code" });
  assert.match(again, /put back/);
  assert.equal(cards.length, before);
  assert.equal(readFileSync(join(home, ".config/fake-cli/auth"), "utf8"), "token-from-login\n");
  logins.close();
});

test("a person who takes longer than the call still ends the login: its card closes, its files are kept, its agent is told", async () => {
  rmSync(go, { force: true });
  const { logins, cards, kept, notified, tool } = setup(50);
  const first = await tool.run("s3", { command: [bin], reason: "push code", fresh: true });
  assert.match(first, /you are told when the login ends/);
  assert.equal(cards.at(-1)!.ended, undefined);

  writeFileSync(go, "");
  assert.match(await notified, /It finished/);
  assert.equal(cards.at(-1)!.ended, "done");
  assert.notEqual(kept(), null);
  logins.close();
});

test("an agent that ended its turn with its call still open is told when the login ends", async () => {
  rmSync(go, { force: true });
  const { logins, cardUp, notified, tool } = setup(60_000, false);
  const call = tool.run("s4", { command: [bin], reason: "push code", fresh: true });
  // Wait for the card, as a person would see it.
  await cardUp;
  writeFileSync(go, "");
  assert.match(await notified, /It finished/);
  await call;
  logins.close();
});
