import { beforeEach, describe, expect, it } from "vitest";
import {
  captureOauthResumeHandle,
  consumeOauthResumeHandle,
  oauthResumeStorageKey,
  oauthResumeUrl,
  peekOauthResumeHandle,
} from "../components/oauth-resume";

const handle = "5f0c2b9a-8f2e-4b7d-9c1a-2e6f3a8d4b10";

function memoryStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (key: string) => map.get(key) ?? null,
    setItem: (key: string, value: string) => void map.set(key, value),
    removeItem: (key: string) => void map.delete(key),
  };
}

describe("captureOauthResumeHandle", () => {
  let storage: ReturnType<typeof memoryStorage>;

  beforeEach(() => {
    storage = memoryStorage();
  });

  it("captures a valid handle and strips it from the URL", () => {
    const cleaned = captureOauthResumeHandle(
      `https://app.example.com/login?oauth_handle=${handle}&other=1`,
      storage
    );

    expect(cleaned).toBe("https://app.example.com/login?other=1");
    expect(peekOauthResumeHandle(storage)).toBe(handle);
  });

  it("is a no-op for URLs without the parameter", () => {
    const cleaned = captureOauthResumeHandle("https://app.example.com/login", storage);

    expect(cleaned).toBeUndefined();
    expect(peekOauthResumeHandle(storage)).toBeUndefined();
  });

  it("discards a malformed handle but still scrubs the URL", () => {
    const cleaned = captureOauthResumeHandle(
      "https://app.example.com/login?oauth_handle=javascript:alert(1)",
      storage
    );

    expect(cleaned).toBe("https://app.example.com/login");
    expect(peekOauthResumeHandle(storage)).toBeUndefined();
  });

  it("lowercases mixed-case UUIDs so both sides compare canonically", () => {
    captureOauthResumeHandle(
      `https://app.example.com/login?oauth_handle=${handle.toUpperCase()}`,
      storage
    );

    expect(peekOauthResumeHandle(storage)).toBe(handle);
  });
});

describe("consumeOauthResumeHandle", () => {
  it("is single use", () => {
    const storage = memoryStorage();
    storage.setItem(oauthResumeStorageKey, handle);

    expect(consumeOauthResumeHandle(storage)).toBe(handle);
    expect(consumeOauthResumeHandle(storage)).toBeUndefined();
  });

  it("drops tampered storage values instead of returning them", () => {
    const storage = memoryStorage();
    storage.setItem(oauthResumeStorageKey, "not-a-uuid");

    expect(consumeOauthResumeHandle(storage)).toBeUndefined();
    expect(storage.getItem(oauthResumeStorageKey)).toBeNull();
  });
});

describe("oauthResumeUrl", () => {
  it.each([
    { name: "targets the configured API origin only", base: "https://api.example.com" },
    {
      name: "tolerates trailing slashes on the base URL",
      base: "https://api.example.com/",
    },
  ])("$name", ({ base }) => {
    expect(oauthResumeUrl(base, handle)).toBe(
      `https://api.example.com/oauth2/authorize?resume=${handle}`
    );
  });
});
