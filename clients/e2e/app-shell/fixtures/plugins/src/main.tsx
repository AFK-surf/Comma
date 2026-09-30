import "@comma/ui/styles.css";

import {
  PluginCatalog,
  PluginDetail,
  type PluginCatalogCopy,
  type PluginCategory,
  type PluginDefinition,
  type PluginDetailCopy,
} from "@comma/ui";
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";

const FixtureIcon = ({ label }: { label: string }) => (
  <svg aria-label={label} viewBox="0 0 24 24">
    <circle cx="12" cy="12" fill="currentColor" r="8" />
  </svg>
);

const notionPlugin = {
  id: "notion",
  name: "Notion",
  summary: "Search and update your workspace",
} satisfies PluginDefinition;

const linearPlugin = {
  id: "linear",
  name: "Linear",
  summary: "Plan and track product work",
  icon: <FixtureIcon label="Linear icon" />,
  description: "Connect issues, projects, and roadmaps to Comma.",
  mcps: [{ id: "linear-mcp", name: "Linear MCP" }],
  skills: [{ id: "triage-issues", name: "Triage issues" }],
} satisfies PluginDefinition;

const hiddenPlugins = [
  {
    id: "github",
    name: "GitHub",
    summary: "Work with repositories",
    icon: <FixtureIcon label="GitHub icon" />,
  },
  {
    id: "slack",
    name: "Slack",
    summary: "Collaborate with your team",
    icon: <FixtureIcon label="Slack icon" />,
  },
  {
    id: "google-drive",
    name: "Google Drive",
    summary: "Search company files",
    icon: <FixtureIcon label="Google Drive icon" />,
  },
  {
    id: "jira",
    name: "Jira",
    summary: "Track engineering work",
    icon: <FixtureIcon label="Jira icon" />,
  },
  {
    id: "asana",
    name: "Asana",
    summary: "Coordinate team projects",
    icon: <FixtureIcon label="Asana icon" />,
  },
  {
    id: "figma",
    name: "Figma",
    summary: "Review product designs",
    icon: <FixtureIcon label="Figma icon" />,
  },
  {
    id: "zendesk",
    name: "Zendesk",
    summary: "Resolve support requests",
    icon: <FixtureIcon label="Zendesk icon" />,
  },
  {
    id: "hubspot",
    name: "HubSpot",
    summary: "Manage customer relationships",
    icon: <FixtureIcon label="HubSpot icon" />,
  },
  {
    id: "salesforce",
    name: "Salesforce",
    summary: "Inspect account activity",
    icon: <FixtureIcon label="Salesforce icon" />,
  },
  {
    id: "dropbox",
    name: "Dropbox",
    summary: "Find shared documents",
    icon: <FixtureIcon label="Dropbox icon" />,
  },
] satisfies readonly PluginDefinition[];

const fixtureSearchParams = new URLSearchParams(window.location.search);
const requestedHiddenPluginCount = fixtureSearchParams.get("hiddenPluginCount");
const parsedHiddenPluginCount =
  requestedHiddenPluginCount === null ? Number.NaN : Number(requestedHiddenPluginCount);
const hiddenPluginCount = Number.isInteger(parsedHiddenPluginCount)
  ? Math.min(Math.max(parsedHiddenPluginCount, 1), hiddenPlugins.length)
  : 2;

const categories = [
  {
    id: "productivity",
    name: "Productivity",
    plugins: [notionPlugin, linearPlugin, ...hiddenPlugins.slice(0, hiddenPluginCount)],
  },
] satisfies readonly PluginCategory[];

const zhCatalogCopy = {
  addLabel: "添加",
  addPluginAriaLabel: (name) => `添加 ${name}`,
  emptyLabel: "未找到插件",
  installedLabel: "已安装",
  manageLabel: "管理",
  openPluginAriaLabel: (name) => `查看 ${name} 插件详情`,
  searchAriaLabel: "搜索插件",
  searchPlaceholder: "搜索插件…",
  showAllCategoryAriaLabel: (category) => `显示全部 ${category} 插件`,
  showAllLabel: "显示全部",
  openSkillAriaLabel: (name) => `查看 ${name} 技能详情`,
  skillCategoriesAriaLabel: "技能分类",
  skillsEmptyLabel: "未找到技能",
  skillsSearchAriaLabel: "搜索技能",
  skillsSearchPlaceholder: "搜索技能…",
  skillsTitle: "技能",
  title: "插件",
} satisfies PluginCatalogCopy;

const zhDetailCopy = {
  backLabel: "返回插件列表",
  descriptionLabel: "描述",
  installLabel: "添加到 Comma",
  installPluginAriaLabel: (name) => `将 ${name} 添加到 Comma`,
  manageLabel: "管理",
  mcpsLabel: "MCP",
  skillsLabel: "技能",
  tryInChatLabel: "在聊天中试用",
  tryPluginInChatAriaLabel: (name) => `在聊天中试用 ${name}`,
  uninstallLabel: "卸载",
  uninstallPluginAriaLabel: (name) => `卸载 ${name}`,
} satisfies PluginDetailCopy;

const zhCN = fixtureSearchParams.get("locale") === "zh-CN";
document.documentElement.lang = zhCN ? "zh-CN" : "en";

function PluginsFixture() {
  const [openedPluginId, setOpenedPluginId] = useState<string | null>(null);
  const [detailInstalled, setDetailInstalled] = useState(false);
  const localizedCategories = zhCN
    ? categories.map((category) => ({
        ...category,
        name: category.id === "productivity" ? "效率" : category.name,
      }))
    : categories;

  return (
    <main className="flex min-h-screen flex-col items-center gap-8 bg-primary p-8 text-primary">
      <PluginCatalog
        categories={localizedCategories}
        categoryPreviewCount={1}
        className="h-[720px] w-[702px]"
        installedPlugins={[notionPlugin]}
        onPluginInstall={() => undefined}
        onPluginOpen={(plugin) => setOpenedPluginId(plugin.id)}
        {...(zhCN ? { copy: zhCatalogCopy } : {})}
      />
      <output aria-live="polite">
        {openedPluginId ? `Opened plugin: ${openedPluginId}` : ""}
      </output>
      <PluginDetail
        className="h-[720px] w-[702px]"
        plugin={linearPlugin}
        {...(zhCN
          ? {
              copy: zhDetailCopy,
              installed: detailInstalled,
              onBack: () => undefined,
              onInstall: () => setDetailInstalled(true),
              onTryInChat: () => undefined,
              onUninstall: () => setDetailInstalled(false),
            }
          : { onInstall: () => undefined })}
      />
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <PluginsFixture />
  </StrictMode>
);
