import { ModelIcon } from "./ModelIcon";

// Brand artwork for the model picker and provider list. OpenAI and vendors
// with a Central Icons mark use the app icons instead.
const logos: Record<string, string> = {
  anthropic: new URL("./assets/claude.svg", import.meta.url).href,
  google: new URL("./assets/gemini.svg", import.meta.url).href,
  glm: new URL("./assets/glm.svg", import.meta.url).href,
  kimi: new URL("./assets/kimi.svg", import.meta.url).href,
  fireworks: new URL("./assets/fireworks.svg", import.meta.url).href,
  deepseek: new URL("./assets/deepseek.svg", import.meta.url).href,
  minimax: new URL("./assets/minimax.svg", import.meta.url).href,
  qwen: new URL("./assets/qwen.svg", import.meta.url).href,
  // Placeholder marks from @lobehub/icons-static-svg for providers without a
  // Central Icons logo, until design supplies artwork.
  openrouter: new URL("./assets/openrouter.svg", import.meta.url).href,
  groq: new URL("./assets/groq.svg", import.meta.url).href,
  cerebras: new URL("./assets/cerebras.svg", import.meta.url).href,
  together: new URL("./assets/together.svg", import.meta.url).href,
  huggingface: new URL("./assets/huggingface.svg", import.meta.url).href,
  cloudflare: new URL("./assets/cloudflare.svg", import.meta.url).href,
  azure: new URL("./assets/azure.svg", import.meta.url).href,
  xiaomi: new URL("./assets/xiaomi.svg", import.meta.url).href,
  baseten: new URL("./assets/baseten.svg", import.meta.url).href,
};

/** Whether `vendor` has supplied artwork rather than an app icon fallback. */
export const hasModelVendorLogo = (vendor: string) => vendor in logos;

export function ModelVendorIcon({ vendor }: { vendor: string }) {
  const logo = logos[vendor];
  return logo ? (
    <img alt="" className="size-4 shrink-0 object-contain dark:invert" src={logo} />
  ) : (
    <ModelIcon brand={vendor} />
  );
}
