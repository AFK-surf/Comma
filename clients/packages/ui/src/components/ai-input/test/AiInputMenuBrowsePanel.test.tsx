import { fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { AiInputMenuBrowsePanel } from "../menu/AiInputMenuBrowsePanel";
import type { AiInputMenuBrowse, AiInputMenuGroup } from "../richText";

const first = { id: "a1", label: "a1.txt" };
const selected = { id: "b1", label: "b1.txt" };
function view(groups: AiInputMenuGroup[], loadMore = vi.fn()) {
  const browse: AiInputMenuBrowse = {
    label: "More",
    title: "Drive",
    searchPlaceholder: "Search",
    emptyLabel: "Empty",
    noResultsLabel: "No matches",
    groups,
    prefiltered: true,
    onLoadMore: loadMore,
  };
  return (
    <AiInputMenuBrowsePanel
      backLabel="Back"
      browse={browse}
      focusOnMount
      group={{ id: "drive", items: [] }}
      initialQuery=""
      listId="files"
      onBack={() => {}}
      onBlur={() => {}}
      onSelectItem={() => {}}
      optionId={(id) => id}
      searchingLabel="Searching"
    />
  );
}

describe("remote browse pagination", () => {
  it("keeps keyboard selection on the same file when another folder gains rows", () => {
    const groups = [
      { id: "a", items: [first] },
      { id: "b", items: [selected] },
    ];
    const rendered = render(view(groups));
    fireEvent.keyDown(screen.getByRole("combobox"), { key: "ArrowDown" });
    expect(screen.getByRole("option", { name: "b1.txt" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
    rendered.rerender(
      view([{ id: "a", items: [first, { id: "a2", label: "a2.txt" }] }, groups[1]!])
    );
    expect(screen.getByRole("option", { name: "b1.txt" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
  });

  it("requests another page from the last keyboard option", () => {
    const loadMore = vi.fn();
    render(view([{ id: "a", items: [first] }], loadMore));
    fireEvent.keyDown(screen.getByRole("combobox"), { key: "ArrowDown" });
    expect(loadMore).toHaveBeenCalledOnce();
    expect(screen.getByRole("option", { name: "a1.txt" })).toHaveAttribute(
      "aria-selected",
      "true"
    );
  });
});
