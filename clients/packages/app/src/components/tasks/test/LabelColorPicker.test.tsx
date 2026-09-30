import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LabelColorPicker } from "../LabelColorPicker";
import { isCustomLabelColor } from "../labelColor";

function renderPicker(color: string, onChange = vi.fn()) {
  render(
    <CommaI18nProvider locale="en">
      <LabelColorPicker
        color={color}
        disabled={false}
        label="Label color"
        onChange={onChange}
      />
    </CommaI18nProvider>
  );
  return onChange;
}

describe("LabelColorPicker", () => {
  beforeEach(() => {
    initializeCommaI18n(["en"]);
  });

  it("commits a preset from the swatch row and marks the current one", async () => {
    const user = userEvent.setup();
    const onChange = renderPicker("brand");
    await user.click(screen.getByRole("button", { name: "Label color" }));
    await screen.findByTestId("label-color-picker");
    expect(screen.getByRole("radio", { name: "brand" })).toBeChecked();
    expect(screen.queryByTestId("label-color-custom-panel")).toBeNull();
    await user.click(screen.getByRole("radio", { name: "indigo" }));
    expect(onChange).toHaveBeenCalledWith("indigo");
  });

  it("opens the custom picker and commits a typed hex value", async () => {
    const user = userEvent.setup();
    const onChange = renderPicker("gray");
    await user.click(screen.getByRole("button", { name: "Label color" }));
    await screen.findByTestId("label-color-picker");
    await user.click(screen.getByRole("radio", { name: "Custom color" }));
    expect(await screen.findByTestId("label-color-custom-panel")).toBeInTheDocument();
    const hex = screen.getByTestId("label-color-hex");
    fireEvent.change(hex, { target: { value: "#E06C75" } });
    fireEvent.blur(hex);
    await waitFor(() => expect(onChange).toHaveBeenCalledWith("#e06c75"));
  });

  it("treats a custom colour as selected in the custom slot", async () => {
    const user = userEvent.setup();
    renderPicker("#e06c75");
    expect(isCustomLabelColor("#e06c75")).toBe(true);
    await user.click(screen.getByRole("button", { name: "Label color" }));
    await screen.findByTestId("label-color-picker");
    expect(screen.getByRole("radio", { name: "Custom color" })).toBeChecked();
    expect(screen.getByTestId("label-color-custom-panel")).toBeInTheDocument();
  });
});
