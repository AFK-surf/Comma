import { useEffect, type ReactNode } from "react";
import { useOptionalCommaClientSettings } from "../components/commaClientSettings";
import { markCommaClientReady, setCommaAnalyticsEnabled } from "./client";

/**
 * A committed product root plus session resolution is the client-ready
 * boundary. The analytics switch in Settings applies here as it changes,
 * including a change made in another window or tab.
 */
export function CommaAnalyticsLifecycle({ children }: { children: ReactNode }) {
  const enabled = useOptionalCommaClientSettings()?.usageAnalyticsEnabled;
  useEffect(markCommaClientReady, []);
  useEffect(() => {
    if (enabled !== undefined) setCommaAnalyticsEnabled(enabled);
  }, [enabled]);
  return children;
}
