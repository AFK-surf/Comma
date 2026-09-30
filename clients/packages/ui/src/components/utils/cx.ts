import { extendTailwindMerge } from "tailwind-merge";

const twMerge = extendTailwindMerge({
  extend: {
    theme: {
      text: [
        "display-2xl",
        "display-xl",
        "display-lg",
        "display-md",
        "display-sm",
        "display-xs",
        "micro",
        "mini",
        "small",
        "regular",
        "large",
        "title-3",
        "title-2",
        "title-1",
      ],
    },
  },
});

export const cx = (...classes: Array<string | false | null | undefined>) =>
  twMerge(classes.filter(Boolean).join(" "));
