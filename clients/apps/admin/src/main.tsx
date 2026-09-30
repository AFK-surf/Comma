import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaSessionHostProvider,
  createBrowserSessionHostPorts,
  createWebSessionHostController,
} from "@comma/app/auth";
import "@comma/ui/styles.css";
import "@comma/app/auth/styles.css";
import { AdminApp } from "./AdminApp";
import { adminApiBaseUrl } from "./runtime";
import "./styles.css";

const root = document.getElementById("root");

if (!root) {
  throw new Error("Root element was not found.");
}

const sessionController = createWebSessionHostController({
  apiBaseUrl: adminApiBaseUrl(),
  ports: createBrowserSessionHostPorts({
    read: (key) => localStorage.getItem(key),
    write: (key, value) => localStorage.setItem(key, value),
  }),
});

createRoot(root).render(
  <StrictMode>
    <CommaSessionHostProvider controller={sessionController}>
      <AdminApp />
    </CommaSessionHostProvider>
  </StrictMode>
);
