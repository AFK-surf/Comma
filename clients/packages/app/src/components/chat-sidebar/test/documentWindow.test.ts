import { expect, it } from "vitest";
import {
  documentWindowOf,
  documentWindowRoute,
  documentWindowSearch,
  documentWindowTarget,
  documentWindowVersion,
} from "../documentWindow";

const version = (messageId: string, workspacePath?: string) => ({
  groupId: "grp_1",
  conversationId: "cnv_1",
  messageId,
  attachmentIndex: 0,
  fileName: "插件 接入方案 & notes.md",
  ...(workspacePath ? { workspacePath } : {}),
});

it("names a document's window by a route that reads back as the same document", () => {
  const target = documentWindowOf("wsp_1", version("42"));
  const route = documentWindowRoute(target);
  expect(route.startsWith("/documents/window?")).toBe(true);
  // The router gives a search value that reads as a number as one.
  const search = Object.fromEntries(
    Array.from(new URLSearchParams(route.split("?")[1]), ([key, value]) => [
      key,
      /^\d+$/u.test(value) ? Number(value) : value,
    ])
  );
  expect(documentWindowTarget(documentWindowSearch(search))).toEqual(target);
  expect(
    documentWindowTarget(documentWindowSearch({ ...search, n: undefined }))
  ).toBeUndefined();
});

it("names one window for a document whichever of its versions is shown", () => {
  // The panel finds the document's window by this route: an Agent's new version, and a version the person sent,
  // are the same document's, so the panel still says the document is in its window and opens no second one.
  const first = documentWindowRoute(documentWindowOf("wsp_1", version("42")));
  expect(documentWindowRoute(documentWindowOf("wsp_1", version("57")))).toBe(first);
  expect(
    documentWindowRoute(
      documentWindowOf(
        "wsp_1",
        version("58", "/uploads/AAAAAAAAAAAAAAAAAAAAAQ-notes.md")
      )
    )
  ).toBe(first);
  // Another document of the conversation has a window of its own.
  expect(
    documentWindowRoute(
      documentWindowOf("wsp_1", { ...version("42"), fileName: "other.md" })
    )
  ).not.toBe(first);
});

it("shows the newest version in the window, and a chosen one only until another arrives", () => {
  expect(documentWindowVersion([], undefined)).toBeUndefined();
  expect(documentWindowVersion(["v1", "v2"], undefined)).toBe("v2");
  // The reader went back to the first of two versions.
  const chosen = { version: "v1", among: 2 };
  expect(documentWindowVersion(["v1", "v2"], chosen)).toBe("v1");
  // A third arrives: the window goes to it.
  expect(documentWindowVersion(["v1", "v2", "v3"], chosen)).toBe("v3");
});
