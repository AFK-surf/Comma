import userEvent from "@testing-library/user-event";
import { act, fireEvent, render, screen, within } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import {
  PluginArtwork,
  PluginCatalog,
  PluginDetail,
  PluginListItem,
  type PluginCategory,
  type PluginDefinition,
} from "../Plugins";

const notionPlugin: PluginDefinition = {
  id: "notion",
  name: "Notion",
  summary: "Search and update your workspace",
};

const linearPlugin: PluginDefinition = {
  id: "linear",
  name: "Linear",
  summary: "Plan and track product work",
};

const createDOMRect = (left: number, top: number, width: number, height: number) =>
  ({
    bottom: top + height,
    height,
    left,
    right: left + width,
    toJSON: () => ({}),
    top,
    width,
    x: left,
    y: top,
  }) satisfies DOMRect;

const zhCatalogCopy = {
  addLabel: "添加",
  addPluginAriaLabel: (name: string) => `添加 ${name}`,
  emptyLabel: "未找到插件",
  installedLabel: "已安装",
  manageLabel: "管理",
  openPluginAriaLabel: (name: string) => `查看 ${name} 插件详情`,
  searchAriaLabel: "搜索插件",
  searchPlaceholder: "搜索插件…",
  showAllCategoryAriaLabel: (category: string) => `显示全部 ${category} 插件`,
  showAllLabel: "显示全部",
  title: "插件",
};

const zhDetailCopy = {
  backLabel: "返回插件列表",
  descriptionLabel: "描述",
  installLabel: "添加到 Comma",
  installPluginAriaLabel: (name: string) => `将 ${name} 添加到 Comma`,
  manageLabel: "管理",
  mcpsLabel: "MCP",
  skillsLabel: "技能",
  tryInChatLabel: "在聊天中试用",
  tryPluginInChatAriaLabel: (name: string) => `在聊天中试用 ${name}`,
  uninstallLabel: "卸载",
  uninstallPluginAriaLabel: (name: string) => `卸载 ${name}`,
};

