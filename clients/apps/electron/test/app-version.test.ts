import { describe, expect, it, vi } from "vitest";
import {
  configureElectronAboutPanel,
  resolveElectronDisplayVersion,
} from "../src/app-version";

describe("resolveElectronDisplayVersion", () => {
  it.each(
    (
      [
        {
          name: "uses the stable package version for a local production build",
          input: { flavor: "prod", packageVersion: "1.2.3" },
          expected: "1.2.3",
        },
        {
          name: "uses the release version for a published production build",
          input: { flavor: "prod", packageVersion: "1.2.3", releaseVersion: "2.0.0" },
          expected: "2.0.0",
        },
        {
          name: "uses the GitHub run-bearing release version for staging",
          input: {
            flavor: "staging",
            packageVersion: "1.2.3",
            releaseVersion: "1.2.4-staging.280",
          },
          expected: "1.2.4-staging.280",
        },
        {
          name: "marks a Forge-only local staging build without inventing a run number",
          input: { flavor: "staging", packageVersion: "1.2.3" },
          expected: "1.2.3-staging.local",
        },
        {
          name: "adds the development suffix without accepting release metadata",
          input: { flavor: "dev", packageVersion: "1.2.3", releaseVersion: "9.9.9" },
          expected: "1.2.3-dev",
        },
      ] as const
    ).map((row) => [row.name, row] as [string, typeof row])
  )("%s", (_name, { input, expected }) => {
    expect(resolveElectronDisplayVersion(input)).toBe(expected);
  });

  it.each([
    {
      flavor: "prod" as const,
      packageVersion: "1.2",
      releaseVersion: undefined,
    },
    {
      flavor: "prod" as const,
      packageVersion: "1.2.3",
      releaseVersion: "1.2.3-staging.280",
    },
    {
      flavor: "staging" as const,
      packageVersion: "1.2.3",
      releaseVersion: "1.2.4",
    },
    {
      flavor: "staging" as const,
      packageVersion: "1.2.3",
      releaseVersion: "1.2.4-staging.local",
    },
  ])(
    "rejects an invalid $flavor version contract",
    ({ flavor, packageVersion, releaseVersion }) => {
      expect(() =>
        resolveElectronDisplayVersion({
          flavor,
          packageVersion,
          releaseVersion,
        })
      ).toThrow(/version/i);
    }
  );
});

describe("configureElectronAboutPanel", () => {
  it("uses one canonical visible version and clears the plist build version", () => {
    const setAboutPanelOptions = vi.fn();

    configureElectronAboutPanel(
      { setAboutPanelOptions },
      {
        displayVersion: "1.2.4-staging.280",
        productName: "Comma Staging",
      }
    );

    expect(setAboutPanelOptions).toHaveBeenCalledWith({
      applicationName: "Comma Staging",
      applicationVersion: "1.2.4-staging.280",
      version: "",
    });
  });
});
