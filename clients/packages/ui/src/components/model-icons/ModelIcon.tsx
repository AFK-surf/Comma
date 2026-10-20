import {
  OpenAiIcon,
  ClaudeAiIcon,
  CodexBrandIcon,
  AnthropicBrandIcon,
  GeminiBrandIcon,
  DeepSeekBrandIcon,
  MistralBrandIcon,
  MetaAiBrandIcon,
  GrokBrandIcon,
  QwenBrandIcon,
  ZaiBrandIcon,
  NvidiaBrandIcon,
  OllamaBrandIcon,
  OpencodeBrandIcon,
  VercelBrandIcon,
  CopilotBrandIcon,
  SparklesIcon,
} from "../icons";

const icons = {
  openai: OpenAiIcon,
  anthropic: AnthropicBrandIcon,
  codex: CodexBrandIcon,
  claude: ClaudeAiIcon,
  google: GeminiBrandIcon,
  deepseek: DeepSeekBrandIcon,
  mistral: MistralBrandIcon,
  meta: MetaAiBrandIcon,
  xai: GrokBrandIcon,
  qwen: QwenBrandIcon,
  zai: ZaiBrandIcon,
  nvidia: NvidiaBrandIcon,
  ollama: OllamaBrandIcon,
  opencode: OpencodeBrandIcon,
  vercel: VercelBrandIcon,
  "github-copilot": CopilotBrandIcon,
};

/** Whether `brand` has its own mark rather than the generic sparkles. */
export const hasModelIcon = (brand: string | null | undefined) =>
  !!brand && brand in icons;

export function ModelIcon({ brand }: { brand?: string | null | undefined }) {
  const Icon =
    brand && brand in icons ? icons[brand as keyof typeof icons] : SparklesIcon;
  return <Icon className="size-4 shrink-0" aria-hidden="true" />;
}
