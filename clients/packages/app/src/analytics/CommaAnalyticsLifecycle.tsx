import { useEffect, type ReactNode } from "react";
import { markCommaClientReady } from "./client";

/** A committed product root plus session resolution is the client-ready boundary. */
export function CommaAnalyticsLifecycle({ children }: { children: ReactNode }) {
  useEffect(markCommaClientReady, []);
  return children;
}
