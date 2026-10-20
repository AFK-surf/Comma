import { describe, expect, it } from "vitest";
import { enrollmentLabel } from "../src/drive.ts";

const nk = "ybndrfg8ejkmcpqxot1uwisza345h769ybndrfg8ejkmcpqxot1u";

// Enrolling a node in the Workspace's network as Drive loads: drive-files.test.ts.
describe("Drive's network label", () => {
  it("is DNS-safe, from the device's name and the node's key", () => {
    expect(enrollmentLabel("Zanwei's MacBook Pro.local", nk)).toBe(
      "zanwei-s-macbook-pro-local-ybndrfg8ejkm"
    );
  });

  it("labels a device name with no ASCII letters by a fallback stem", () => {
    expect(enrollmentLabel("工作电脑", nk)).toBe("comma-desktop-ybndrfg8ejkm");
    expect(enrollmentLabel("x".repeat(80), nk)).toHaveLength(63);
  });
});
