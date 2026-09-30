import { RouterProvider, createRouter } from "@tanstack/react-router";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { routeTree } from "./routeTree.gen";
import { LocaleProvider } from "./i18n/locale";
import "./styles.css";

const router = createRouter({
  routeTree,
  parseSearch: (search) => {
    const result: Record<string, string | string[]> = {};
    for (const [key, value] of new URLSearchParams(search).entries()) {
      const current = result[key];
      result[key] = current
        ? Array.isArray(current)
          ? [...current, value]
          : [current, value]
        : value;
    }
    return result;
  },
  stringifySearch: (search) => {
    const result = new URLSearchParams();
    for (const [key, value] of Object.entries(search)) {
      if (value === undefined) continue;
      if (Array.isArray(value)) {
        for (const entry of value) result.append(key, String(entry));
      } else {
        result.set(key, String(value));
      }
    }
    const value = result.toString();
    return value ? `?${value}` : "";
  },
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

const rootElement = document.getElementById("root");
if (!rootElement) throw new Error("Root element not found");

createRoot(rootElement).render(
  <StrictMode>
    <LocaleProvider>
      <RouterProvider router={router} />
    </LocaleProvider>
  </StrictMode>
);
