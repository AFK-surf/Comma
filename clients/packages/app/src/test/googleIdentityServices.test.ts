// @vitest-environment jsdom

import { afterEach, describe, expect, it, vi } from "vitest";

const scriptId = "comma-google-identity-services";

describe("Google Identity Services loader", () => {
  afterEach(() => {
    document.getElementById(scriptId)?.remove();
    delete window.google;
    vi.resetModules();
  });

  it("replaces a failed script so a later load can retry", async () => {
    const { loadGoogleIdentityServices } =
      await import("../auth/googleIdentityServices");
    const firstLoad = loadGoogleIdentityServices();
    const firstScript = document.getElementById(scriptId);

    expect(firstScript).toBeInstanceOf(HTMLScriptElement);
    firstScript!.dispatchEvent(new Event("error"));
    await expect(firstLoad).rejects.toThrow("Google sign-in could not be loaded.");
    expect(document.getElementById(scriptId)).toBeNull();

    const secondLoad = loadGoogleIdentityServices();
    const secondScript = document.getElementById(scriptId);
    const google = {
      accounts: {
        id: {
          initialize: vi.fn(),
          renderButton: vi.fn(),
        },
      },
    };
    window.google = google;

    expect(secondScript).toBeInstanceOf(HTMLScriptElement);
    expect(secondScript).not.toBe(firstScript);
    secondScript!.dispatchEvent(new Event("load"));
    await expect(secondLoad).resolves.toBe(google);
  });
});
