import { describe, expect, it } from "vitest";
import { findNativeSessionAdmissionViolations } from "../check-foundation-kernel-lib.mjs";

describe("check-foundation-kernel native Session admission", () => {
  it("requires exhaustive classifications and rationale only for local-only leaves", () => {
    expect(
      findNativeSessionAdmissionViolations([
        {
          id: "native.info",
          sessionAdmission: "local_only",
          sessionAdmissionRationale: "Reads local metadata only.",
        },
        { id: "session.state", sessionAdmission: "lifecycle" },
        { id: "chat.state", sessionAdmission: "required" },
      ])
    ).toEqual([]);

    expect(
      findNativeSessionAdmissionViolations([
        { id: "native.info", sessionAdmission: "local_only" },
        { id: "session.state", sessionAdmission: "sometimes" },
        {
          id: "chat.state",
          sessionAdmission: "required",
          sessionAdmissionRationale: "This rationale is invalid here.",
        },
      ])
    ).toEqual([
      "native.info local_only is missing a rationale",
      "session.state has invalid sessionAdmission sometimes",
      "chat.state declares a local-only rationale with required",
    ]);
  });
});
