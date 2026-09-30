/**
 * Every user-facing string of the BFT dashboard, in the two dashboard locales
 * (`en`, `zh_Hans`). Phoenix resolves the locale with the same rules as the
 * LiveView pages and writes it to `<meta name="bft-locale">`.
 */
const en = {
  productName: "Bridge for Teams",
  nav: {
    label: "Organization navigation",
    overview: "Overview",
    agentSwarms: "Agent Swarms",
    meetings: "Meetings",
    slackTriage: "Slack triage",
    dataPolicy: "Data policy",
    health: "Health",
    runners: "Runners",
    members: "Members",
    plugins: "Plugins",
    settings: "Settings",
    settingsGeneral: "General",
    settingsModels: "Models",
    settingsSso: "Single sign-on",
    settingsOauth: "OAuth apps",
    settingsComposio: "Composio",
    settingsSignal: "Signal",
    settingsFeishu: "Feishu",
  },
  topBar: {
    orgSwitcher: "Switch organization",
    allOrganizations: "All organizations",
    searchPlaceholder: "Search pages and settings",
    searchLabel: "Search",
    accountMenu: "Account",
    paletteLabel: "Go to page",
    palettePlaceholder: "Search pages and settings",
    paletteEmpty: "No matching pages",
    paletteGroupPages: "Pages",
  },
  overview: {
    title: "Overview",
    description: (orgName: string) => `Agent activity across ${orgName}.`,
    inviteMembers: "Invite members",
    createAgentSwarm: "Create Agent Swarm",
    metricAgentSwarms: "Agent Swarms",
    metricInUse: (count: number) => `${count} in use`,
    metricConversations: "Conversations",
    metricTokens: "Tokens used",
    metricMembers: "Members",
    swarmsTitle: "Most active Agent Swarms",
    swarmsViewAll: "View all",
    columnName: "Name",
    columnConversations: "Conversations",
    columnTokens: "Tokens",
    columnStatus: "Status",
    columnRefreshed: "Last refreshed",
    never: "Never",
    swarmsEmptyTitle: "No Agent Swarms yet",
    swarmsEmptyBody: "Create an Agent Swarm to put agents to work in your channels.",
    attentionTitle: "Needs attention",
    attentionEmpty: "Nothing needs attention.",
    attentionError: "Error",
    attentionWarning: "Warning",
    runnersTitle: "Runners",
    runnersOnline: (online: number, total: number) => `${online} of ${total} online`,
    runnersNone: "No runners registered",
    runnersManage: "Manage runners",
    quickActionsTitle: "Quick actions",
    quickInvite: "Invite members",
    quickConnectSlack: "Connect Slack",
    quickAddRunner: "Add a runner",
    quickAuditLog: "Audit log",
  },
  status: {
    ready: "Up to date",
    stale: "Stale",
    refreshing: "Refreshing",
    missing: "No data yet",
    error: "Refresh failed",
  },
  states: {
    loading: "Loading",
    errorTitle: "Could not load this page",
    errorBody: "Something went wrong while loading data. Try again in a moment.",
    retry: "Retry",
    orgNotFoundTitle: "Organization not found",
    orgNotFoundBody:
      "This organization does not exist or you do not have access to it.",
    backToOrganizations: "Back to organizations",
    pageNotFoundTitle: "Page not found",
    pageNotFoundBody: "This address is not part of the dashboard.",
    redirecting: "Opening your organization",
  },
};

export type Messages = typeof en;

const zhHans: Messages = {
  productName: "Bridge for Teams",
  nav: {
    label: "组织导航",
    overview: "概览",
    agentSwarms: "Agent Swarms",
    meetings: "会议",
    slackTriage: "Slack 分诊",
    dataPolicy: "数据策略",
    health: "运行状况",
    runners: "Runner",
    members: "成员",
    plugins: "插件",
    settings: "设置",
    settingsGeneral: "常规",
    settingsModels: "模型",
    settingsSso: "单点登录",
    settingsOauth: "OAuth 应用",
    settingsComposio: "Composio",
    settingsSignal: "Signal",
    settingsFeishu: "飞书",
  },
  topBar: {
    orgSwitcher: "切换组织",
    allOrganizations: "全部组织",
    searchPlaceholder: "搜索页面和设置",
    searchLabel: "搜索",
    accountMenu: "账户",
    paletteLabel: "前往页面",
    palettePlaceholder: "搜索页面和设置",
    paletteEmpty: "没有匹配的页面",
    paletteGroupPages: "页面",
  },
  overview: {
    title: "概览",
    description: (orgName: string) => `${orgName} 的 Agent 工作情况。`,
    inviteMembers: "邀请成员",
    createAgentSwarm: "创建 Agent Swarm",
    metricAgentSwarms: "Agent Swarms",
    metricInUse: (count: number) => `${count} 个在用`,
    metricConversations: "对话",
    metricTokens: "Token 用量",
    metricMembers: "成员",
    swarmsTitle: "最活跃的 Agent Swarms",
    swarmsViewAll: "查看全部",
    columnName: "名称",
    columnConversations: "对话",
    columnTokens: "Token",
    columnStatus: "状态",
    columnRefreshed: "上次刷新",
    never: "从未",
    swarmsEmptyTitle: "还没有 Agent Swarm",
    swarmsEmptyBody: "创建一个 Agent Swarm，让 Agent 在你的频道里开始工作。",
    attentionTitle: "需要处理",
    attentionEmpty: "没有需要处理的事项。",
    attentionError: "错误",
    attentionWarning: "警告",
    runnersTitle: "Runner",
    runnersOnline: (online: number, total: number) => `${online} / ${total} 在线`,
    runnersNone: "还没有注册 Runner",
    runnersManage: "管理 Runner",
    quickActionsTitle: "快捷操作",
    quickInvite: "邀请成员",
    quickConnectSlack: "连接 Slack",
    quickAddRunner: "添加 Runner",
    quickAuditLog: "审计日志",
  },
  status: {
    ready: "已是最新",
    stale: "已过期",
    refreshing: "刷新中",
    missing: "暂无数据",
    error: "刷新失败",
  },
  states: {
    loading: "加载中",
    errorTitle: "无法加载此页面",
    errorBody: "加载数据时出错，请稍后重试。",
    retry: "重试",
    orgNotFoundTitle: "未找到组织",
    orgNotFoundBody: "该组织不存在，或你没有访问权限。",
    backToOrganizations: "返回组织列表",
    pageNotFoundTitle: "未找到页面",
    pageNotFoundBody: "这个地址不属于控制台。",
    redirecting: "正在打开你的组织",
  },
};

export type BftLocale = "en" | "zh_Hans";

export function messagesFor(locale: string | null | undefined): Messages {
  return locale === "zh_Hans" ? zhHans : en;
}

export function documentLocale(): BftLocale {
  if (typeof document === "undefined") return "en";
  const meta = document
    .querySelector('meta[name="bft-locale"]')
    ?.getAttribute("content");
  // The mock dev server has no Phoenix to inject the meta tag.
  const override =
    import.meta.env.VITE_BFT_MOCK === "1"
      ? new URLSearchParams(window.location.search).get("locale")
      : null;
  return (override ?? meta) === "zh_Hans" ? "zh_Hans" : "en";
}

export const locale: BftLocale = documentLocale();
export const messages: Messages = messagesFor(locale);
