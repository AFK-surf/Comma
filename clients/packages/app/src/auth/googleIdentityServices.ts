const googleIdentityScriptId = "comma-google-identity-services";
const googleIdentityScriptSrc = "https://accounts.google.com/gsi/client";

export interface GoogleCredentialResponse {
  credential?: string;
}

interface GoogleIdentityApi {
  initialize(config: {
    callback: (response: GoogleCredentialResponse) => void;
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

interface GoogleIdentityServices {
  accounts: {
    id: GoogleIdentityApi;
  };
}

declare global {
  interface Window {
    google?: GoogleIdentityServices;
  }
}

let loader: Promise<GoogleIdentityServices> | undefined;

export function loadGoogleIdentityServices(): Promise<GoogleIdentityServices> {
  if (window.google?.accounts.id) {
    return Promise.resolve(window.google);
  }

  if (loader) {
    return loader;
  }

  loader = new Promise((resolve, reject) => {
    const existing = document.getElementById(googleIdentityScriptId);
    const script = existing instanceof HTMLScriptElement ? existing : createScript();

    const cleanup = () => {
      script.removeEventListener("load", loaded);
      script.removeEventListener("error", failed);
    };

    const rejectLoad = (message: string) => {
      cleanup();
      script.remove();
      loader = undefined;
      reject(new Error(message));
    };

    const loaded = () => {
      if (window.google?.accounts.id) {
        cleanup();
        resolve(window.google);
      } else {
        rejectLoad("Google sign-in did not initialize.");
      }
    };

    const failed = () => {
      rejectLoad("Google sign-in could not be loaded.");
    };

    script.addEventListener("load", loaded, { once: true });
    script.addEventListener("error", failed, { once: true });

    if (!existing) {
      document.head.append(script);
    }
  });

  return loader;
}

export async function renderGoogleSignInButton({
  clientId,
  element,
  nonce,
  onCredential,
}: {
  clientId: string;
  element: HTMLElement;
  nonce: string;
  onCredential: (response: GoogleCredentialResponse) => void;
}) {
  const google = await loadGoogleIdentityServices();

  element.replaceChildren();
  google.accounts.id.initialize({
    callback: onCredential,
    client_id: clientId,
    nonce,
    ux_mode: "popup",
  });
  google.accounts.id.renderButton(element, {
    shape: "rectangular",
    size: "large",
    text: "continue_with",
    theme: "outline",
    type: "standard",
    width: Math.max(240, Math.floor(element.getBoundingClientRect().width || 288)),
  });
}

function createScript() {
  const script = document.createElement("script");
  script.id = googleIdentityScriptId;
  script.src = googleIdentityScriptSrc;
  script.async = true;
  script.defer = true;
  return script;
}
