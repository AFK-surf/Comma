import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { lazyBrandMark } from "../brandMarks";

describe("brand marks", () => {
  // Hosts answer several logos together, so one missing chunk must not reject the rest.
  it("settles with an empty logo when its chunk cannot load", async () => {
    const Missing = lazyBrandMark(() => Promise.reject(new Error("chunk removed")));

    await expect(Missing.preload()).resolves.toBeUndefined();
    expect(renderToStaticMarkup(<Missing />)).toBe("");
  });
});
