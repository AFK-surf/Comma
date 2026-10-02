import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@comma/ui/styles.css";
import { createBftApi } from "./api";
import { App } from "./App";
import { ApiContext } from "./resource";
import "./styles.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root element was not found.");
}

async function start(element: HTMLElement) {
  // Mock mode is a dev-only switch; the dynamic import keeps it out of real builds.
  let api = createBftApi();
  if (import.meta.env.VITE_BFT_MOCK === "1") {
    const mock = await import("./mockApi");
    // Phoenix injects the CSRF token into the served page; the mock page has none.
    if (!document.querySelector('meta[name="csrf-token"]')) {
      const meta = document.createElement("meta");
      meta.name = "csrf-token";
      meta.content = mock.mockCsrfToken;
      document.head.appendChild(meta);
    }
    api = createBftApi({ fetch: mock.mockFetch });
  }

  createRoot(element).render(
    <StrictMode>
      <ApiContext value={api}>
        <App />
      </ApiContext>
    </StrictMode>
  );
}

void start(root);
