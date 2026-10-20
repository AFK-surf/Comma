import { describe, expect, it } from "vitest";
import {
  ATTACHED_FILES_HEADER,
  ATTACHED_ONLY_TEXT,
  composeMessageWithAttachedTexts,
  composeMessageWithAttachments,
  composeMessageWithQuotes,
} from "../protocol";
import { decodeUserMessage } from "../userMessageText";

describe("a person's message as shown", () => {
  it("reads the quotes, the words, the attached texts and files back out, leaving the inspected element's context to the agent of the wire text", () => {
    const texts = [
      {
        source: "Linear",
        text: "Help me review COMMA-1\n\nhttps://linear.app/c/COMMA-1",
      },
      { text: "> already quoted" },
    ];
    // The element's screenshot uploads after the message is written, so its file trails the element.
    const wire = composeMessageWithAttachments(
      `${composeMessageWithQuotes(
        composeMessageWithAttachedTexts("What does this mean?", texts),
        ["The plan\n\nslips"]
      )}

<user-reminder>
<browser-element-inspection id="inspection-1" />
<browser_element_context>
Page URL: https://example.com/docs
Selector: main > button
Tag: button
</browser_element_context>
</user-reminder>`,
      [{ name: "inspected-element.png", path: "/uploads/1-inspected-element.png" }]
    );
    expect(decodeUserMessage(wire)).toEqual({
      body: "What does this mean?",
      quotes: ["The plan\n\nslips"],
      texts,
      files: [
        { name: "inspected-element.png", path: "/uploads/1-inspected-element.png" },
      ],
    });
  });

  it("shows an attached text sent alone, and leaves a header without quoted lines as words", () => {
    expect(
      decodeUserMessage(
        composeMessageWithAttachedTexts("", [{ text: "Help me reply" }])
      )
    ).toEqual({ body: "", quotes: [], texts: [{ text: "Help me reply" }], files: [] });
    const prose = "Attached text from Linear:\nsee the issue";
    expect(decodeUserMessage(prose)).toEqual({ body: prose, quotes: [], files: [] });
  });

  it("shows files sent alone without the placeholder text, and leaves a malformed list as words", () => {
    expect(
      decodeUserMessage(
        composeMessageWithAttachments("", [{ name: "a.png", path: "/uploads/a.png" }])
      )
    ).toEqual({
      body: "",
      quotes: [],
      files: [{ name: "a.png", path: "/uploads/a.png" }],
    });
    const malformed = `${ATTACHED_ONLY_TEXT}\n\n${ATTACHED_FILES_HEADER}\n- a.png (somewhere)`;
    expect(decodeUserMessage(malformed)).toEqual({
      body: malformed,
      quotes: [],
      files: [],
    });
  });

  it("names a command sent alone, and leaves a command within prose, code or a skill mention as words", () => {
    expect(decodeUserMessage("<salix-command>compact</salix-command>").command).toBe(
      "compact"
    );
    expect(
      decodeUserMessage("<salix-command>cat /Notes/Q3 Plan.md</salix-command>").command
    ).toBe("cat /Notes/Q3 Plan.md");
    expect(
      decodeUserMessage(" <salix-command>\n status \n</salix-command> ").command
    ).toBe("status");
    for (const text of [
      "Use <salix-command>help</salix-command>",
      "`<salix-command>help</salix-command>`",
      "<salix-command>status",
      "/code-review",
      "<salix-command><nested></salix-command>",
    ])
      expect(decodeUserMessage(text)).toEqual({ body: text, quotes: [], files: [] });
  });
});
