// Google Identity Services in the browser: the script is loaded once (a failed load is removed so the next try loads it
// again), then Google draws its own sign-in button, which returns an ID token for the attempt's nonce in a popup.
import { Effect, Layer } from "effect";
import { GoogleIdentity, GoogleUnavailable } from "./auth";
import { messages } from "@comma/i18n";

const scriptId = "comma-google-identity-services";
const scriptSrc = "https://accounts.google.com/gsi/client";

interface GoogleIdApi {
  initialize(config: {
    callback: (response: { credential?: string }) => void;
    client_id: string;
    nonce: string;
    ux_mode: "popup";
  }): void;
  renderButton(
    parent: HTMLElement,
    options: {
      shape: "rectangular";
      size: "large";
      text: "continue_with";
      theme: "outline";
      type: "standard";
      width: number;
    }
  ): void;
}

const googleId = () =>
  (window as { google?: { accounts?: { id?: GoogleIdApi } } }).google?.accounts?.id;

const load = Effect.callback<GoogleIdApi, GoogleUnavailable>((resume) => {
  const ready = googleId();
  if (ready) {
    resume(Effect.succeed(ready));
    return;
  }
  const existing = document.getElementById(scriptId);
  const script =
    existing instanceof HTMLScriptElement ? existing : document.createElement("script");
  const cleanup = () => {
    script.removeEventListener("load", loaded);
    script.removeEventListener("error", failed);
  };
  const reject = (message: string) => {
    cleanup();
    script.remove();
    resume(Effect.fail(new GoogleUnavailable({ message })));
  };
  const loaded = () => {
    const api = googleId();
    if (api) {
      cleanup();
      resume(Effect.succeed(api));
    } else {
      reject(messages.admin_google_init_failed());
    }
  };
  const failed = () => reject(messages.admin_google_load_failed());
  script.addEventListener("load", loaded, { once: true });
  script.addEventListener("error", failed, { once: true });
  if (!existing) {
    script.id = scriptId;
    script.src = scriptSrc;
    script.async = true;
    script.defer = true;
    document.head.append(script);
  }
  return Effect.sync(cleanup);
});

export const GoogleIdentityLive = Layer.succeed(
  GoogleIdentity,
  GoogleIdentity.of({
    render: ({ clientId, element, nonce, onCredential }) =>
      load.pipe(
        Effect.flatMap((api) =>
          Effect.sync(() => {
            element.replaceChildren();
            api.initialize({
              callback: (response) => onCredential(response.credential),
              client_id: clientId,
              nonce,
              ux_mode: "popup",
            });
            api.renderButton(element, {
              shape: "rectangular",
              size: "large",
              text: "continue_with",
              theme: "outline",
              type: "standard",
              width: Math.max(
                240,
                Math.floor(element.getBoundingClientRect().width || 288)
              ),
            });
          })
        )
      ),
  })
);
