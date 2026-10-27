import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { ToastProvider } from "./components/toast";
import "./index.css";

// Inside Comma, the runtime installs window.comma before this script runs.
// Outside Comma (`npm run dev`), an in-memory mock stands in for it.
if (import.meta.env.DEV && !("comma" in window)) {
  const { installMockComma } = await import("./comma/mock");
  installMockComma();
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ToastProvider>
      <App />
    </ToastProvider>
  </StrictMode>,
);
