import { describe, expect, it } from "vitest";
import { LAUNCHER_COMPOSE_MAX_CHARS, parseLauncherLink } from "../launcher-link";

const challenge = "c".repeat(43);
const parse = (url: string) => parseLauncherLink(url, "comma-staging");

describe("launcher link", () => {
  it("opens Home, a Task, or Home with words in its draft", () => {
    expect(parse("comma-staging://home")).toEqual({ kind: "route", route: "/" });
    expect(parse("comma-staging://task/wsp_1/grp_1/cnv_1")).toEqual({
      kind: "route",
      route: "/inbox/wsp_1/grp_1/cnv_1",
    });
    expect(
      parse(
        "comma-staging://home/compose?text=Book%20a%20table%20%26%20taxi&entry=raycast"
      )
    ).toEqual({
      kind: "route",
      route: `/?draft=${encodeURIComponent('"Book a table & taxi"')}&entry=raycast`,
    });
    // Words that read as a number or a boolean stay words.
    expect(parse("comma-staging://home/compose?text=42")).toEqual({
      kind: "route",
      route: `/?draft=${encodeURIComponent('"42"')}`,
    });
  });

  it("asks to connect Raycast only with a well-formed challenge", () => {
    expect(parse(`comma-staging://connect/raycast?challenge=${challenge}`)).toEqual({
      kind: "connectRaycast",
      challenge,
    });
    expect(parse("comma-staging://connect/raycast?challenge=short")).toBeUndefined();
    expect(parse("comma-staging://connect/raycast")).toBeUndefined();
  });

  it("is nothing for another scheme, another shape, or more than it may carry", () => {
    for (const url of [
      "comma://home",
      "https://home/compose?text=hi",
      "comma-staging://home/compose",
      "comma-staging://home/compose?text=%20",
      "comma-staging://home/compose?text=hi&entry=telegram",
      "comma-staging://home/compose?text=hi&send=1",
      "comma-staging://home/compose?text=hi&text=again",
      `comma-staging://home/compose?text=${"a".repeat(LAUNCHER_COMPOSE_MAX_CHARS + 1)}`,
      "comma-staging://home/settings",
      "comma-staging://user@home",
      "comma-staging://task/wsp_1/grp_1",
      "comma-staging://task/wsp_1/grp_1/cnv%2F1",
      `comma-staging://connect/raycast?challenge=${challenge}&next=1`,
      "not a url",
    ]) {
      expect(parse(url)).toBeUndefined();
    }
  });
});
