import { afterEach, describe, expect, it, vi } from "vitest";

async function loadViteConfig(
  flavor: "dev" | "prod" | "staging",
  explicitApiBaseUrl = ""
) {
  vi.stubEnv("COMMA_BUILD_FLAVOR", flavor);
  vi.stubEnv("COMMA_API_BASE_URL", explicitApiBaseUrl);
  vi.resetModules();
  return (await import("../vite.config")).default;
}

describe("Comma web runtime config", () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it("uses the local Comma API origin without a same-origin proxy fallback", async () => {
    const config = await loadViteConfig("dev");

    expect(config.define).toMatchObject({
      COMMA_DEFINED_API_BASE_URL: JSON.stringify("http://127.0.0.1:4200"),
    });
    expect(config.server?.proxy).toBeUndefined();
    expect(config.preview?.proxy).toBeUndefined();
  });

  it("keeps an explicit API override local to dev builds", async () => {
    const config = await loadViteConfig("dev", "http://127.0.0.1:4300");

    expect(config.define).toMatchObject({
      COMMA_DEFINED_API_BASE_URL: JSON.stringify("http://127.0.0.1:4300"),
    });
  });
});
