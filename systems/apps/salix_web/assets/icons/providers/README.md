`codex.svg` and `claude.svg` come from [Lobe Icons](https://github.com/lobehub/lobe-icons/tree/master/packages/static-svg/icons).
The files use the upstream `codex-color.svg` and `claude-color.svg` variants without changes to their colors.
The included MIT license applies to these two SVG files.

The `model-anthropic.svg`, `model-claude.svg`, `model-google.svg`, `model-deepseek.svg`, `model-qwen.svg`, `model-glm.svg`, `model-kimi.svg`, `model-minimax.svg`, and `model-fireworks.svg` files come from the user-supplied `logo.zip`. The BFT Dashboard uses copies of these files.

The other `model-*.svg` files come from the installed Central Icons React package, `@central-icons-react/round-filled-radius-2-stroke-2`. OpenAI and Codex keep their existing icons because `logo.zip` has no matching files. The Lobe Icons license above applies only to `codex.svg` and `claude.svg`.

The Dashboard embeds these files as image data URLs at compile time. Each image keeps its SVG gradient identifiers isolated. It does not fetch icons from an external service.
