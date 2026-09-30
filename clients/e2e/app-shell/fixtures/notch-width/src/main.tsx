import "../../../../../packages/app/src/styles.css";

import { createSettingsRegistry, NotchWidthSetting, SettingsDialog } from "@comma/ui";
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";

declare global {
  interface Window {
    /** Every width the setting handed to its owner, in order. */
    notchWidthCommits?: number[];
    /** Every width the reader asked to see on the real Notch. */
    notchWidthPreviews?: number[];
  }
}

const range = { min: 32, default: 156, max: 240 };

/**
 * Settings > General > Notch as the app composes it: the Settings dialog, its
 * page and the app stylesheet, whose rules apply to what happens inside.
 */
function NotchWidthFixture() {
  const [visible, setVisible] = useState(true);
  const [width, setWidth] = useState(range.default);

  const registry = createSettingsRegistry({
    groups: [
      {
        id: "application",
        label: "Application",
        categories: [
          {
            id: "general",
            icon: "general",
            label: "General",
            sections: [
              {
                id: "general.notch",
                title: "Notch",
                items: [
                  {
                    id: "app.notch",
                    title: "Show in notch",
                    description:
                      "Show running tasks and AirDrop transfers beside the notch at the top of the screen.",
                    control: {
                      type: "toggle",
                      checked: visible,
                      onChange: (event) => setVisible(event.target.checked),
                    },
                    content: visible ? (
                      <NotchWidthSetting
                        defaultValue={range.default}
                        labels={{
                          preview: "Preview on notch",
                          reset: "Reset",
                          sampleTitle: "Summarize this week’s meetings",
                          valueText: (points) => `${points} pt on each side`,
                          width: "Notch width",
                        }}
                        max={range.max}
                        min={range.min}
                        onPreview={(next) => {
                          window.notchWidthPreviews = [
                            ...(window.notchWidthPreviews ?? []),
                            next,
                          ];
                        }}
                        onValueCommit={(next) => {
                          window.notchWidthCommits = [
                            ...(window.notchWidthCommits ?? []),
                            next,
                          ];
                          setWidth(next);
                        }}
                        value={width}
                      />
                    ) : null,
                  },
                ],
              },
            ],
          },
          {
            id: "notifications",
            icon: "notifications",
            label: "Notifications",
            sections: [
              {
                id: "notifications.sound",
                title: "Sound",
                items: [
                  {
                    id: "notifications.sound.play",
                    title: "Play a sound",
                    control: {
                      type: "toggle",
                      checked: true,
                      onChange: () => undefined,
                    },
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
  });

  return (
    <SettingsDialog
      ariaLabel="Settings"
      closeLabel="Close"
      onClose={() => undefined}
      registry={registry}
      searchAriaLabel="Search settings"
      searchPlaceholder="Search"
    />
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <NotchWidthFixture />
  </StrictMode>
);
