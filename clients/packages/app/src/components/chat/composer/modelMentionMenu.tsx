import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import type { AiInputMenuItem, AiInputMenuGroup } from "@comma/ui/components/ai-input";
import { modelMentionPlainText } from "@comma/core/chat";
import type { ComposerModelMentionItem } from "./useComposerMentionSources";

const vendorNames: Record<string, string> = {
  openai: "OpenAI",
  anthropic: "Anthropic",
  google: "Google",
  deepseek: "DeepSeek",
  qwen: "Qwen",
  kimi: "Kimi",
  glm: "GLM",
  minimax: "MiniMax",
  xai: "xAI",
};

/**
 * The "@" menu's models: a row per vendor, each holding its models, each
 * model holding its reasoning efforts. A search lists the models it finds
 * directly, so "@gpt" and Enter take a model at its default effort.
 */
export function modelMentionMenu(
  models: readonly ComposerModelMentionItem[],
  labels: {
    modelsGroupLabel: string;
    effortLabel: string;
    defaultEffortLabel: string;
    noResultsLabel: string;
  }
): AiInputMenuGroup {
  const { modelsGroupLabel, effortLabel, defaultEffortLabel, noResultsLabel } = labels;
  const vendors = new Map<string, AiInputMenuItem[]>();
  const found: AiInputMenuItem[] = [];
  for (const model of models) {
    const icon = <ModelVendorIcon vendor={model.vendor} />;
    // A row of its own for the default effort and for each it takes.
    const choice = (effort: string | null): AiInputMenuItem => {
      const name = effort ? `${model.name} · ${effort}` : model.name;
      return {
        id: `model:${model.id}${effort ? `:${effort}` : ""}`,
        label: effort ?? defaultEffortLabel,
        icon,
        tokenLabel: name,
        plainText: modelMentionPlainText(name, model.id, effort ?? undefined),
        data: { kind: "model", modelId: model.id, effort },
      };
    };
    // Found by a search, Enter or a click takes the default effort and
    // ArrowRight opens the efforts; under its vendor they open beside it.
    // A model with no efforts to choose is picked by its row alone.
    const row: AiInputMenuItem = {
      ...choice(null),
      label: model.name,
      keywords: [model.id],
      ...(model.efforts.length > 0
        ? {
            browse: {
              compact: true,
              label: model.name,
              title: `${model.name} · ${effortLabel}`,
              // The field heads the panel: which model these efforts are for.
              searchPlaceholder: model.name,
              emptyLabel: noResultsLabel,
              noResultsLabel,
              groups: [
                {
                  id: `model:${model.id}/efforts`,
                  label: effortLabel,
                  items: [null, ...model.efforts].map(choice),
                },
              ],
            },
          }
        : {}),
    };
    // Beside its efforts, the row's id stays clear of the default's.
    const listed = row.browse ? { ...row, id: `model:${model.id}/choices` } : row;
    vendors.set(model.vendor, [...(vendors.get(model.vendor) ?? []), listed]);
    found.push({ ...row, searchOnly: true });
  }
  return {
    id: "models",
    label: modelsGroupLabel,
    items: [
      ...[...vendors].map(([vendor, items]): AiInputMenuItem => {
        const label = vendorNames[vendor] ?? vendor;
        return {
          id: `vendor:${vendor}`,
          label,
          icon: <ModelVendorIcon vendor={vendor} />,
          browseGroupId: `vendor:${vendor}`,
          browse: {
            compact: true,
            label,
            title: label,
            searchPlaceholder: label,
            emptyLabel: noResultsLabel,
            noResultsLabel,
            groups: [{ id: `vendor:${vendor}/models`, items }],
          },
        };
      }),
      ...found,
    ],
  };
}