describe("Plugins", () => {
  it("matches the settings titlebar spacing and catalog title scale", () => {
    const { container, rerender } = render(<PluginCatalog categories={[]} />);

    expect(container.querySelector('[data-slot="plugin-catalog"]')).toHaveClass(
      "relative"
    );
    expect(container.querySelector('[data-slot="plugin-titlebar-drag"]')).toBeNull();
    expect(screen.getByRole("heading", { level: 1, name: "Plugins" })).toHaveClass(
      "text-balance",
      "text-xl"
    );
    expect(
      container.querySelector('[data-slot="plugin-catalog"] [class~="pt-7xl"]')
    ).not.toBeNull();

    rerender(<PluginDetail plugin={notionPlugin} />);

    expect(container.querySelector('[data-slot="plugin-detail"]')).toHaveClass(
      "relative"
    );
    expect(container.querySelector('[data-slot="plugin-titlebar-drag"]')).toBeNull();
    expect(
      container.querySelector('[data-slot="plugin-detail"] [class~="pt-7xl"]')
    ).not.toBeNull();
  });

  it("matches the bordered plugin artwork treatment", () => {
    render(<PluginArtwork icon={<svg data-testid="plugin-glyph" />} />);

    const artwork = screen.getByTestId("plugin-glyph").parentElement;

    expect(artwork).toHaveClass(
      "size-11",
      "rounded-md",
      "border",
      "border-primary",
      "bg-primary",
      "text-primary",
      "[&_svg]:size-6"
    );
  });

  it("renders installed plugins as openable cards and reports pointer opens", async () => {
    const user = userEvent.setup();
    const onPluginOpen = vi.fn();

    render(
      <PluginCatalog
        categories={[]}
        installedPlugins={[notionPlugin]}
        onPluginOpen={onPluginOpen}
      />
    );

    const openButton = screen.getByRole("button", {
      name: "View Notion plugin details",
    });

    expect(openButton).toHaveAttribute("data-slot", "plugin-installed-card");
    expect(openButton).toHaveClass("comma-plugin-card");
    expect(within(openButton).getByText("Installed")).toBeInTheDocument();

    await user.click(openButton);

    expect(onPluginOpen).toHaveBeenCalledOnce();
    expect(onPluginOpen).toHaveBeenCalledWith(notionPlugin, "pointer");
  });

  it("keeps the details and Add buttons as siblings and does not open from Add", async () => {
    const user = userEvent.setup();
    const onAction = vi.fn();
    const onOpen = vi.fn();

    render(
      <PluginListItem
        actionLabel="Add"
        onAction={onAction}
        onOpen={onOpen}
        plugin={linearPlugin}
      />
    );

    const openButton = screen.getByRole("button", {
      name: "View Linear plugin details",
    });
    const addButton = screen.getByRole("button", { name: "Add Linear" });

    expect(openButton.parentElement).toBe(addButton.parentElement);
    expect(openButton).not.toContainElement(addButton);
    expect(addButton).not.toContainElement(openButton);

    await user.click(addButton);

    expect(onAction).toHaveBeenCalledOnce();
    expect(onAction).toHaveBeenCalledWith(linearPlugin);
    expect(onOpen).not.toHaveBeenCalled();
  });

  it("opens the shared Collapse and removes Show all after expansion", async () => {
    const user = userEvent.setup();
    const onPluginInstall = vi.fn();
    const onPluginOpen = vi.fn();
    const plugins = [
      notionPlugin,
      linearPlugin,
      {
        id: "github",
        icon: <svg data-testid="github-show-all-icon" />,
        name: "GitHub",
        summary: "Work with repositories",
      },
      {
        id: "slack",
        icon: <svg data-testid="slack-show-all-icon" />,
        name: "Slack",
        summary: "Collaborate with your team",
      },
    ] satisfies readonly PluginDefinition[];
    const { container } = render(
      <PluginCatalog
        categories={[
          {
            id: "productivity",
            name: "Productivity",
            plugins,
          },
        ]}
        categoryPreviewCount={2}
        onPluginInstall={onPluginInstall}
        onPluginOpen={onPluginOpen}
      />
    );

    expect(screen.getByText("Notion")).toBeInTheDocument();
    expect(screen.getByText("Linear")).toBeInTheDocument();
    expect(screen.queryByText("GitHub")).not.toBeInTheDocument();
    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "closed"
    );

    const showAllButton = screen.getByRole("button", {
      name: "Show all Productivity plugins",
    });
    expect(showAllButton).toHaveAttribute("aria-expanded", "false");
    expect(within(showAllButton).getByTestId("github-show-all-icon")).toBeVisible();
    expect(within(showAllButton).getByTestId("slack-show-all-icon")).toBeVisible();
    expect(showAllButton.querySelectorAll("[data-plugin-id]")).toHaveLength(2);

    await user.click(showAllButton);

    expect(screen.getByText("GitHub")).toBeInTheDocument();
    expect(screen.getByText("Slack")).toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Show all Productivity plugins" })
    ).toBeNull();
    expect(
      screen.getByRole("button", { name: "View GitHub plugin details" })
    ).toHaveFocus();

    await user.tab();
    expect(screen.getByRole("button", { name: "Add GitHub" })).toHaveFocus();
    expect(container.querySelector(".collapse-container")).toHaveAttribute(
      "data-state",
      "open"
    );
  });

  it("expands immediately without WAAPI motion from the keyboard", async () => {
    const user = userEvent.setup();
    const animate = vi.fn();
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );

    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    try {
      render(
        <PluginCatalog
          categories={[
            {
              id: "productivity",
              name: "Productivity",
              plugins: [
                notionPlugin,
                linearPlugin,
                {
                  id: "github",
                  name: "GitHub",
                  summary: "Work with repositories",
                },
                {
                  id: "slack",
                  name: "Slack",
                  summary: "Collaborate with your team",
                },
              ],
            },
          ]}
          categoryPreviewCount={2}
          onPluginOpen={vi.fn()}
        />
      );

      const showAllButton = screen.getByRole("button", {
        name: "Show all Productivity plugins",
      });
      showAllButton.focus();

      await user.keyboard("{Enter}");

      expect(animate).not.toHaveBeenCalled();
      expect(screen.getByText("GitHub")).toBeVisible();
      expect(
        screen.getByRole("button", { name: "View GitHub plugin details" })
      ).toHaveFocus();
    } finally {
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it.each([
    { commaSetting: false, source: "system preference", systemMatches: true },
    { commaSetting: true, source: "Comma setting", systemMatches: false },
  ])(
    "keeps only a short opacity reveal when reduced motion is requested by $source",
    async ({ commaSetting, systemMatches }) => {
      const user = userEvent.setup();
      const animate = vi.fn(
        (
          _keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
          _options?: number | KeyframeAnimationOptions
        ) => {
          const animation = new EventTarget() as Animation;
          animation.cancel = vi.fn();
          return animation;
        }
      );
      const animateDescriptor = Object.getOwnPropertyDescriptor(
        Element.prototype,
        "animate"
      );
      const matchMediaDescriptor = Object.getOwnPropertyDescriptor(
        window,
        "matchMedia"
      );
      const matchMedia = vi.fn(
        (query: string) =>
          ({
            addEventListener: vi.fn(),
            addListener: vi.fn(),
            dispatchEvent: vi.fn(),
            matches: systemMatches && query === "(prefers-reduced-motion: reduce)",
            media: query,
            onchange: null,
            removeEventListener: vi.fn(),
            removeListener: vi.fn(),
          }) as MediaQueryList
      );

      Object.defineProperty(Element.prototype, "animate", {
        configurable: true,
        value: animate,
      });
      Object.defineProperty(window, "matchMedia", {
        configurable: true,
        value: matchMedia,
      });

      if (commaSetting) {
        document.documentElement.setAttribute("data-comma-reduced-motion", "true");
      }

      try {
        render(
          <PluginCatalog
            categories={[
              {
                id: "productivity",
                name: "Productivity",
                plugins: [
                  notionPlugin,
                  linearPlugin,
                  {
                    id: "github",
                    name: "GitHub",
                    summary: "Work with repositories",
                  },
                  {
                    id: "slack",
                    name: "Slack",
                    summary: "Collaborate with your team",
                  },
                ],
              },
            ]}
            categoryPreviewCount={2}
          />
        );

        await user.click(
          screen.getByRole("button", {
            name: "Show all Productivity plugins",
          })
        );

        expect(animate).toHaveBeenCalledTimes(2);
        expect(animate.mock.calls[0]?.[0]).toEqual([{ opacity: 0 }, { opacity: 1 }]);
        expect(animate.mock.calls.map((call) => call[1])).toEqual([
          {
            delay: 0,
            duration: 120,
            easing: "cubic-bezier(0.16, 1, 0.3, 1)",
            fill: "both",
          },
          {
            delay: 0,
            duration: 120,
            easing: "cubic-bezier(0.16, 1, 0.3, 1)",
            fill: "both",
          },
        ]);
      } finally {
        document.documentElement.removeAttribute("data-comma-reduced-motion");
        if (matchMediaDescriptor) {
          Object.defineProperty(window, "matchMedia", matchMediaDescriptor);
        } else {
          Reflect.deleteProperty(window, "matchMedia");
        }
        if (animateDescriptor) {
          Object.defineProperty(Element.prototype, "animate", animateDescriptor);
        } else {
          Reflect.deleteProperty(Element.prototype, "animate");
        }
      }
    }
  );

  it("moves preview artwork into the matching revealed plugin rows", async () => {
    const user = userEvent.setup();
    const animations: Animation[] = [];
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
        _options?: number | KeyframeAnimationOptions
      ) => {
        const animation = new EventTarget() as Animation;
        animation.cancel = vi.fn();
        animations.push(animation);
        return animation;
      }
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );
    const offsetWidthDescriptor = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "offsetWidth"
    );
    const offsetHeightDescriptor = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "offsetHeight"
    );
    const getBoundingClientRect = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        const element = this as HTMLElement;
        if (element.dataset.slot !== "plugin-artwork") {
          return createDOMRect(0, 0, 0, 0);
        }

        const pluginId =
          element.closest<HTMLElement>("[data-plugin-id]")?.dataset.pluginId;
        const isPreview = element.closest('[data-slot="plugin-show-all"]');

        if (isPreview) {
          return pluginId === "github"
            ? createDOMRect(79, 299, 18, 18)
            : createDOMRect(93, 299, 18, 18);
        }

        return pluginId === "github"
          ? createDOMRect(80, 300, 44, 44)
          : createDOMRect(80, 372, 44, 44);
      });

    Object.defineProperties(HTMLElement.prototype, {
      offsetHeight: {
        configurable: true,
        get() {
          return this.dataset.slot === "plugin-artwork" &&
            this.closest('[data-slot="plugin-show-all"]')
            ? 16
            : 0;
        },
      },
      offsetWidth: {
        configurable: true,
        get() {
          return this.dataset.slot === "plugin-artwork" &&
            this.closest('[data-slot="plugin-show-all"]')
            ? 16
            : 0;
        },
      },
    });
    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    try {
      render(
        <PluginCatalog
          categories={[
            {
              id: "productivity",
              name: "Productivity",
              plugins: [
                notionPlugin,
                linearPlugin,
                {
                  id: "github",
                  icon: (
                    <svg>
                      <defs>
                        <mask id="github-plugin-mask">
                          <rect fill="white" height="24" width="24" />
                        </mask>
                        <mask id="github-plugin-mask-long">
                          <rect fill="white" height="24" width="24" />
                        </mask>
                        <linearGradient id="fff">
                          <stop stopColor="white" />
                        </linearGradient>
                      </defs>
                      <rect
                        fill="#ffffff"
                        height="24"
                        mask="url(#github-plugin-mask-long)"
                        width="24"
                      />
                      <use href="#github-plugin-mask" />
                    </svg>
                  ),
                  name: "GitHub",
                  summary: "Work with repositories",
                },
                {
                  id: "slack",
                  name: "Slack",
                  summary: "Collaborate with your team",
                },
              ],
            },
          ]}
          categoryPreviewCount={2}
        />
      );

      await user.click(
        screen.getByRole("button", {
          name: "Show all Productivity plugins",
        })
      );

      expect(animate).toHaveBeenCalledTimes(8);
      expect(animate.mock.calls[0]?.[0]).toEqual([
        { transform: "translate3d(-14px, -14px, 0)" },
        { transform: "translate3d(0, 0, 0)" },
      ]);
      expect(animate.mock.calls[1]?.[0]).toEqual([
        {
          opacity: 1,
          transform: "translate3d(-50%, -50%, 0) scale(1) rotate(4.5deg)",
        },
        {
          opacity: 0,
          transform: "translate3d(-50%, -50%, 0) scale(2.75) rotate(0deg)",
        },
      ]);
      expect(animate.mock.calls[2]?.[0]).toEqual([
        {
          opacity: 0,
          transform: "scale(0.36363636363636365) rotate(4.5deg)",
        },
        { opacity: 1, transform: "scale(1) rotate(0deg)" },
      ]);
      expect(animate.mock.calls[3]?.[0]).toEqual([
        { transform: "translate3d(0px, -86px, 0)" },
        { transform: "translate3d(0, 0, 0)" },
      ]);
      expect(animate.mock.calls[0]?.[1]).toEqual({
        duration: 200,
        easing: "cubic-bezier(0.77, 0, 0.175, 1)",
        fill: "both",
      });
      expect(animate.mock.calls.slice(6).map((call) => call[0])).toEqual([
        [{ opacity: 0 }, { opacity: 1 }],
        [{ opacity: 0 }, { opacity: 1 }],
      ]);
      expect(animate.mock.calls.slice(6).map((call) => call[1])).toEqual([
        {
          delay: 0,
          duration: 100,
          easing: "cubic-bezier(0.16, 1, 0.3, 1)",
          fill: "both",
        },
        {
          delay: 30,
          duration: 100,
          easing: "cubic-bezier(0.16, 1, 0.3, 1)",
          fill: "both",
        },
      ]);

      const githubFlight = document.body.querySelector<HTMLElement>(
        '[data-slot="plugin-artwork-flight"][data-plugin-id="github"]'
      );
      const githubSource = githubFlight?.querySelector<HTMLElement>(
        '[data-slot="plugin-artwork-flight-source"]'
      );
      const masks = Array.from(githubSource?.querySelectorAll("mask") ?? []);
      const longMask = masks.find((mask) =>
        mask.id.startsWith("github-plugin-mask-long-")
      );
      const shortMask = masks.find(
        (mask) =>
          mask.id.startsWith("github-plugin-mask-") &&
          !mask.id.startsWith("github-plugin-mask-long-")
      );

      expect(githubSource).toHaveStyle({ height: "16px", width: "16px" });
      expect(longMask?.id).toMatch(/^github-plugin-mask-long-comma-plugin-flight-\d+$/);
      expect(githubSource?.querySelector("rect[mask]")).toHaveAttribute(
        "mask",
        `url(#${longMask?.id})`
      );
      expect(githubSource?.querySelector("use")).toHaveAttribute(
        "href",
        `#${shortMask?.id}`
      );
      expect(githubSource?.querySelector('rect[fill="#ffffff"]')).not.toBeNull();
      expect(document.querySelectorAll("#github-plugin-mask")).toHaveLength(1);

      const githubArtwork = screen
        .getByText("GitHub")
        .closest('[data-slot="plugin-list-item"]')
        ?.querySelector<HTMLElement>('[data-slot="plugin-artwork"]');
      expect(githubArtwork).toHaveStyle({ visibility: "hidden" });

      animations[0]?.dispatchEvent(new Event("finish"));

      animations.slice(0, 3).forEach((animation) => {
        expect(animation.cancel).toHaveBeenCalledOnce();
      });
      expect(githubArtwork).not.toHaveStyle({ visibility: "hidden" });
      expect(
        document.body.querySelectorAll('[data-slot="plugin-artwork-flight"]')
      ).toHaveLength(1);
    } finally {
      getBoundingClientRect.mockRestore();
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
      if (offsetWidthDescriptor) {
        Object.defineProperty(
          HTMLElement.prototype,
          "offsetWidth",
          offsetWidthDescriptor
        );
      }
      if (offsetHeightDescriptor) {
        Object.defineProperty(
          HTMLElement.prototype,
          "offsetHeight",
          offsetHeightDescriptor
        );
      }
    }
  });

  it("cancels reveal animations and restores hidden artwork on unmount", async () => {
    const user = userEvent.setup();
    const animations: Animation[] = [];
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
        _options?: number | KeyframeAnimationOptions
      ) => {
        const animation = new EventTarget() as Animation;
        animation.cancel = vi.fn();
        animations.push(animation);
        return animation;
      }
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );
    const getBoundingClientRect = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        const element = this as HTMLElement;
        if (element.dataset.slot !== "plugin-artwork") {
          return createDOMRect(0, 0, 0, 0);
        }

        const pluginId =
          element.closest<HTMLElement>("[data-plugin-id]")?.dataset.pluginId;
        const isPreview = element.closest('[data-slot="plugin-show-all"]');

        if (isPreview) {
          return pluginId === "linear"
            ? createDOMRect(20, 20, 16, 16)
            : createDOMRect(34, 20, 16, 16);
        }

        return pluginId === "linear"
          ? createDOMRect(80, 80, 44, 44)
          : createDOMRect(80, 152, 44, 44);
      });

    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    try {
      const { unmount } = render(
        <PluginCatalog
          categories={[
            {
              id: "productivity",
              name: "Productivity",
              plugins: [
                notionPlugin,
                linearPlugin,
                {
                  id: "github",
                  name: "GitHub",
                  summary: "Work with repositories",
                },
              ],
            },
          ]}
          categoryPreviewCount={1}
        />
      );

      await user.click(
        screen.getByRole("button", {
          name: "Show all Productivity plugins",
        })
      );

      const linearArtwork = screen
        .getByText("Linear")
        .closest('[data-slot="plugin-list-item"]')
        ?.querySelector<HTMLElement>('[data-slot="plugin-artwork"]');

      expect(animations).toHaveLength(8);
      expect(linearArtwork).toHaveStyle({ visibility: "hidden" });
      expect(
        document.body.querySelectorAll('[data-slot="plugin-artwork-flight"]')
      ).toHaveLength(2);

      unmount();

      animations.forEach((animation) => {
        expect(animation.cancel).toHaveBeenCalledOnce();
      });
      expect(linearArtwork).not.toHaveStyle({ visibility: "hidden" });
      expect(
        document.body.querySelector('[data-slot="plugin-artwork-flight"]')
      ).toBeNull();
    } finally {
      getBoundingClientRect.mockRestore();
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it("reveals every hidden row on one bounded timeline", async () => {
    const user = userEvent.setup();
    const animations: Animation[] = [];
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
        _options?: number | KeyframeAnimationOptions
      ) => {
        const animation = new EventTarget() as Animation;
        animation.cancel = vi.fn();
        animations.push(animation);
        return animation;
      }
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );

    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    try {
      render(
        <PluginCatalog
          categories={[
            {
              id: "large-category",
              name: "Large category",
              plugins: [
                notionPlugin,
                ...Array.from({ length: 12 }, (_, index) => ({
                  id: `hidden-${index + 1}`,
                  name: `Hidden plugin ${index + 1}`,
                  summary: `Hidden plugin summary ${index + 1}`,
                })),
              ],
            },
          ]}
          categoryPreviewCount={1}
        />
      );

      await user.click(
        screen.getByRole("button", {
          name: "Show all Large category plugins",
        })
      );

      expect(animate).toHaveBeenCalledTimes(12);
      const delays = animate.mock.calls.map((call) =>
        Number(typeof call[1] === "number" ? 0 : call[1]?.delay)
      );
      expect(delays.slice(0, 4)).toEqual([0, 30, 60, 130]);
      expect(delays.at(-1)).toBe(200);
      expect(
        delays.every((delay, index) => index === 0 || delay > delays[index - 1]!)
      ).toBe(true);
      expect(animate.mock.calls[2]?.[1]).toMatchObject({
        delay: 60,
        duration: 100,
      });
      expect(animate.mock.calls[3]?.[1]).toMatchObject({
        delay: 130,
        duration: 100,
      });
      const finalTiming = animate.mock.calls.at(-1)?.[1] as KeyframeAnimationOptions;
      const finalEnd = Number(finalTiming.delay) + Number(finalTiming.duration);
      expect(finalEnd).toBe(300);
      expect(animate.mock.calls[0]?.[0]).toEqual([
        {
          opacity: 0,
          transform: "translate3d(0, -8px, 0)",
        },
        {
          opacity: 1,
          transform: "translate3d(0, 0, 0)",
        },
      ]);
      expect(animate.mock.calls[11]?.[0]).toEqual(animate.mock.calls[0]?.[0]);

      animations.at(-1)?.dispatchEvent(new Event("finish"));
      expect(animations.at(-1)?.cancel).toHaveBeenCalledOnce();
    } finally {
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it("bounds animation work for very large plugin categories", async () => {
    const user = userEvent.setup();
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes | null,
        _options?: number | KeyframeAnimationOptions
      ) => {
        const animation = new EventTarget() as Animation;
        animation.cancel = vi.fn();
        return animation;
      }
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );

    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    try {
      render(
        <PluginCatalog
          categories={[
            {
              id: "large-category",
              name: "Large category",
              plugins: [
                notionPlugin,
                ...Array.from({ length: 40 }, (_, index) => ({
                  id: `hidden-${index + 1}`,
                  name: `Hidden plugin ${index + 1}`,
                  summary: `Hidden plugin summary ${index + 1}`,
                })),
              ],
            },
          ]}
          categoryPreviewCount={1}
        />
      );

      await user.click(
        screen.getByRole("button", {
          name: "Show all Large category plugins",
        })
      );

      const overflowGroup = document.querySelector(
        '[data-slot="plugin-reveal-overflow"]'
      );
      expect(overflowGroup?.children).toHaveLength(28);
      expect(animate).toHaveBeenCalledTimes(13);

      const delays = animate.mock.calls.map((call) =>
        Number(typeof call[1] === "number" ? 0 : call[1]?.delay)
      );
      expect(
        delays.every((delay, index) => index === 0 || delay > delays[index - 1]!)
      ).toBe(true);
      expect(delays.at(-1)).toBe(200);
    } finally {
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it("suppresses row background transitions only during pointer expansion", () => {
    vi.useFakeTimers();

    try {
      const { container } = render(
        <PluginCatalog
          categories={[
            {
              id: "productivity",
              name: "Productivity",
              plugins: [
                notionPlugin,
                linearPlugin,
                {
                  id: "github",
                  name: "GitHub",
                  summary: "Work with repositories",
                },
                {
                  id: "slack",
                  name: "Slack",
                  summary: "Collaborate with your team",
                },
              ],
            },
          ]}
          categoryPreviewCount={2}
        />
      );

      fireEvent.click(
        screen.getByRole("button", {
          name: "Show all Productivity plugins",
        }),
        { detail: 1 }
      );

      const revealedItems = container.querySelector("[data-pointer-expanding]");
      expect(revealedItems).toBeInTheDocument();

      act(() => vi.advanceTimersByTime(299));
      expect(revealedItems).toHaveAttribute("data-pointer-expanding");

      act(() => vi.advanceTimersByTime(1));
      expect(revealedItems).not.toHaveAttribute("data-pointer-expanding");
    } finally {
      vi.useRealTimers();
    }
  });

  it("shows a single overflow plugin directly without Show all", () => {
    render(
      <PluginCatalog
        categories={[
          {
            id: "productivity",
            name: "Productivity",
            plugins: [
              notionPlugin,
              linearPlugin,
              {
                id: "github",
                name: "GitHub",
                summary: "Work with repositories",
              },
            ],
          },
        ]}
        categoryPreviewCount={2}
      />
    );

    expect(screen.getByText("GitHub")).toBeVisible();
    expect(
      screen.queryByRole("button", { name: "Show all Productivity plugins" })
    ).toBeNull();
  });

  it("previews only the first three overflow plugin icons in Show all", () => {
    const overflowPlugins = [
      {
        id: "github",
        icon: <svg data-testid="github-overflow-icon" />,
        name: "GitHub",
        summary: "Work with repositories",
      },
      {
        id: "slack",
        icon: <svg data-testid="slack-overflow-icon" />,
        name: "Slack",
        summary: "Collaborate with your team",
      },
      {
        id: "google",
        icon: <svg data-testid="google-overflow-icon" />,
        name: "Google",
        summary: "Search company files",
      },
      {
        id: "jira",
        icon: <svg data-testid="jira-overflow-icon" />,
        name: "Jira",
        summary: "Track engineering work",
      },
    ] satisfies readonly PluginDefinition[];

    render(
      <PluginCatalog
        categories={[
          {
            id: "productivity",
            name: "Productivity",
            plugins: [notionPlugin, linearPlugin, ...overflowPlugins],
          },
        ]}
        categoryPreviewCount={2}
      />
    );

    const showAllButton = screen.getByRole("button", {
      name: "Show all Productivity plugins",
    });

    expect(within(showAllButton).getByTestId("github-overflow-icon")).toBeVisible();
    expect(within(showAllButton).getByTestId("slack-overflow-icon")).toBeVisible();
    expect(within(showAllButton).getByTestId("google-overflow-icon")).toBeVisible();
    expect(within(showAllButton).queryByTestId("jira-overflow-icon")).toBeNull();
    expect(showAllButton.querySelectorAll("[data-plugin-id]")).toHaveLength(3);
  });

  it("gives focus only to the latest controlled expansion request", async () => {
    const user = userEvent.setup();
    const categories = [
      {
        id: "productivity",
        name: "Productivity",
        plugins: [
          notionPlugin,
          linearPlugin,
          {
            id: "github",
            name: "GitHub",
            summary: "Work with repositories",
          },
          {
            id: "jira",
            name: "Jira",
            summary: "Track issues",
          },
        ],
      },
      {
        id: "collaboration",
        name: "Collaboration",
        plugins: [
          {
            id: "docs",
            name: "Docs",
            summary: "Write together",
          },
          {
            id: "chat",
            name: "Chat",
            summary: "Talk together",
          },
          {
            id: "huddles",
            name: "Huddles",
            summary: "Meet together",
          },
          {
            id: "calls",
            name: "Calls",
            summary: "Call together",
          },
        ],
      },
    ] satisfies readonly PluginCategory[];
    const props = {
      categories,
      categoryPreviewCount: 2,
      onExpandedCategoryIdsChange: vi.fn(),
      onPluginOpen: vi.fn(),
    };
    const { rerender } = render(<PluginCatalog {...props} expandedCategoryIds={[]} />);

    await user.click(
      screen.getByRole("button", {
        name: "Show all Productivity plugins",
      })
    );
    await user.click(
      screen.getByRole("button", {
        name: "Show all Collaboration plugins",
      })
    );

    rerender(
      <PluginCatalog
        {...props}
        expandedCategoryIds={["productivity", "collaboration"]}
      />
    );

    expect(
      screen.getByRole("button", { name: "View Huddles plugin details" })
    ).toHaveFocus();
    expect(
      screen.getByRole("button", { name: "View GitHub plugin details" })
    ).not.toHaveFocus();
  });

  it("restores focus to Show all after a controlled collapse", () => {
    const category = {
      id: "productivity",
      name: "Productivity",
      plugins: [
        notionPlugin,
        linearPlugin,
        {
          id: "github",
          name: "GitHub",
          summary: "Work with repositories",
        },
        {
          id: "jira",
          name: "Jira",
          summary: "Track issues",
        },
      ],
    } satisfies PluginCategory;
    const props = {
      categories: [category],
      categoryPreviewCount: 2,
      onExpandedCategoryIdsChange: vi.fn(),
      onPluginOpen: vi.fn(),
    };
    const { rerender } = render(
      <PluginCatalog {...props} expandedCategoryIds={["productivity"]} />
    );

    screen.getByRole("button", { name: "View GitHub plugin details" }).focus();
    rerender(<PluginCatalog {...props} expandedCategoryIds={[]} />);

    expect(
      screen.getByRole("button", { name: "Show all Productivity plugins" })
    ).toHaveFocus();
  });

  it("does not steal focus when a controlled expansion resolves after focus moved", async () => {
    const user = userEvent.setup();
    const onExpandedCategoryIdsChange = vi.fn();
    const category = {
      id: "productivity",
      name: "Productivity",
      plugins: [
        notionPlugin,
        linearPlugin,
        {
          id: "github",
          name: "GitHub",
          summary: "Work with repositories",
        },
        {
          id: "slack",
          name: "Slack",
          summary: "Collaborate with your team",
        },
      ],
    } satisfies PluginCategory;
    const { rerender } = render(
      <PluginCatalog
        categories={[category]}
        categoryPreviewCount={2}
        expandedCategoryIds={[]}
        onExpandedCategoryIdsChange={onExpandedCategoryIdsChange}
        onPluginOpen={vi.fn()}
      />
    );

    await user.click(
      screen.getByRole("button", {
        name: "Show all Productivity plugins",
      })
    );
    await user.click(screen.getByRole("textbox", { name: "Search plugins" }));

    rerender(
      <PluginCatalog
        categories={[category]}
        categoryPreviewCount={2}
        expandedCategoryIds={["productivity"]}
        onExpandedCategoryIdsChange={onExpandedCategoryIdsChange}
        onPluginOpen={vi.fn()}
      />
    );

    expect(screen.getByRole("textbox", { name: "Search plugins" })).toHaveFocus();
    expect(
      screen.getByRole("button", { name: "View GitHub plugin details" })
    ).not.toHaveFocus();
  });

  it("filters installed and listed plugins from the search field", async () => {
    const user = userEvent.setup();

    render(
      <PluginCatalog
        categories={[
          {
            id: "productivity",
            name: "Productivity",
            plugins: [
              linearPlugin,
              {
                id: "github",
                name: "GitHub",
                summary: "Work with repositories",
              },
            ],
          },
        ]}
        installedPlugins={[notionPlugin]}
      />
    );

    const searchInput = screen.getByRole("textbox", { name: "Search plugins" });

    await user.click(searchInput);

    expect(searchInput).toHaveFocus();

    await user.type(searchInput, "LINEAR");

    expect(screen.getByText("Linear")).toBeInTheDocument();
    expect(screen.queryByText("Notion")).not.toBeInTheDocument();
    expect(screen.queryByText("GitHub")).not.toBeInTheDocument();
    expect(screen.queryByText("Installed")).not.toBeInTheDocument();
  });

  it("does not expose installed plugins as installable category rows", () => {
    render(
      <PluginCatalog
        categories={[
          {
            id: "productivity",
            name: "Productivity",
            plugins: [notionPlugin, linearPlugin],
          },
        ]}
        installedPlugins={[notionPlugin]}
        onPluginInstall={vi.fn()}
      />
    );

    expect(screen.queryByRole("button", { name: "Add Notion" })).toBeNull();
    expect(screen.getAllByText("Notion")).toHaveLength(1);
    expect(screen.getByRole("button", { name: "Add Linear" })).toBeInTheDocument();
  });

  it("renders plugin detail resources and invokes its action callbacks", async () => {
    const user = userEvent.setup();
    const onBack = vi.fn();
    const onInstall = vi.fn();
    const onManageMcps = vi.fn();
    const plugin: PluginDefinition = {
      ...linearPlugin,
      description: "Connect issues, projects, and roadmaps to Comma.",
      mcps: [
        {
          id: "linear-mcp",
          name: "Linear MCP",
        },
      ],
      skills: [
        {
          id: "triage-issues",
          name: "Triage issues",
        },
      ],
    };

    render(
      <PluginDetail
        onBack={onBack}
        onInstall={onInstall}
        onManageMcps={onManageMcps}
        plugin={plugin}
      />
    );

    expect(
      screen.getByText("Connect issues, projects, and roadmaps to Comma.")
    ).toBeInTheDocument();
    expect(
      screen.getByRole("heading", { level: 1, name: "Linear" })
    ).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Description" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "MCPs" })).toBeInTheDocument();
    expect(screen.getByText("Linear MCP")).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Skills" })).toBeInTheDocument();
    expect(screen.getByText("Triage issues")).toBeInTheDocument();

    const addButton = screen.getByRole("button", { name: "Add to Comma Linear" });

    expect(addButton.closest("article")).not.toHaveClass("comma-plugin-list-item");

    await user.click(addButton);
    await user.click(screen.getByRole("button", { name: "Manage" }));
    await user.click(screen.getByRole("button", { name: "Back to plugins" }));

    expect(onInstall).toHaveBeenCalledOnce();
    expect(onInstall).toHaveBeenCalledWith(plugin);
    expect(onManageMcps).toHaveBeenCalledOnce();
    expect(onManageMcps).toHaveBeenCalledWith(plugin);
    expect(onBack).toHaveBeenCalledOnce();
  });

  it("renders the post-add actions without making the detail header hoverable", async () => {
    const user = userEvent.setup();
    const onTryInChat = vi.fn();
    const onUninstall = vi.fn();

    render(
      <PluginDetail
        installed
        onTryInChat={onTryInChat}
        onUninstall={onUninstall}
        plugin={linearPlugin}
      />
    );

    const uninstallButton = screen.getByRole("button", {
      name: "Uninstall Linear",
    });
    const tryInChatButton = screen.getByRole("button", {
      name: "Try in Chat Linear",
    });

    expect(uninstallButton.closest("article")).not.toHaveClass(
      "comma-plugin-list-item"
    );

    await user.click(uninstallButton);
    await user.click(tryInChatButton);

    expect(onUninstall).toHaveBeenCalledOnce();
    expect(onUninstall).toHaveBeenCalledWith(linearPlugin);
    expect(onTryInChat).toHaveBeenCalledOnce();
    expect(onTryInChat).toHaveBeenCalledWith(linearPlugin);
  });

  it("reports keyboard-triggered detail opens", async () => {
    const user = userEvent.setup();
    const onOpen = vi.fn();

    render(<PluginListItem onOpen={onOpen} plugin={linearPlugin} />);

    await user.tab();
    expect(
      screen.getByRole("button", {
        name: "View Linear plugin details",
      })
    ).toHaveFocus();

    await user.keyboard("{Enter}");

    expect(onOpen).toHaveBeenCalledOnce();
    expect(onOpen).toHaveBeenCalledWith(linearPlugin, "keyboard");
  });

  it("uses injected catalog copy for visible labels and name-aware ARIA", async () => {
    const user = userEvent.setup();
    const category = {
      id: "productivity",
      name: "效率",
      plugins: [
        linearPlugin,
        {
          id: "github",
          name: "GitHub",
          summary: "Work with repositories",
        },
        {
          id: "slack",
          name: "Slack",
          summary: "Collaborate with your team",
        },
      ],
    } satisfies PluginCategory;

    render(
      <PluginCatalog
        categories={[category]}
        categoryPreviewCount={1}
        copy={zhCatalogCopy}
        installedPlugins={[notionPlugin]}
        onManageInstalled={vi.fn()}
        onPluginInstall={vi.fn()}
        onPluginOpen={vi.fn()}
      />
    );

    expect(screen.getByRole("heading", { name: "插件" })).toBeVisible();
    const searchInput = screen.getByRole("textbox", { name: "搜索插件" });
    expect(searchInput).toHaveAttribute("placeholder", "搜索插件…");
    expect(screen.getByRole("heading", { name: "已安装" })).toBeVisible();
    expect(screen.getAllByText("已安装")).toHaveLength(2);
    expect(screen.getByRole("button", { name: "管理" })).toBeVisible();
    expect(screen.getByRole("button", { name: "查看 Notion 插件详情" })).toBeVisible();
    expect(screen.getByRole("button", { name: "添加 Linear" })).toBeVisible();
    expect(
      screen.getByRole("button", { name: "显示全部 效率 插件" })
    ).toHaveTextContent("显示全部");

    await user.type(searchInput, "missing-plugin");

    expect(screen.getByText("未找到插件")).toBeVisible();
  });

  it("uses injected detail copy for sections, actions, and name-aware ARIA", () => {
    const plugin = {
      ...linearPlugin,
      description: "Connect issues, projects, and roadmaps to Comma.",
      mcps: [{ id: "linear-mcp", name: "Linear MCP" }],
      skills: [{ id: "triage-issues", name: "Triage issues" }],
    } satisfies PluginDefinition;
    const detail = (installed: boolean) => (
      <PluginDetail
        copy={zhDetailCopy}
        installed={installed}
        onBack={vi.fn()}
        onInstall={vi.fn()}
        onManageMcps={vi.fn()}
        onTryInChat={vi.fn()}
        onUninstall={vi.fn()}
        plugin={plugin}
      />
    );
    const { rerender } = render(detail(false));

    expect(screen.getByRole("button", { name: "返回插件列表" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "描述" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "MCP" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "技能" })).toBeVisible();
    expect(screen.getByRole("button", { name: "管理" })).toBeVisible();
    expect(
      screen.getByRole("button", { name: "将 Linear 添加到 Comma" })
    ).toHaveTextContent("添加到 Comma");

    rerender(detail(true));

    expect(screen.getByRole("button", { name: "卸载 Linear" })).toHaveTextContent(
      "卸载"
    );
    expect(
      screen.getByRole("button", { name: "在聊天中试用 Linear" })
    ).toHaveTextContent("在聊天中试用");
  });
});
