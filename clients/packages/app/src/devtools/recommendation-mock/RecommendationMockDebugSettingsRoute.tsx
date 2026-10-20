import { useCall, useTopic } from "@comma/core-client";
import { useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { AppSettingsRoute } from "../../components/AppSettingsRoute";
import { useCommaAuth } from "../../components/auth-context";

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
  const call = useCall();
  const { value: shown } = useTopic({ topic: "recommendationMock" }, { lingerMs: 0 });
  const status = shown?.status === "ready" ? shown : undefined;
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string>();
  const pending = busy || shown === null || shown === undefined;
  const shownMessage =
    message ??
    (shown?.status === "failed"
      ? m.settings_debug_recommendation_mock_unavailable()
      : undefined);

  const updateEnabled = async (enabled: boolean) => {
    if (pending) return;
    setBusy(true);
    setMessage(undefined);
    try {
      const next = await call("recommendationMock.set", { enabled });
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
      setBusy(false);
    }
  };

  const refreshRecommendations = async () => {
    if (pending || !status?.enabled) return;
    setBusy(true);
    setMessage(undefined);
    try {
      await call("recommendationMock.refresh", {});
      setMessage(m.settings_debug_recommendation_mock_refresh_started());
    } catch {
      setMessage(m.settings_debug_recommendation_mock_refresh_failed());
    } finally {
      setBusy(false);
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
            description:
              shownMessage ?? m.settings_debug_recommendation_mock_description(),
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
