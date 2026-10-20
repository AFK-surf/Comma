import {
  initializeCommaI18n,
  readLegacyCommaLocalePreference,
  resolveLocalePreference,
} from "@comma/i18n";
import { Effect, ManagedRuntime } from "effect";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "@comma/ui/styles.css";
import { AdminApp } from "./AdminApp";
import { adminLayer } from "./adminLayer";
import { AdminRuntimeProvider } from "./adminRuntime";
import { AdminAuth } from "./auth";
import { adminApiBaseUrl } from "./runtime";
import "./styles.css";

// The page's language: the one chosen in the account menu (shared with Comma's clients), else the browser's.
initializeCommaI18n([resolveLocalePreference(readLegacyCommaLocalePreference())]);

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root element was not found.");
}

const apiBaseUrl = adminApiBaseUrl();
const runtime = ManagedRuntime.make(adminLayer({ apiBaseUrl }));
// The services start before the first render, which shows them; the session is read once, at startup.
await runtime.runPromise(Effect.void);
runtime.runFork(AdminAuth.use((auth) => auth.start));

createRoot(root).render(
  <StrictMode>
    <AdminRuntimeProvider runtime={runtime}>
      <AdminApp apiBaseUrl={apiBaseUrl} />
    </AdminRuntimeProvider>
  </StrictMode>
);
