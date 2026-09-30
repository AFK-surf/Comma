// @vitest-environment jsdom
import { afterEach, expect, it, vi } from "vitest";
import { defaultApiBaseUrl } from "../config";

vi.mock("@comma/config", () => ({
  getActiveCommaConfig: () => ({
    channel: "prod",
    apiBaseUrl: "https://salix.comma.surf",
  }),
}));

afterEach(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});

it("honors an explicitly built production API address", () => {
  vi.stubGlobal("COMMA_DEFINED_API_BASE_URL", "https://comma.example");
  localStorage.setItem("comma.apiBaseUrl", "https://another-instance.example");
  expect(defaultApiBaseUrl()).toBe("https://comma.example");
});
