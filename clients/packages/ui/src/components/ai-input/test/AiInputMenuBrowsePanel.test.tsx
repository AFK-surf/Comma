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

  it("shows what arrives behind an open row, and tells it the row opened", () => {
    const onQueryChange = vi.fn();
    const behind = (rows: string[]): AiInputMenuBrowse => ({
      compact: true,
      label: "Row",
      title: "Row",
      searchPlaceholder: "Search",
      emptyLabel: "Empty",
      noResultsLabel: "No matches",
      onQueryChange,
      groups: [{ id: "behind", items: rows.map((id) => ({ id, label: id })) }],
    });
    const panel = (rows: string[]) => {
      const browse: AiInputMenuBrowse = {
        label: "More",
        title: "Outer",
        searchPlaceholder: "Search",
        emptyLabel: "Empty",
        noResultsLabel: "No matches",
        groups: [
          { id: "rows", items: [{ id: "row", label: "Row", browse: behind(rows) }] },
        ],
      };
      return (
        <AiInputMenuBrowsePanel
          backLabel="Back"
          browse={browse}
          focusOnMount
          group={{ id: "outer", items: [], browse }}
          initialQuery=""
          listId="list"
          onBack={() => undefined}
          onBlur={() => undefined}
          onSelectItem={() => undefined}
          optionId={(id) => id}
          searchingLabel="Searching"
        />
      );
    };
    const { rerender } = render(panel(["whole"]));
    fireEvent.mouseDown(screen.getByText("Row"));
    expect(screen.getByText("whole")).toBeTruthy();
    expect(onQueryChange).toHaveBeenLastCalledWith("");

    rerender(panel(["whole", "amy"]));
    expect(screen.getByText("amy")).toBeTruthy();
  });
});
