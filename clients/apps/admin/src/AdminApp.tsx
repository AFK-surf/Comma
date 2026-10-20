import { commaLogoUrl } from "@comma/config";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import {
  ApiConnectionIcon,
  ChainLinkIcon,
  ChevronDownSmallIcon,
  CubeIcon,
  HomeIcon,
  SearchIcon,
  GlobeIcon,
  HistoryIcon,
  PanelLeftIcon,
  PeopleCircleIcon,
  SparklesIcon,
  TagLabelIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { type ReactNode } from "react";
import type { AdminSection } from "./adminNavigation";
import { useAdminCommand, useAdminService, useAdminState } from "./adminRuntime";
import { AdminShell, type SectionView } from "./adminShell";
import { AdminSessionScreen } from "./AdminSignIn";
import { AdminAuth } from "./auth";
import { AuditLogView } from "./AuditLogView";
import { BillingView } from "./BillingView";
import { GuestModeView } from "./GuestModeView";
import { ComputeNodesView } from "./ComputeNodesView";
import { FreeRouterModelsView } from "./FreeRouterModelsView";
import { OverviewView } from "./OverviewView";
import { AdminSearchPalette } from "./AdminSearchPalette";
import { OAuthClientsView } from "./OAuthClientsView";
import { UsersView } from "./UsersView";
import { messages, type CommaLocale } from "@comma/i18n";
import { AdminBrowser } from "./adminBrowser";

const sectionLabels: Record<AdminSection, () => string> = {
  audit: messages.admin_section_audit,
  billing: messages.admin_section_billing,
  compute: messages.admin_section_compute,
  "free-models": messages.admin_section_free_models,
  guest: messages.admin_section_guest,
  oauth: messages.admin_section_oauth,
  overview: messages.admin_section_overview,
  users: messages.admin_section_users,
};

const sectionGroups: Record<AdminSection, (() => string) | undefined> = {
  audit: messages.admin_group_records,
  billing: messages.admin_group_billing,
  compute: messages.admin_group_platform,
  "free-models": messages.admin_group_billing,
  guest: messages.admin_group_platform,
  oauth: messages.admin_group_platform,
  overview: undefined,
  users: messages.admin_group_people,
};

const navigation: ReadonlyArray<{
  readonly group?: () => string;
  readonly items: ReadonlyArray<{
    readonly icon: ReactNode;
    readonly section: AdminSection;
  }>;
}> = [
  {
    items: [
      { icon: <HomeIcon />, section: "overview" },
      { icon: <PeopleCircleIcon />, section: "users" },
    ],
  },
  {
    group: messages.admin_group_billing,
    items: [
      { icon: <TagLabelIcon />, section: "billing" },
      { icon: <SparklesIcon />, section: "free-models" },
    ],
  },
  {
    group: messages.admin_group_platform,
    items: [
      { icon: <GlobeIcon />, section: "guest" },
      { icon: <CubeIcon />, section: "compute" },
      { icon: <ApiConnectionIcon />, section: "oauth" },
    ],
  },
  {
    group: messages.admin_group_records,
    items: [{ icon: <HistoryIcon />, section: "audit" }],
  },
];

interface AdminObservabilityLink {
  href: string;
  label: string;
}

const stagingObservabilityLinks: AdminObservabilityLink[] = [
  {
    href: "https://afksurf.grafana.net/d/comma-staging-comma-product",
    label: "Comma product",
  },
  {
    href: "https://afksurf.grafana.net/d/comma-staging-billing",
    label: "Billing",
  },
  {
    href: "https://afksurf.grafana.net/d/comma-staging-platform-overview",
    label: "Platform overview",
  },
];

export function observabilityLinksForApiBaseUrl(
  apiBaseUrl: string
): AdminObservabilityLink[] {
  try {
    const hostname = new URL(apiBaseUrl).hostname;
    if (hostname === "salix.comma.surf") return [];
    if (
      hostname === "salix-staging.comma.surf" ||
      hostname === "127.0.0.1" ||
      hostname === "localhost"
    ) {
      return stagingObservabilityLinks;
    }
  } catch {
    return [];
  }

  return [];
}

const setLanguage = (locale: CommaLocale) =>
  AdminBrowser.use((browser) => browser.setLocale(locale));

export function AdminApp({ apiBaseUrl }: { apiBaseUrl: string }) {
  const auth = useAdminService(AdminAuth);
  const state = useAdminState(auth.state);
  if (state.phase !== "signed_in") return <AdminSessionScreen state={state} />;
  return <AdminSurface apiBaseUrl={apiBaseUrl} userEmail={state.lease.email} />;
}

function AdminSurface({
  apiBaseUrl,
  userEmail,
}: {
  apiBaseUrl: string;
  userEmail: string;
}) {
  const auth = useAdminService(AdminAuth);
  const shell = useAdminService(AdminShell);
  const run = useAdminCommand();
  const { accessDenied, section, sidebarCollapsed, sidebarOpen, view } = useAdminState(
    shell.state
  );
  const observabilityLinks = observabilityLinksForApiBaseUrl(apiBaseUrl);
  const selectSection = (nextSection: AdminSection) => run(shell.select(nextSection));
  const signOut = () => run(auth.signOut);

  if (accessDenied) {
    return <AdminAccessDenied onSignOut={signOut} userEmail={userEmail} />;
  }

  return (
    <div
      className="admin-shell"
      data-sidebar-collapsed={sidebarCollapsed ? "true" : "false"}
      data-sidebar-open={sidebarOpen ? "true" : "false"}
      data-testid="admin-app"
    >
      <aside aria-label={messages.admin_nav_label()} className="admin-sidebar">
        <div className="admin-sidebar-brand">
          <img alt="" aria-hidden="true" src={commaLogoUrl} />
          <div>
            <strong>Comma Admin</strong>
            <span>{messages.admin_brand_subtitle()}</span>
          </div>
        </div>

        <button
          aria-keyshortcuts="Meta+K Control+K"
          className="admin-search-trigger"
          onClick={() => run(shell.search.setOpen(true))}
          type="button"
        >
          <SearchIcon aria-hidden="true" />
          <span>{messages.admin_search_trigger()}</span>
          <kbd>⌘K</kbd>
        </button>

        <nav className="admin-nav">
          {navigation.map((group, index) => (
            <div className="admin-nav-group" key={index}>
              {group.group ? <p>{group.group()}</p> : null}
              {group.items.map((item) => (
                <AdminNavButton
                  active={section === item.section}
                  icon={item.icon}
                  key={item.section}
                  label={sectionLabels[item.section]()}
                  onPress={() => selectSection(item.section)}
                />
              ))}
            </div>
          ))}
          {observabilityLinks.length ? (
            <div className="admin-nav-group">
              <p>{messages.admin_grafana_group()}</p>
              {observabilityLinks.map((link) => (
                <AdminExternalNavLink key={link.href} {...link} />
              ))}
            </div>
          ) : null}
        </nav>

        <div className="admin-sidebar-account">
          <MenuTrigger>
            <Button
              aria-label={messages.admin_account_menu({ email: userEmail })}
              className="admin-account-trigger"
              hierarchy="tertiary-gray"
              size="sm"
            >
              <span className="admin-account-trigger-content">
                <span aria-hidden="true" className="admin-account-avatar">
                  {userEmail.slice(0, 1).toUpperCase()}
                </span>
                <span className="admin-account-copy">
                  <strong title={userEmail}>{userEmail}</strong>
                  <span>{messages.admin_account_role()}</span>
                </span>
                <ChevronDownSmallIcon
                  aria-hidden="true"
                  className="admin-account-chevron"
                />
              </span>
            </Button>
            <MenuPopover className="admin-account-menu-popover" placement="top start">
              <Menu
                aria-label={messages.admin_account_actions()}
                onAction={(key) => {
                  if (key === "sign-out") signOut();
                  if (key === "en" || key === "zh-CN") run(setLanguage(key));
                }}
              >
                <MenuItem id="zh-CN">{messages.admin_language_chinese()}</MenuItem>
                <MenuItem id="en">{messages.admin_language_english()}</MenuItem>
                <MenuItem id="sign-out" tone="destructive">
                  {messages.admin_sign_out()}
                </MenuItem>
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </div>
      </aside>

      <button
        aria-hidden={sidebarOpen ? undefined : "true"}
        aria-label={messages.admin_close_navigation()}
        className="admin-sidebar-overlay"
        onClick={() => run(shell.closeSidebar)}
        tabIndex={sidebarOpen ? 0 : -1}
        type="button"
      />

      <main className="admin-main">
        <header className="admin-topbar">
          <div className="admin-topbar-leading">
            <Button
              aria-label={messages.admin_toggle_navigation()}
              hierarchy="tertiary-gray"
              iconLeading={<PanelLeftIcon />}
              iconOnly
              onPress={() => run(shell.toggleSidebar)}
              size="sm"
            />
            <span aria-hidden="true" className="admin-topbar-divider" />
            <div className="admin-topbar-breadcrumb">
              {sectionGroups[section] ? (
                <span>{sectionGroups[section]?.()}</span>
              ) : null}
              <strong>{sectionLabels[section]()}</strong>
            </div>
          </div>
        </header>

        <AdminSearchPalette
          model={shell.search}
          onOpenSection={selectSection}
          onOpenUser={(userId) => run(shell.openUser(userId))}
          sections={navigation.flatMap((group) =>
            group.items.map((item) => ({
              label: sectionLabels[item.section](),
              section: item.section,
            }))
          )}
        />

        <div className="admin-main-content">
          <div className="admin-view-content">
            {view ? <AdminSectionView view={view} /> : null}
          </div>
        </div>
      </main>
    </div>
  );
}

function AdminSectionView({ view }: { view: SectionView }) {
  switch (view.section) {
    case "users":
      return <UsersView model={view.model} />;
    case "oauth":
      return <OAuthClientsView model={view.model} />;
    case "compute":
      return <ComputeNodesView model={view.model} />;
    case "billing":
      return <BillingView model={view.model} />;
    case "free-models":
      return <FreeRouterModelsView model={view.model} />;
    case "guest":
      return <GuestModeView model={view.model} />;
    case "audit":
      return <AuditLogView model={view.model} />;
    case "overview":
      return <OverviewView model={view.model} />;
  }
}

function AdminExternalNavLink({ href, label }: AdminObservabilityLink) {
  return (
    <a
      className="admin-nav-link"
      href={href}
      rel="noreferrer"
      target="_blank"
      title={messages.admin_grafana_link_title({ label })}
    >
      <ChainLinkIcon aria-hidden="true" className="admin-nav-external" />
      <span>{label}</span>
    </a>
  );
}

function AdminNavButton({
  active,
  icon,
  label,
  onPress,
}: {
  active: boolean;
  icon: ReactNode;
  label: string;
  onPress: () => void;
}) {
  return (
    <button
      aria-current={active ? "page" : undefined}
      className="admin-nav-button"
      data-active={active ? "true" : "false"}
      onClick={onPress}
      title={label}
      type="button"
    >
      <span aria-hidden="true" className="admin-nav-icon">
        {icon}
      </span>
      <span>{label}</span>
    </button>
  );
}

function AdminAccessDenied({
  onSignOut,
  userEmail,
}: {
  onSignOut: () => void;
  userEmail: string;
}) {
  return (
    <main className="admin-access-screen">
      <section aria-labelledby="admin-access-title" className="admin-access-card">
        <img alt="" aria-hidden="true" src={commaLogoUrl} />
        <div className="admin-access-copy">
          <Badge color="gray" size="sm" type="pill-outline">
            Comma Admin
          </Badge>
          <h1 id="admin-access-title">{messages.admin_access_required_title()}</h1>
          <p>{messages.admin_access_required_body()}</p>
        </div>
        <div className="admin-access-account">
          <span>{messages.admin_access_current_account()}</span>
          <strong>{userEmail}</strong>
        </div>
        <Button onPress={onSignOut}>{messages.admin_sign_out()}</Button>
      </section>
    </main>
  );
}
