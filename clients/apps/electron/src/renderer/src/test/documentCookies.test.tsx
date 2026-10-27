import posthog from "posthog-js";
import { afterEach, expect, it, vi } from "vitest";
import { closeDocumentCookies } from "../documentCookies";

afterEach(() => {
  Reflect.deleteProperty(document, "cookie");
});

it("analytics leaves the cookie store alone", () => {
  // The document's own cookie store.
  const read = vi.spyOn(Document.prototype, "cookie", "get");
  const write = vi.spyOn(Document.prototype, "cookie", "set");
  closeDocumentCookies();
  // A named instance of its own: the module's default instance may have
  // loaded before this test.
  const client = posthog.init(
    "phc_test",
    {
      api_host: "https://posthog.invalid",
      persistence: "localStorage",
      advanced_disable_flags: true,
      disable_external_dependency_loading: true,
    },
    "document-cookies-test"
  );
  client.register({ runtime: "electron" });
  client.has_opted_out_capturing();
  client.reset(true);

  expect(read).not.toHaveBeenCalled();
  expect(write).not.toHaveBeenCalled();
  expect(document.cookie).toBe("");
});
