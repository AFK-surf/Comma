import { useState } from "react";
import userEvent from "@testing-library/user-event";
import { render, screen } from "@comma/test-utils/render";
import { describe, expect, it } from "vitest";
import { SearchSelect } from "../SearchSelect";

const groups = [
  { id: "oc_sales", label: "Sales" },
  { id: "oc_product", label: "Product" },
];

function Picker() {
  const [value, setValue] = useState("none");
  const label =
    value === "none"
      ? "None"
      : (groups.find((group) => group.id === value)?.label ?? value);
  return (
    <SearchSelect
      display={label}
      emptyText="No group matches"
      items={(query) => {
        const needle = query.trim().toLowerCase();
        const listed = groups.filter(
          (group) => !needle || group.label.toLowerCase().includes(needle)
        );
        const pasted =
          /^oc_\w+$/.test(needle) && !listed.length
            ? [{ id: needle, label: `Use ID ${needle}` }]
            : [];
        return [
          ...(needle ? [] : [{ id: "none", label: "None" }]),
          ...listed,
          ...pasted,
        ];
      }}
      label="Team group"
      onChange={setValue}
      searchPlaceholder="Filter groups"
      value={value}
    />
  );
}

describe("SearchSelect", () => {
  it("keeps one trigger and searches inside its panel", async () => {
    const user = userEvent.setup();
    render(<Picker />);

    const trigger = screen.getByRole("button", { name: "Team group" });
    expect(trigger).toHaveTextContent("None");
    expect(screen.queryByPlaceholderText("Filter groups")).toBeNull();

    await user.click(trigger);
    const search = screen.getByPlaceholderText("Filter groups");
    expect(search).toHaveFocus();
    await user.type(search, "prod");
    expect(screen.queryByRole("button", { name: /Sales/ })).toBeNull();
    await user.click(screen.getByRole("button", { name: /Product/ }));

    expect(screen.queryByPlaceholderText("Filter groups")).toBeNull();
    expect(screen.getByRole("button", { name: "Team group" })).toHaveTextContent(
      "Product"
    );

    // Each opening starts from the whole list.
    await user.click(screen.getByRole("button", { name: "Team group" }));
    expect(screen.getByPlaceholderText("Filter groups")).toHaveValue("");
  });

  it("offers a pasted ID and says when nothing matches", async () => {
    const user = userEvent.setup();
    render(<Picker />);

    await user.click(screen.getByRole("button", { name: "Team group" }));
    await user.type(screen.getByPlaceholderText("Filter groups"), "zzz");
    expect(screen.getByText("No group matches")).toBeInTheDocument();

    await user.clear(screen.getByPlaceholderText("Filter groups"));
    await user.type(screen.getByPlaceholderText("Filter groups"), "oc_new");
    await user.click(screen.getByRole("button", { name: "Use ID oc_new" }));
    expect(screen.getByRole("button", { name: "Team group" })).toHaveTextContent(
      "oc_new"
    );
  });
});
