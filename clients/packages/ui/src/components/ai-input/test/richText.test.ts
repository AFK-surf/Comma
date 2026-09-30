import { describe, expect, it } from "vitest";
import {
  aiInputMenuBrowseItemId,
  createAiInputRichValue,
  filterAiInputMenuGroups,
  filterAiInputMenuItems,
  findAiInputMenuMatch,
  type AiInputMenuGroup,
  type AiInputMenuRegistration,
} from "../richText";

const registrations: AiInputMenuRegistration[] = [
  {
    id: "skills",
    trigger: "/",
    label: "Skills",
    groups: [
      {
        id: "skills",
        items: [
          {
            id: "code-review",
            label: "Code Review",
            description: "Review pull requests",
            keywords: ["quality"],
          },
          { id: "image-gen", label: "Image Generation" },
        ],
      },
    ],
  },
  {
    id: "plugins",
    trigger: "@",
    label: "Plugins",
    groups: [{ id: "plugins", items: [{ id: "codex", label: "Codex" }] }],
  },
];

describe("AI input rich-text helpers", () => {
  it("matches the nearest registered trigger only at a text boundary", () => {
    expect(findAiInputMenuMatch("Build with /cod", registrations)).toMatchObject({
      query: "cod",
      start: 11,
      registration: { id: "skills" },
    });
    expect(findAiInputMenuMatch("Ask @cod", registrations)).toMatchObject({
      query: "cod",
      registration: { id: "plugins" },
    });
    expect(findAiInputMenuMatch("https://comma.ai", registrations)).toBeNull();
    expect(findAiInputMenuMatch("email@comma.ai", registrations)).toBeNull();
    expect(findAiInputMenuMatch("/code review", registrations)).toBeNull();
  });

  it("falls back to fullwidth ＠ and ／ committed by a CJK input method", () => {
    expect(findAiInputMenuMatch("用 ／cod", registrations)).toMatchObject({
      query: "cod",
      registration: { id: "skills" },
    });
    expect(findAiInputMenuMatch("问 ＠cod", registrations)).toMatchObject({
      query: "cod",
      registration: { id: "plugins" },
    });
    // The boundary rule still applies to the fullwidth forms.
    expect(findAiInputMenuMatch("邮箱＠comma.ai", registrations)).toBeNull();
    // The context reports the canonical trigger, not the typed alias.
    let seenTrigger: string | undefined;
    findAiInputMenuMatch("＠", [
      {
        ...registrations[1]!,
        shouldOpen: (context) => {
          seenTrigger = context.trigger;
          return true;
        },
      },
    ]);
    expect(seenTrigger).toBe("@");
  });

  it("ranks names before descriptions and keywords and caps results", () => {
    expect(
      filterAiInputMenuGroups(registrations[0]!, "code")[0]?.items.map(
        (item) => item.id
      )
    ).toEqual(["code-review"]);
    expect(
      filterAiInputMenuGroups(registrations[0]!, "quality")[0]?.items.map(
        (item) => item.id
      )
    ).toEqual(["code-review"]);
  });

  it("keeps rich tokens separate while producing a backwards-compatible prompt", () => {
    const value = createAiInputRichValue([
      { type: "text", text: "Use " },
      {
        type: "token",
        instanceId: "skill-1",
        menuId: "skills",
        itemId: "image-gen",
        trigger: "/",
        label: "Image Generation",
        plainText: "/image-gen",
        data: { location: "/skills/image-gen/SKILL.md" },
      },
      { type: "text", text: " with " },
      {
        type: "token",
        instanceId: "plugin-1",
        menuId: "plugins",
        itemId: "codex",
        trigger: "@",
        label: "Codex",
        plainText: "@codex",
      },
    ]);

    expect(value.plainText).toBe("Use /image-gen with @codex");
    expect(value.tokens.map((token) => token.itemId)).toEqual(["image-gen", "codex"]);
  });
  it("caps a group at its limit and appends the browse row once the source has settled", () => {
    const files = [
      { id: "c", label: "gamma.txt" },
      { id: "b", label: "beta.png" },
      { id: "a", label: "alpha.pdf" },
    ];
    const drive = (status: "loading" | "ready"): AiInputMenuGroup => ({
      id: "drive",
      label: "Drive",
      items: files,
      limit: 2,
      status,
      browse: {
        label: "View more",
        title: "Drive",
        searchPlaceholder: "Search files",
        emptyLabel: "No files",
        noResultsLabel: "No results found",
        groups: [{ id: "folder", label: "Folder A", items: files }],
      },
    });
    const registration = (status: "loading" | "ready"): AiInputMenuRegistration => ({
      id: "mentions",
      trigger: "@",
      label: "Mentions",
      maxItems: Number.POSITIVE_INFINITY,
      groups: [drive(status)],
    });

    // Source order is recency; the cap keeps the head and the browse row closes the group.
    expect(filterAiInputMenuGroups(registration("ready"), "")[0]?.items).toMatchObject([
      { id: "c" },
      { id: "b" },
      {
        id: aiInputMenuBrowseItemId("drive"),
        label: "View more",
        browseGroupId: "drive",
      },
    ]);
    // A query ranks across the whole group before the cap applies.
    expect(
      filterAiInputMenuGroups(registration("ready"), "alp")[0]?.items.map(
        (item) => item.id
      )
    ).toEqual(["a", "drive:browse"]);
    // No match still leaves the door to the panel open, with the query carried there.
    expect(
      filterAiInputMenuGroups(registration("ready"), "zzz")[0]?.items.map(
        (item) => item.id
      )
    ).toEqual(["drive:browse"]);
    // While the source indexes there is no door yet: the rows it has so far
    // list, and the searching row (not "View more") closes the section.
    expect(
      filterAiInputMenuGroups(registration("loading"), "")[0]?.items.map(
        (item) => item.id
      )
    ).toEqual(["c", "b"]);
    // The browse panel filters the same rows without a cap.
    expect(filterAiInputMenuItems(files, "a").map((item) => item.id)).toEqual([
      "a",
      "c",
      "b",
    ]);
    expect(filterAiInputMenuItems(files, "alpha").map((item) => item.id)).toEqual([
      "a",
    ]);
  });
});
