// Admin's services, composed: the fetch wrapper, the session (auth), the Admin API, the page and the dashboard shell.
import { Layer } from "effect";
import { AdminApiLive } from "./adminApi";
import { AdminBrowserLive, type AdminBrowser } from "./adminBrowser";
import { AdminConfig, AdminFetchLive, type AdminFetch } from "./adminHttp";
import type { AdminServices } from "./adminRuntime";
import { AdminShellLive } from "./adminShell";
import { AdminAuthLive, type GoogleIdentity } from "./auth";
import { GoogleIdentityLive } from "./googleIdentity";

/** Admin's services over `fetch` and the page, for the API at `apiBaseUrl`. */
export function adminLayer(options: {
  apiBaseUrl: string;
  browser?: Layer.Layer<AdminBrowser>;
  google?: Layer.Layer<GoogleIdentity>;
}) {
  const config = Layer.succeed(
    AdminConfig,
    AdminConfig.of({ apiBaseUrl: options.apiBaseUrl })
  );
  return adminServices({
    browser: options.browser ?? AdminBrowserLive,
    fetch: AdminFetchLive.pipe(Layer.provide(config)),
    google: options.google ?? GoogleIdentityLive,
  });
}

/** Admin's services over the given page, fetch and Google layers (tests give fakes). */
export function adminServices(layers: {
  browser: Layer.Layer<AdminBrowser>;
  fetch: Layer.Layer<AdminFetch>;
  google: Layer.Layer<GoogleIdentity>;
}): Layer.Layer<AdminServices> {
  const auth = AdminAuthLive.pipe(
    Layer.provide(Layer.mergeAll(layers.fetch, layers.google, layers.browser))
  );
  const api = AdminApiLive.pipe(Layer.provide(Layer.merge(layers.fetch, auth)));
  const shell = AdminShellLive.pipe(
    Layer.provide(Layer.mergeAll(auth, api, layers.browser))
  );
  return Layer.mergeAll(auth, api, layers.browser, shell);
}
