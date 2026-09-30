import { useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { fn } from "storybook/test";
import {
  GithubProviderLogo,
  GoogleProviderLogo,
  LinearProviderLogo,
  NotionProviderLogo,
  SlackProviderLogo,
} from "../provider-brand-logos";
import { CubeIcon } from "../icons";
import { MarkdownStream } from "../markdown-stream";
import {
  PluginCatalog,
  PluginDetail,
  PluginDetailSection,
  PluginInstalledCard,
  PluginListItem,
  PluginShowAll,
  type PluginCategory,
  type PluginDefinition,
} from "./Plugins";

const brandArtwork = {
  github: <GithubProviderLogo />,
  google: <GoogleProviderLogo />,
  linear: <LinearProviderLogo />,
  notion: <NotionProviderLogo />,
  slack: <SlackProviderLogo />,
} as const;

const createPlugin = (
  id: string,
  name: string,
  summary: string,
  icon: PluginDefinition["icon"]
): PluginDefinition => ({
  icon,
  id,
  name,
  summary,
});

const dataAnalytics = createPlugin(
  "data-analytics",
  "Data Analytics",
  "Turn data into clear decisions",
  brandArtwork.google
);

const installedPlugins = [
  dataAnalytics,
  createPlugin(
    "customer-insights",
    "Customer Insights",
    "Understand every customer signal",
    brandArtwork.slack
  ),
  createPlugin(
    "product-discovery",
    "Product Discovery",
    "Shape evidence into product direction",
    brandArtwork.notion
  ),
  createPlugin(
    "developer-tools",
    "Developer Tools",
    "Keep engineering work moving",
    brandArtwork.github
  ),
] satisfies readonly PluginDefinition[];

const categories = [
  {
    id: "customer-experience",
    name: "Customer experience",
    plugins: [
      createPlugin(
        "account-health",
        "Account Health",
        "Monitor customer health signals",
        brandArtwork.google
      ),
      createPlugin(
        "voice-of-customer",
        "Voice of Customer",
        "Synthesize feedback across every channel",
        brandArtwork.slack
      ),
      createPlugin(
        "support-quality",
        "Support Quality",
        "Find coaching opportunities in support work",
        brandArtwork.notion
      ),
      createPlugin(
        "journey-mapping",
        "Journey Mapping",
        "Reveal friction across customer journeys",
        brandArtwork.linear
      ),
    ],
  },
  {
    id: "engineering",
    name: "Engineering",
    plugins: [
      createPlugin(
        "incident-response",
        "Incident Response",
        "Investigate incidents and coordinate recovery",
        brandArtwork.slack
      ),
      createPlugin(
        "code-review",
        "Code Review",
        "Review changes with repository context",
        brandArtwork.github
      ),
      createPlugin(
        "release-notes",
        "Release Notes",
        "Turn shipped work into clear updates",
        brandArtwork.notion
      ),
      createPlugin(
        "developer-docs",
        "Developer Docs",
        "Create documentation from working code",
        brandArtwork.google
      ),
      createPlugin(
        "deployment-automation",
        "Deployment Automation",
        "Coordinate reliable releases across environments",
        brandArtwork.linear
      ),
    ],
  },
  {
    id: "collaboration",
    name: "Collaboration",
    plugins: [
      createPlugin(
        "team-chat",
        "Team Chat",
        "Coordinate work with the whole team",
        brandArtwork.slack
      ),
      createPlugin(
        "knowledge-base",
        "Knowledge Base",
        "Keep shared guidance easy to find",
        brandArtwork.notion
      ),
      createPlugin(
        "repository-search",
        "Repository Search",
        "Find implementation context across repositories",
        brandArtwork.github
      ),
      createPlugin(
        "workspace-search",
        "Workspace Search",
        "Search files and documents across the workspace",
        brandArtwork.google
      ),
      createPlugin(
        "project-planning",
        "Project Planning",
        "Plan milestones and track delivery",
        brandArtwork.linear
      ),
      createPlugin(
        "meeting-notes",
        "Meeting Notes",
        "Capture decisions and follow-up work",
        brandArtwork.notion
      ),
      createPlugin(
        "release-coordination",
        "Release Coordination",
        "Keep launch communication in sync",
        brandArtwork.slack
      ),
    ],
  },
] satisfies readonly PluginCategory[];

const showAllTwoPlugins = categories.flatMap((category) =>
  category.id === "engineering" ? category.plugins.slice(3) : []
);
const showAllManyPlugins = categories.flatMap((category) =>
  category.id === "collaboration" ? category.plugins.slice(3) : []
);
const expansionPreviewPlugins = categories.flatMap((category) =>
  category.id === "collaboration" ? category.plugins.slice(0, 3) : []
);
const expansionHiddenPlugins = [
  ...showAllManyPlugins,
  ...categories.flatMap((category) =>
    category.id === "collaboration" ? [] : category.plugins
  ),
].slice(0, 10);
const overflowCaseCategories = categories.map((category) => ({
  ...category,
  name:
    category.id === "customer-experience"
      ? "Customer experience · 1 remaining"
      : category.id === "engineering"
        ? "Engineering · 2 hidden"
        : "Collaboration · 4 hidden",
}));

const detailPlugin = {
  ...dataAnalytics,
  description:
    "Turn analytical questions into validated answers, dashboards, reports, notebooks, and clear recommendations. Explore product and business data, explain why key metrics changed, design KPIs, size opportunities, check data quality, and save reusable metric and source context for future work.",
  mcps: [
    {
      icon: dataAnalytics.icon,
      id: "metric-diagnostics-mcp",
      name: "Metric diagnostics",
    },
  ],
  skills: [
    { id: "metric-diagnostics", name: "Metric diagnostics" },
    { id: "dashboard-reporting", name: "Dashboard and reporting" },
    { id: "kpi-design", name: "KPI design" },
    { id: "opportunity-sizing", name: "Opportunity sizing" },
    { id: "data-quality", name: "Data quality checks" },
  ],
} satisfies PluginDefinition;

const callbacks = {
  onExpand: fn(),
  onInstall: fn(),
  onManageInstalled: fn(),
  onManageMcps: fn(),
  onOpen: fn(),
  onSearch: fn(),
  onShowAll: fn(),
  onTryInChat: fn(),
  onUninstall: fn(),
};

const InteractivePluginDetail = ({
  initiallyInstalled = false,
}: {
  initiallyInstalled?: boolean;
}) => {
  const [installed, setInstalled] = useState(initiallyInstalled);

  return (
    <PluginDetail
      className="h-[956px] w-[702px]"
      installed={installed}
      onInstall={(plugin) => {
        callbacks.onInstall(plugin);
        setInstalled(true);
      }}
      onManageMcps={callbacks.onManageMcps}
      onTryInChat={callbacks.onTryInChat}
      onUninstall={(plugin) => {
        callbacks.onUninstall(plugin);
        setInstalled(false);
      }}
      plugin={detailPlugin}
    />
  );
};

const meta = {
  title: "App components/Plugins",
  parameters: {
    layout: "centered",
  },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;
type ExpansionTestStory = StoryObj<{ hiddenPluginCount: number }>;

export const Installed: Story = {
  render: () => (
    <PluginInstalledCard
      className="w-[166px]"
      onOpen={callbacks.onOpen}
      plugin={dataAnalytics}
    />
  ),
};

export const InstalledHover: Story = {
  name: "Installed · Hover",
  render: () => (
    <PluginInstalledCard
      className="w-[166px] !bg-secondary"
      onOpen={callbacks.onOpen}
      plugin={dataAnalytics}
    />
  ),
};

export const List: Story = {
  render: () => (
    <div className="w-[700px] bg-primary">
      <PluginListItem
        actionLabel="Add"
        onAction={callbacks.onInstall}
        onOpen={callbacks.onOpen}
        plugin={dataAnalytics}
      />
    </div>
  ),
};

export const Hover: Story = {
  globals: {
    theme: "dark",
  },
  render: () => (
    <div className="w-[700px] bg-primary">
      <PluginListItem
        actionLabel="Install"
        className="bg-[var(--color-plugin-row-bg-hover)]"
        onAction={callbacks.onInstall}
        onOpen={callbacks.onOpen}
        plugin={dataAnalytics}
      />
    </div>
  ),
};

export const ShowAll: Story = {
  globals: {
    theme: "dark",
  },
  name: "Show all",
  render: () => (
    <div className="flex flex-col gap-md bg-primary">
      <section>
        <p className="m-0 px-md text-xs text-quaternary">Two hidden plugins</p>
        <PluginShowAll onPress={callbacks.onShowAll} plugins={showAllTwoPlugins} />
      </section>
      <section>
        <p className="m-0 px-md text-xs text-quaternary">
          Three or more hidden plugins
        </p>
        <PluginShowAll onPress={callbacks.onShowAll} plugins={showAllManyPlugins} />
      </section>
    </div>
  ),
};

export const WholeUI: Story = {
  name: "Whole UI",
  render: () => (
    <PluginCatalog
      categories={overflowCaseCategories}
      categoryPreviewCount={3}
      className="h-[956px] w-[702px] [&_[data-plugin-id='account-health']]:bg-[var(--color-plugin-row-bg-hover)]"
      installedPlugins={installedPlugins}
      onExpandedCategoryIdsChange={callbacks.onExpand}
      onManageInstalled={callbacks.onManageInstalled}
      onPluginInstall={callbacks.onInstall}
      onPluginOpen={callbacks.onOpen}
      onSearchQueryChange={callbacks.onSearch}
    />
  ),
};

export const SkillsTab: Story = {
  name: "Skills tab",
  render: () => (
    <PluginCatalog
      categories={overflowCaseCategories}
      className="h-[956px] w-[702px]"
      defaultTab="skills"
      onSkillOpen={callbacks.onOpen}
      installedPlugins={installedPlugins}
      skillCategories={[
        { id: "custom", name: "Custom" },
        { id: "imported", name: "Imported" },
        { id: "system", name: "System" },
      ]}
      skills={[
        {
          categoryId: "custom",
          id: "summarize",
          name: "summarize",
          description: "Summarize a long thread into decisions and follow-ups.",
        },
        {
          categoryId: "custom",
          id: "weekly-report",
          name: "weekly-report",
          description: "Draft a weekly report from recent task activity.",
        },
        { categoryId: "imported", id: "release-notes", name: "release-notes" },
        {
          categoryId: "system",
          id: "file-search",
          name: "file-search",
          description: "Find files across connected sources.",
        },
      ]}
    />
  ),
};

export const SkillDetail: Story = {
  name: "Skill detail",
  render: () => (
    <PluginDetail
      backLabel="Back to skills"
      className="h-[956px] w-[702px]"
      installed
      onBack={callbacks.onOpen}
      onTryInChat={callbacks.onTryInChat}
      plugin={{
        description: "Draft a weekly report from recent task activity.",
        icon: <CubeIcon className="text-fg-tertiary" />,
        id: "weekly-report",
        name: "weekly-report",
        summary: "Custom",
      }}
    >
      <PluginDetailSection title="Instructions">
        <div className="rounded-xl border border-primary p-xl text-sm">
          <MarkdownStream
            animation="none"
            content={[
              "# Reporting steps",
              "",
              "Collect the tasks finished this week, then group them by project.",
              "",
              "## Capabilities",
              "",
              "- Summarize finished work",
              "- Flag blocked tasks",
              "- Propose next-week priorities",
              "",
              "```sh",
              "comma report --week current",
              "```",
            ].join("\n")}
            final
            htmlPolicy="escape"
            streamId="weekly-report"
          />
        </div>
      </PluginDetailSection>
    </PluginDetail>
  ),
};

export const ExpansionTest: ExpansionTestStory = {
  name: "Expansion test",
  parameters: {
    layout: "fullscreen",
  },
  args: {
    hiddenPluginCount: 4,
  },
  argTypes: {
    hiddenPluginCount: {
      control: { max: 10, min: 1, step: 1, type: "range" },
      description:
        "Number of plugins after the three-item preview. One remaining plugin is shown directly; with two or more, up to three icons transition from Show all while every hidden row joins one continuous reveal.",
      name: "Hidden plugins",
    },
  },
  render: ({ hiddenPluginCount }) => (
    <div className="flex h-screen max-h-full w-full items-start justify-center overflow-hidden">
      <PluginCatalog
        categories={[
          {
            id: "collaboration-expansion-test",
            name: `Collaboration · ${hiddenPluginCount} hidden`,
            plugins: [
              ...expansionPreviewPlugins,
              ...expansionHiddenPlugins.slice(0, hiddenPluginCount),
            ],
          },
        ]}
        categoryPreviewCount={3}
        className="h-full max-h-full w-[702px]"
        key={hiddenPluginCount}
        onExpandedCategoryIdsChange={callbacks.onExpand}
        onPluginInstall={callbacks.onInstall}
        onPluginOpen={callbacks.onOpen}
      />
    </div>
  ),
};

export const Detail: Story = {
  render: () => <InteractivePluginDetail />,
};

export const DetailAdded: Story = {
  name: "Detail · Added",
  render: () => <InteractivePluginDetail initiallyInstalled />,
};
