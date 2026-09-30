import { useEffect, useMemo, useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui";
import { z } from "zod";
import { AppSettingsRoute } from "../../components/AppSettingsRoute";
import { useCommaAuth } from "../../components/auth-context";

const recommendationMockDebugSchema = z.object({
  available: z.boolean(),
  enabled: z.boolean(),
  syncError: z.boolean().optional(),
});

type CommaRecommendationMockDebug = z.output<typeof recommendationMockDebugSchema>;

export function RecommendationMockDebugSettingsRoute() {
  const auth = useCommaAuth();
  // The dev app also targets staging. Its local-only debug endpoint must not
  // be probed with a real session: an upstream 401 invalidates the native lease.
  const hostname = new URL(auth.productLease.audience).hostname;
  if (!["localhost", "127.0.0.1", "[::1]"].includes(hostname)) {
    return <AppSettingsRoute />;
  }
  return <LocalRecommendationMockDebugSettingsRoute />;
}

function LocalRecommendationMockDebugSettingsRoute() {
  const m = useCommaMessages();
  const auth = useCommaAuth();
  const { api } = auth;
  const debugApi = useMemo(() => {
    const request = async (
      method: "GET" | "PATCH",
      enabled?: boolean,
      workspaceId?: string,
      signal?: AbortSignal
    ) => {
      const headers: Record<string, string> = { accept: "application/json" };
      if (enabled !== undefined) headers["content-type"] = "application/json";
      auth.sessionTransport?.applyHeaders(headers);
      const init: RequestInit = {
        credentials: auth.sessionTransport?.credentials ?? "include",
        headers,
        method,
        signal: signal ?? auth.sessionTransport?.signal,
      };
      if (enabled !== undefined) init.body = JSON.stringify({ enabled, workspaceId });
      const response = await fetch(
        `${auth.apiBaseUrl.replace(/\/+$/, "")}/v1/debug/recommendation-mock`,
        init
      );
      if (!response.ok) {
        if (response.status === 401 || response.status === 409) {
          auth.sessionTransport?.reportSessionRejection(response.status);
        }
        throw new Error(
          `Recommendation mock debug request failed (${response.status})`
        );
      }
      return recommendationMockDebugSchema.parse(await response.json());
    };

    return {
      get: (signal?: AbortSignal) => request("GET", undefined, undefined, signal),
      update: (enabled: boolean, workspaceId?: string) =>
        request("PATCH", enabled, workspaceId),
    };
  }, [auth.apiBaseUrl, auth.sessionTransport]);
  const [status, setStatus] = useState<CommaRecommendationMockDebug>();
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState<string>();

  useEffect(() => {
    const controller = new AbortController();
    setPending(true);
    void debugApi
      .get(controller.signal)
      .then(setStatus)
      .catch(() => {
        if (!controller.signal.aborted) {
          setMessage(m.settings_debug_recommendation_mock_unavailable());
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setPending(false);
      });
    return () => controller.abort();
  }, [debugApi, m]);

  const updateEnabled = async (enabled: boolean) => {
    if (pending) return;
    setPending(true);
    setMessage(undefined);
    try {
      const [workspace] = await api.listWorkspaces();
      const next = await debugApi.update(enabled, workspace?.id);
      setStatus(next);
      setMessage(
        next.syncError
          ? m.settings_debug_recommendation_mock_sync_failed()
          : enabled
            ? m.settings_debug_recommendation_mock_enabled_notice()
            : m.settings_debug_recommendation_mock_disabled_notice()
      );
    } catch {
      setMessage(m.settings_debug_recommendation_mock_save_failed());
    } finally {
      setPending(false);
    }
  };

  const refreshRecommendations = async () => {
    if (pending || !status?.enabled) return;
    setPending(true);
    setMessage(undefined);
    try {
      const [workspace] = await api.listWorkspaces();
      if (!workspace) throw new Error("workspace unavailable");
      await api.refreshRecommendations(workspace.id);
      setMessage(m.settings_debug_recommendation_mock_refresh_started());
    } catch {
      setMessage(m.settings_debug_recommendation_mock_refresh_failed());
    } finally {
      setPending(false);
    }
  };

  const debugCategory: SettingsCategoryDefinition = {
    id: "debug",
    icon: "debug",
    label: m.settings_debug(),
    sections: [
      {
        id: "debug.recommendations",
        title: m.settings_debug_recommendations(),
        items: [
          {
            id: "debug.recommendations.mock",
            title: m.settings_debug_recommendation_mock(),
            description: message ?? m.settings_debug_recommendation_mock_description(),
            keywords: ["mock", "routines", "MCP", "OAuth", "调试"],
            control: {
              type: "toggle",
              checked: status?.enabled ?? false,
              disabled: pending || !status?.available,
              onChange: (event) => void updateEnabled(event.target.checked),
            },
          },
          {
            id: "debug.recommendations.refresh",
            title: m.settings_debug_recommendation_refresh(),
            description: m.settings_debug_recommendation_refresh_description(),
            control: {
              type: "button",
              disabled: pending || !status?.enabled,
              label: m.settings_debug_recommendation_refresh_action(),
              onPress: () => void refreshRecommendations(),
            },
          },
        ],
      },
    ],
  };

  return <AppSettingsRoute additionalSystemCategories={[debugCategory]} />;
}
