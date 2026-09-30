import type { ApplicationMenuItems } from "@comma/native-bridge";

export type ApplicationMenuPresentation = {
  items: ApplicationMenuItems;
  locale: "en" | "zh-CN";
};
/** Holds the renderer's latest menu presentation for every Main menu. */
export class ApplicationMenuProvider {
  #latest: ApplicationMenuPresentation | undefined;
  readonly #listeners = new Set<(items: ApplicationMenuPresentation) => void>();
  update = (items: ApplicationMenuPresentation): void => {
    this.#latest = items;
    for (const listener of this.#listeners) listener(items);
  };
  /** Replays the latest presentation, then delivers each update. */
  subscribe(listener: (items: ApplicationMenuPresentation) => void) {
    this.#listeners.add(listener);
    if (this.#latest) listener(this.#latest);
    return () => {
      this.#listeners.delete(listener);
    };
  }
}
export const applicationMenuProvider = new ApplicationMenuProvider();
