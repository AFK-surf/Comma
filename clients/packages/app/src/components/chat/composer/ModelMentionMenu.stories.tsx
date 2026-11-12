import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { expect, userEvent, within } from "storybook/test";
import {
  AiInput,
  createAiInputRichValue,
  type AiInputRichValue,
} from "@comma/ui/components/ai-input";
import { modelMentionMenu } from "./modelMentionMenu";

const group = modelMentionMenu(
  [
    {
      id: "gpt-6-sol",
      name: "GPT-6 Sol",
      vendor: "openai",
      efforts: ["low", "medium", "high", "xhigh"],
    },
    {
      id: "gpt-6-astra",
      name: "GPT-6 Astra",
      vendor: "openai",
      efforts: ["low", "medium", "high"],
    },
    {
      id: "claude-opus",
      name: "Claude Opus",
      vendor: "anthropic",
      efforts: ["low", "medium", "high"],
    },
    { id: "default-only", name: "Default only", vendor: "google", efforts: [] },
  ],
  {
    modelsGroupLabel: "Start a Task with",
    effortLabel: "Reasoning effort",
    defaultEffortLabel: "Default",
    noResultsLabel: "No results",
  }
);

const meta = {
  title: "App/Chat/Model mention menu",
  component: AiInput,
} satisfies Meta<typeof AiInput>;
export default meta;
type Story = StoryObj<typeof meta>;
function ModelMentionInput({ atWindowBottom = false }: { atWindowBottom?: boolean }) {
  const [value, setValue] = useState<AiInputRichValue>(() =>
    createAiInputRichValue([])
  );
  return (
    <div
      className={
        atWindowBottom
          ? "fixed bottom-0 left-0 flex items-end"
          : "flex min-h-96 items-end pb-xl"
      }
      style={{ width: 640 }}
    >
      <AiInput
        menuRegistrations={[
          { id: "mentions", trigger: "@", label: "Models", groups: [group] },
        ]}
        richValue={value}
        onRichValueChange={setValue}
      />
    </div>
  );
}

export const ProviderAndEffort: Story = {
  tags: ["browser"],
  render: () => <ModelMentionInput />,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement);
    const editor = canvas.getByRole("textbox", { name: "AI prompt" });
    await userEvent.click(editor);
    await userEvent.type(editor, "@");
    await expect(canvas.getByRole("option", { name: "OpenAI" })).toBeVisible();
    await userEvent.keyboard("{Enter}");
    await expect(canvas.getByRole("option", { name: "GPT-6 Sol" })).toBeVisible();
    await userEvent.keyboard("{ArrowDown}{ArrowRight}");
    await expect(
      canvas.getByRole("combobox", { name: "GPT-6 Astra · Reasoning effort" })
    ).toHaveFocus();
    await userEvent.keyboard("{ArrowDown}{ArrowDown}{Enter}");
    await expect(editor).toHaveTextContent("GPT-6 Astra · medium");
    await userEvent.type(editor, " @");
    await userEvent.click(canvas.getByRole("option", { name: "Anthropic" }));
    await userEvent.hover(canvas.getByRole("option", { name: "Claude Opus" }));
    await userEvent.click(canvas.getByRole("option", { name: "high" }));
    await expect(editor).toHaveTextContent("Claude Opus · high");
    await userEvent.type(editor, " @");
    await userEvent.click(canvas.getByRole("option", { name: "Google" }));
    // A model with no efforts to choose is picked by its row.
    await userEvent.click(canvas.getByRole("option", { name: "Default only" }));
    await expect(editor).toHaveTextContent("Default only");
    // A search lists the models it finds: Enter takes the default effort.
    await userEvent.type(editor, " @opus");
    await expect(canvas.queryByRole("option", { name: "Anthropic" })).toBeNull();
    await userEvent.keyboard("{Enter}");
    await expect(editor).toHaveTextContent(/Claude Opus$/);
  },
};

/** Interactive fixture without an automatic play sequence, also used for pointer tests. */
export const Preview: Story = { render: () => <ModelMentionInput /> };

/** The composer flush with the window's bottom edge, where the choices must rise. */
export const AtWindowBottom: Story = {
  render: () => <ModelMentionInput atWindowBottom />,
};
