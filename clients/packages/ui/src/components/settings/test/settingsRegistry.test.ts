import { describe, expect, it } from "vitest";
import { createSettingsRegistry } from "../settingsRegistry";

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
              id: "general.behavior",
              title: "Behavior",
              items: [
                {
                  id: "app.launch-at-login",
                  title: "Launch Comma at login",
                  description: "Start Comma when signing in.",
                  keywords: ["startup", "boot"],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
});

describe("createSettingsRegistry", () => {
  it("indexes visible copy and explicit search aliases", () => {
    expect(registry.search("launch")).toHaveLength(1);
    expect(registry.search("signing")).toHaveLength(1);
    expect(registry.search("startup")).toHaveLength(1);
    expect(registry.search("missing")).toEqual([]);
  });

  it("indexes integration account facts, status and scope", () => {
    const channels = createSettingsRegistry({
      groups: [
        {
          id: "application",
          categories: [
            {
              id: "channels",
              icon: "general",
              label: "Channels",
              sections: [
                {
                  id: "telegram",
                  title: "",
                  items: [
                    {
                      id: "telegram.connection",
                      title: "Telegram",
                      integration: {
                        status: { label: "Connected", color: "success" },
                        details: [
                          { label: "Account", value: "@ada" },
                          {
                            label: "Comma bot",
                            value: "@CommaTestBot",
                            actionLabel: "Open in Telegram",
                          },
                        ],
                        note: "Private chats only.",
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
    expect(channels.search("@ada")).toHaveLength(1);
    expect(channels.search("connected")).toHaveLength(1);
    expect(channels.search("private")).toHaveLength(1);
    expect(channels.search("open in telegram")).toHaveLength(1);
  });

  it("rejects duplicate stable setting ids", () => {
    expect(() =>
      createSettingsRegistry({
        groups: [
          {
            id: "application",
            categories: [
              {
                id: "general",
                icon: "general",
                label: "General",
                sections: [
                  {
                    id: "one",
                    title: "One",
                    items: [{ id: "duplicate", title: "First" }],
                  },
                  {
                    id: "two",
                    title: "Two",
                    items: [{ id: "duplicate", title: "Second" }],
                  },
                ],
              },
            ],
          },
        ],
      })
    ).toThrow('Duplicate settings item id: "duplicate".');
  });
});
