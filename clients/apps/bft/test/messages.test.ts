import { describe, expect, it } from "vitest";
import { messagesFor } from "../src/messages";

describe("messagesFor", () => {
  it("serves Simplified Chinese for zh_Hans and English otherwise", () => {
    expect(messagesFor("zh_Hans").overview.title).toBe("概览");
    expect(messagesFor("en").overview.title).toBe("Overview");
    expect(messagesFor(undefined).overview.title).toBe("Overview");
    expect(messagesFor("fr").overview.title).toBe("Overview");
    expect(messagesFor("en").health.title).toBe("Health");
    expect(messagesFor("zh_Hans").health.title).toBe("运行状况");
  });
});
