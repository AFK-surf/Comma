import { cardIconDefaults } from "@comma/chat-contract/dynamic-ui-cards";
import { ClockIcon, CircleInfoIcon } from "@comma/ui/components/icons";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, it } from "vitest";
import { cardIconMarkup } from "../cardHost";

it("the glyphs the phone host page carries are the ones this app draws", () => {
  // Phones start a widget with no icons; the shared host page gives it these.
  // Regenerate with `pnpm --filter @comma/chat-contract generate:card-icon-defaults`.
  expect(cardIconDefaults).toEqual({
    ...cardIconMarkup(),
    clock: renderToStaticMarkup(<ClockIcon />),
    info: renderToStaticMarkup(<CircleInfoIcon />),
  });
});
