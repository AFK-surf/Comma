import type { ComponentType } from "react";
import { createCentralIcon, type IconProps } from "./createCentralIcon";

type CentralIcon = Parameters<typeof createCentralIcon>[0];

/**
 * A logo whose Central Icons module loads on `preload()`. A mark is about
 * 1 KB gzipped, but the catalog together is about 24 KB, so each mark ships
 * as its own chunk and a card pays only for the logos it shows. The mark
 * renders nothing until it loads, and nothing if its chunk cannot load.
 */
export const lazyBrandMark = (load: () => Promise<CentralIcon>) => {
  let Icon: ComponentType<IconProps> | undefined;
  let pending: Promise<void> | undefined;
  const preload = () =>
    (pending ??= load().then(
      (loaded) => {
        Icon = createCentralIcon(loaded);
      },
      () => {}
    ));
  function BrandMarkIcon(props: IconProps) {
    return Icon ? <Icon {...props} /> : null;
  }
  return Object.assign(BrandMarkIcon, { preload });
};

/**
 * Well-known brands content cards can mark with their logo. Keys are stable
 * product identifiers; every entry is recorded in `iconRegistry` as
 * `brandMarks.<key>`. AI providers stay on the filled package, matching the
 * trademark package the model picker already uses.
 */
export const brandMarks = {
  apple: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconApple").then(
      (m) => m.IconApple
    )
  ),
  "apple-music": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconAppleMusic").then(
      (m) => m.IconAppleMusic
    )
  ),
  "app-store": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconAppstore").then(
      (m) => m.IconAppstore
    )
  ),
  google: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconGoogle").then(
      (m) => m.IconGoogle
    )
  ),
  "google-play": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconGooglePlayStore").then(
      (m) => m.IconGooglePlayStore
    )
  ),
  nvidia: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconNvidia").then(
      (m) => m.IconNvidia
    )
  ),
  bitcoin: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconBitcoin").then(
      (m) => m.IconBitcoin
    )
  ),
  ethereum: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconEthereum").then(
      (m) => m.IconEthereum
    )
  ),
  github: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconGithub").then(
      (m) => m.IconGithub
    )
  ),
  linear: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconLinear").then(
      (m) => m.IconLinear
    )
  ),
  notion: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconNotion").then(
      (m) => m.IconNotion
    )
  ),
  slack: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSlack").then(
      (m) => m.IconSlack
    )
  ),
  figma: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconFigma").then(
      (m) => m.IconFigma
    )
  ),
  jira: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconJira").then(
      (m) => m.IconJira
    )
  ),
  atlassian: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconAtlassian").then(
      (m) => m.IconAtlassian
    )
  ),
  vercel: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconVercel").then(
      (m) => m.IconVercel
    )
  ),
  supabase: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSupabase").then(
      (m) => m.IconSupabase
    )
  ),
  framer: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconFramer").then(
      (m) => m.IconFramer
    )
  ),
  webflow: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconWebflow").then(
      (m) => m.IconWebflow
    )
  ),
  todoist: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconTodoist").then(
      (m) => m.IconTodoist
    )
  ),
  npm: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconNpm").then(
      (m) => m.IconNpm
    )
  ),
  "stack-overflow": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconStackOverflow").then(
      (m) => m.IconStackOverflow
    )
  ),
  "product-hunt": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconProducthunt").then(
      (m) => m.IconProducthunt
    )
  ),
  replit: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconReplit").then(
      (m) => m.IconReplit
    )
  ),
  x: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconX").then(
      (m) => m.IconX
    )
  ),
  reddit: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconReddit").then(
      (m) => m.IconReddit
    )
  ),
  discord: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconDiscord").then(
      (m) => m.IconDiscord
    )
  ),
  telegram: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconTelegram").then(
      (m) => m.IconTelegram
    )
  ),
  wechat: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconWechat").then(
      (m) => m.IconWechat
    )
  ),
  whatsapp: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconWhatsapp").then(
      (m) => m.IconWhatsapp
    )
  ),
  tiktok: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconTiktok").then(
      (m) => m.IconTiktok
    )
  ),
  instagram: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconInstagram").then(
      (m) => m.IconInstagram
    )
  ),
  facebook: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconFacebook").then(
      (m) => m.IconFacebook
    )
  ),
  linkedin: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconLinkedin").then(
      (m) => m.IconLinkedin
    )
  ),
  threads: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconThreads").then(
      (m) => m.IconThreads
    )
  ),
  bluesky: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconBluesky").then(
      (m) => m.IconBluesky
    )
  ),
  pinterest: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconPinterest").then(
      (m) => m.IconPinterest
    )
  ),
  snapchat: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSnapchat").then(
      (m) => m.IconSnapchat
    )
  ),
  medium: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconMedium").then(
      (m) => m.IconMedium
    )
  ),
  substack: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSubstack").then(
      (m) => m.IconSubstack
    )
  ),
  youtube: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconYoutube").then(
      (m) => m.IconYoutube
    )
  ),
  spotify: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSpotify").then(
      (m) => m.IconSpotify
    )
  ),
  twitch: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconTwitch").then(
      (m) => m.IconTwitch
    )
  ),
  steam: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSteam").then(
      (m) => m.IconSteam
    )
  ),
  playstation: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconPlaystation").then(
      (m) => m.IconPlaystation
    )
  ),
  xbox: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconXbox").then(
      (m) => m.IconXbox
    )
  ),
  "nintendo-switch": lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconNintendoSwitch").then(
      (m) => m.IconNintendoSwitch
    )
  ),
  chrome: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconChrome").then(
      (m) => m.IconChrome
    )
  ),
  safari: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconSafari").then(
      (m) => m.IconSafari
    )
  ),
  firefox: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconFirefox").then(
      (m) => m.IconFirefox
    )
  ),
  duolingo: lazyBrandMark(() =>
    import("@central-icons-react/round-outlined-radius-2-stroke-2/IconDuolingo").then(
      (m) => m.IconDuolingo
    )
  ),
  openai: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconOpenai").then(
      (m) => m.IconOpenai
    )
  ),
  anthropic: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconAnthropic").then(
      (m) => m.IconAnthropic
    )
  ),
  claude: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconClaudeai").then(
      (m) => m.IconClaudeai
    )
  ),
  gemini: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconGemini").then(
      (m) => m.IconGemini
    )
  ),
  deepseek: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconDeepseek").then(
      (m) => m.IconDeepseek
    )
  ),
  qwen: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconQwen").then(
      (m) => m.IconQwen
    )
  ),
  kimi: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconKimi").then(
      (m) => m.IconKimi
    )
  ),
  minimax: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconMinimax").then(
      (m) => m.IconMinimax
    )
  ),
  mistral: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconMistral").then(
      (m) => m.IconMistral
    )
  ),
  "meta-ai": lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconMetaAi").then(
      (m) => m.IconMetaAi
    )
  ),
  grok: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconGrok").then(
      (m) => m.IconGrok
    )
  ),
  perplexity: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconPerplexity").then(
      (m) => m.IconPerplexity
    )
  ),
  midjourney: lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconMidjourney").then(
      (m) => m.IconMidjourney
    )
  ),
  "microsoft-copilot": lazyBrandMark(() =>
    import("@central-icons-react/round-filled-radius-2-stroke-2/IconMicrosoftCopilot").then(
      (m) => m.IconMicrosoftCopilot
    )
  ),
};

export type BrandKey = keyof typeof brandMarks;

/** Narrows a name from generated content to a catalogued brand. */
export const isBrandKey = (value: string): value is BrandKey =>
  Object.hasOwn(brandMarks, value);
