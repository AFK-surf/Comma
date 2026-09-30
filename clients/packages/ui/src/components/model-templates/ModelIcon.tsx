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
};

export function ModelIcon({ brand }: { brand?: string | null | undefined }) {
  const Icon =
    brand && brand in icons ? icons[brand as keyof typeof icons] : SparklesIcon;
  return <Icon className="size-4 shrink-0" aria-hidden="true" />;
}
