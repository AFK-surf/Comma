import { useEffect, useState } from "react";
import {
  askScreenCase,
  askScreenCaseRest,
  screenCaseCame,
  screenCaseOf,
  type ScreenCase,
  type ScreenCasePictures,
  type ScreenStreamChrome,
} from "./screenCase";
import type { ScreenTurn } from "./screenDevice";

/**
 * A simulator's case as it stands now, once its pictures have come and are decoded: those of this panel and way first,
 * then the rest one after another, so that a turn or a fold finds them there (still.fail's screen_case.mbt `case_ask`).
 * Until then, and where there is no case, none: the frame draws its plain body.
 */
export function useScreenCase(
  chrome: ScreenStreamChrome | undefined,
  pictureRatio: number | undefined,
  turn: ScreenTurn
): { layout: ScreenCase; pictures: ScreenCasePictures } | undefined {
  const layout = chrome ? screenCaseOf(chrome.panels, pictureRatio, turn) : undefined;
  const [, setCame] = useState(0);
  const panel = layout?.panel;
  const quarter = layout?.turn;
  useEffect(() => {
    if (!chrome || panel === undefined || quarter === undefined) return undefined;
    let live = true;
    askScreenCase(chrome, panel, quarter)
      .then(() => {
        if (live) setCame((n) => n + 1);
        return askScreenCaseRest(chrome);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [chrome, panel, quarter]);
  const pictures =
    chrome && layout ? screenCaseCame(chrome, layout.key, layout.turn) : undefined;
  return layout && pictures ? { layout, pictures } : undefined;
}
