import { describe, expect, it } from "vitest";
import { workerMeshGradientStyle } from "../workerAvatar";

describe("workerMeshGradientStyle", () => {
  it("maps one Worker identity to the same mesh on every render", () => {
    expect(workerMeshGradientStyle("actor_worker_alpha")).toEqual(
      workerMeshGradientStyle("actor_worker_alpha")
    );
  });

  it("maps distinct Worker identities to distinct visual fingerprints", () => {
    const identities = Array.from({ length: 128 }, (_, index) =>
      JSON.stringify(workerMeshGradientStyle(`actor_worker_${index}`))
    );

    expect(new Set(identities).size).toBe(identities.length);
  });
});
