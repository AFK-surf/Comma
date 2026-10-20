// The page Admin runs in: its URL and history, the width it is shown at, and the clipboard. Models use it through
// Effect, so tests can run them against jsdom's page.
import { legacyCommaLocaleStorageKey, type CommaLocale } from "@comma/i18n";
import { Context, Effect, Layer, Stream } from "effect";

export class AdminBrowser extends Context.Service<
  AdminBrowser,
  {
    /** The page's URL (`location.href`). */
    readonly href: Effect.Effect<string>;
    /** Adds a history entry for `href` (a path with its query). */
    readonly push: (href: string) => Effect.Effect<void>;
    /** Sets or removes query parameters of the current history entry. */
    readonly replaceParams: (
      params: Record<string, string | undefined>
    ) => Effect.Effect<void>;
    /** Each browser back or forward navigation. */
    readonly popstate: Stream.Stream<void>;
    /** Each time the browser goes back online. */
    readonly online: Stream.Stream<void>;
    /** Whether the page is as narrow as a phone (the navigation is a drawer there). */
    readonly narrow: Effect.Effect<boolean>;
    readonly copy: (text: string) => Effect.Effect<void, unknown>;
    /** Keeps `locale` as the page's language (the key Comma's clients share) and reloads the page in it. */
    readonly setLocale: (locale: CommaLocale) => Effect.Effect<void>;
  }
>()("admin/AdminBrowser") {}

export const AdminBrowserLive = Layer.sync(AdminBrowser, () =>
  AdminBrowser.of({
    href: Effect.sync(() => window.location.href),
    push: (href) => Effect.sync(() => window.history.pushState(null, "", href)),
    replaceParams: (params) =>
      Effect.sync(() => {
        const url = new URL(window.location.href);
        for (const [name, value] of Object.entries(params)) {
          if (value) url.searchParams.set(name, value);
          else url.searchParams.delete(name);
        }
        if (url.href !== window.location.href) {
          window.history.replaceState(window.history.state, "", url);
        }
      }),
    popstate: Stream.fromEventListener(window, "popstate").pipe(Stream.as(undefined)),
    online: Stream.fromEventListener(window, "online").pipe(Stream.as(undefined)),
    narrow: Effect.sync(() => window.matchMedia("(max-width: 900px)").matches),
    copy: (text) => Effect.tryPromise(() => navigator.clipboard.writeText(text)),
    setLocale: (locale) =>
      Effect.sync(() => {
        try {
          window.localStorage.setItem(legacyCommaLocaleStorageKey, locale);
        } catch {
          // Without storage the page keeps following the browser's language.
        }
        window.location.reload();
      }),
  })
);
