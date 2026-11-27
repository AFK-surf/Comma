import { describe, expect, it } from "vitest";
import { workerStarting } from "../workerStarting";

const brief = { brief: true as const };
const reply = {};

describe("a Task that reads as started before its Worker reports", () => {
  it("holds from the brief until the Worker's first message", () => {
    expect(
      workerStarting({ inProgress: true, messages: [brief], place: { kind: "salix" } })
    ).toBe(true);
    expect(
      workerStarting({
        inProgress: true,
        messages: [brief, reply],
        place: { kind: "salix" },
      })
    ).toBe(false);
  });

  it("holds from a request the Router brought into the Task until the Worker answers", () => {
    const request = { routerRequest: true as const };
    expect(
      workerStarting({
        inProgress: true,
        messages: [brief, reply, request],
        place: { kind: "salix" },
      })
    ).toBe(true);
    expect(
      workerStarting({
        inProgress: true,
        messages: [brief, reply, request, reply],
        place: { kind: "salix" },
      })
    ).toBe(false);
  });

  it("ends with the Task", () => {
    expect(
      workerStarting({ inProgress: false, messages: [brief], place: undefined })
    ).toBe(false);
  });

  it("follows the sandbox: starting holds it, a sandbox that is down ends it", () => {
    expect(
      workerStarting({
        inProgress: true,
        messages: [brief, reply],
        place: { kind: "sandbox", state: "starting" },
      })
    ).toBe(true);
    expect(
      workerStarting({
        inProgress: true,
        messages: [brief],
        place: { kind: "sandbox", state: "failed" },
      })
    ).toBe(false);
  });
});
