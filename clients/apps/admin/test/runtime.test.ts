import { describe, expect, it, vi } from "vitest";
import { resolveAdminApiBaseUrl } from "../src/runtime";
import { createAdminViteConfig, resolveAdminBuildConfiguration } from "../vite.config";
import worker from "../wrangler.worker";

describe("Comma Admin runtime boundary", () => {
  it("has no Vite API proxy", () => {
    const config = createAdminViteConfig({ COMMA_BUILD_FLAVOR: "dev" });

    expect(config.define).toMatchObject({
      COMMA_DEFINED_API_BASE_URL: JSON.stringify("http://127.0.0.1:4200"),
    });
    expect("server" in config).toBe(false);
    expect("preview" in config).toBe(false);
  });

  it("binds each Admin build channel to its authoritative API origin", () => {
    expect(() => resolveAdminBuildConfiguration({})).toThrow(
      "Missing COMMA_BUILD_FLAVOR"
    );
    const channels = [
      ["dev", "http://127.0.0.1:4200"],
      ["staging", "https://salix-staging.comma.surf"],
      ["prod", "https://salix.comma.surf"],
    ] as const;

    for (const [flavor, apiBaseUrl] of channels) {
      const config = createAdminViteConfig({ COMMA_BUILD_FLAVOR: flavor });
      expect(config.define).toMatchObject({
        COMMA_DEFINED_API_BASE_URL: JSON.stringify(apiBaseUrl),
        COMMA_DEFINED_BUILD_FLAVOR: JSON.stringify(flavor),
      });
    }

    expect(
      createAdminViteConfig({
        COMMA_API_BASE_URL: "http://127.0.0.1:65535",
        COMMA_BUILD_FLAVOR: "dev",
      }).define.COMMA_DEFINED_API_BASE_URL
    ).toBe(JSON.stringify("http://127.0.0.1:65535"));

    for (const flavor of ["staging", "prod"] as const) {
      expect(() =>
        createAdminViteConfig({
          COMMA_API_BASE_URL: "https://unexpected.example",
          COMMA_BUILD_FLAVOR: flavor,
        })
      ).toThrow("COMMA_API_BASE_URL is only supported for dev Admin builds");
    }

    expect(
      createAdminViteConfig({
        COMMA_API_BASE_URL: "   ",
        COMMA_BUILD_FLAVOR: "prod",
      }).define.COMMA_DEFINED_API_BASE_URL
    ).toBe(JSON.stringify("https://salix.comma.surf"));
  });

  it("permits an operator-selected API only in an explicit selfhost production build", () => {
    expect(
      createAdminViteConfig({
        COMMA_BUILD_FLAVOR: "prod",
        COMMA_SELFHOST_BUILD: "true",
        COMMA_API_BASE_URL: "https://api.instance.example",
      }).define.COMMA_DEFINED_API_BASE_URL
    ).toBe(JSON.stringify("https://api.instance.example"));
  });

  it("requires a build-injected API origin", () => {
    expect(resolveAdminApiBaseUrl("http://127.0.0.1:4200")).toBe(
      "http://127.0.0.1:4200"
    );
    expect(() => resolveAdminApiBaseUrl(undefined)).toThrow(
      "was not injected by the build"
    );
  });

  it("rejects same-origin /v1 requests instead of proxying credentials", async () => {
    const assetsFetch = vi.fn(async () => new Response("asset"));
    const env = { ASSETS: { fetch: assetsFetch } };

    const apiResponse = await worker.fetch(
      new Request("https://admin.comma.surf/v1/comma/admin/users"),
      env
    );
    const assetResponse = await worker.fetch(
      new Request("https://admin.comma.surf/"),
      env
    );

    expect(apiResponse.status).toBe(404);
    await expect(apiResponse.json()).resolves.toEqual({
      error: "direct_api_origin_required",
    });
    expect(await assetResponse.text()).toBe("asset");
    expect(assetsFetch).toHaveBeenCalledOnce();
  });
});
