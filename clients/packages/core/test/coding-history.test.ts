import { describe, expect, it } from "vitest";
import { historyItems } from "../src/coding-history.ts";

const received = (text: string) => {
  const [item] = historyItems([{ at: null, kind: "user", text }]);
  if (item?.kind !== "received") throw new Error("not received");
  return item.text;
};

describe("a request's words in a coding session's history", () => {
  it("are the message's, without the tags the station wrapped it in", () => {
    expect(
      received(
        '<message via="task" connect="ember" thread="TASK/1.0" from="Ada (ada@x)" ts="1.1">\ncheck the build\n</message>'
      )
    ).toBe("check the build");
  });

  it("leave out the station's note on a thread that is new to the session", () => {
    expect(
      received(
        '(Thread TASK/1.0 had messages before you were brought in; read them with chat_history to="TASK/1.0" if they matter.)\n<message via="task" connect="ember" thread="TASK/1.0" from="Ada" ts="1.1">\ncheck the build\n</message>'
      )
    ).toBe("check the build");
  });

  it("join what several messages said", () => {
    expect(
      received(
        '<message via="web" from="A" ts="1">\none\n</message>\n<message via="web" from="B" ts="2">\ntwo\n</message>'
      )
    ).toBe("one\ntwo");
  });

  it("read past a > in an attribute", () => {
    expect(
      received(
        '<message via="slack" you="ember (<@U1>)" from="A" ts="1">\nhi\n</message>'
      )
    ).toBe("hi");
  });

  it("run to the end of a prompt the station cut short", () => {
    expect(
      received(
        '<message via="task" from="A" ts="1">\nlong words\n… (900 more characters)'
      )
    ).toBe("long words\n… (900 more characters)");
  });

  it("stay as they are in a prompt that carries no message", () => {
    for (const text of [
      "add retries",
      'what does - <message via="web" from="A">x</message> mean?',
      '<message via="web" from="A">never closed',
    ])
      expect(received(text)).toBe(text);
  });
});
