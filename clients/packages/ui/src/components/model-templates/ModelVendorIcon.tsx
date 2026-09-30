import { ModelIcon } from "./ModelIcon";

// Brand artwork supplied for the model picker. OpenAI and vendors without
// supplied artwork use the existing app icons.
const logos: Record<string, string> = {
  anthropic: new URL("./assets/claude.svg", import.meta.url).href,
  google: new URL("./assets/gemini.svg", import.meta.url).href,
  glm: new URL("./assets/glm.svg", import.meta.url).href,
  kimi: new URL("./assets/kimi.svg", import.meta.url).href,
  fireworks: new URL("./assets/fireworks.svg", import.meta.url).href,
  deepseek: new URL("./assets/deepseek.svg", import.meta.url).href,
  minimax: new URL("./assets/minimax.svg", import.meta.url).href,
  qwen: new URL("./assets/qwen.svg", import.meta.url).href,
};

export function ModelVendorIcon({ vendor }: { vendor: string }) {
  const logo = logos[vendor];
  return logo ? (
    <img alt="" className="size-4 shrink-0 object-contain dark:invert" src={logo} />
  ) : (
    <ModelIcon brand={vendor} />
  );
}
