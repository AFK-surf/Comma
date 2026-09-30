import { CommaAuthGate, useCommaAuth } from "@comma/app/auth";
import { commaLogoUrl } from "@comma/config";
import {
  Badge,
  Button,
  ChainLinkIcon,
  ChevronDownSmallIcon,
  FileIcon,
  GlobeIcon,
  ListChecksIcon,
  Menu,
  MenuItem,
  MenuPopover,
  MenuTrigger,
  PanelLeftIcon,
  ShieldCheckIcon,
} from "@comma/ui";
import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { createAdminApi, type AdminRedeemTarget } from "./adminApi";
import {
  adminSectionFromSearch,
  adminSectionHref,
  type AdminSection,
} from "./adminNavigation";
import { AuditLogView } from "./AuditLogView";
import { BillingView } from "./BillingView";
import { ModelSelectionView } from "./ModelSelectionView";
import { ComputeNodesView } from "./ComputeNodesView";
import { OAuthClientsView } from "./OAuthClientsView";
import { UsersView } from "./UsersView";

const sectionLabels: Record<AdminSection, string> = {
  audit: "Audit log",
  billing: "Redeem codes",
  compute: "Compute nodes",
  models: "Models",
  oauth: "OAuth clients",
  users: "Users",
};

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

export function AdminApp() {
  return (
    <CommaAuthGate>
      <AdminSurface />
    </CommaAuthGate>
  );
}

function AdminSurface() {
  const { apiBaseUrl, sessionTransport, signOut, userEmail } = useCommaAuth();
  const [accessDenied, setAccessDenied] = useState(false);
  const [redeemTarget, setRedeemTarget] = useState<AdminRedeemTarget>();
  const [section, setSection] = useState<AdminSection>(() =>
    adminSectionFromSearch(window.location.search)
  );
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const api = useMemo(
    () =>
      createAdminApi({
        baseUrl: apiBaseUrl,
        sessionTransport,
      }),
    [apiBaseUrl, sessionTransport]
  );
  const observabilityLinks = useMemo(
    () => observabilityLinksForApiBaseUrl(apiBaseUrl),
    [apiBaseUrl]
  );
  const onAccessDenied = useCallback(() => {
    setAccessDenied(true);
  }, []);
  useEffect(() => {
    const syncSection = () => {
      setSection(adminSectionFromSearch(window.location.search));
      setSidebarOpen(false);
    };
    window.addEventListener("popstate", syncSection);
    return () => window.removeEventListener("popstate", syncSection);
  }, []);
  const selectSection = useCallback((nextSection: AdminSection) => {
    if (adminSectionFromSearch(window.location.search) !== nextSection) {
      window.history.pushState(
        null,
        "",
        adminSectionHref(nextSection, window.location.href)
      );
    }
    setSection(nextSection);
    setSidebarOpen(false);
  }, []);
  const toggleSidebar = useCallback(() => {
    if (window.matchMedia("(max-width: 900px)").matches) {
      setSidebarOpen((current) => !current);
      return;
    }
    setSidebarCollapsed((current) => !current);
  }, []);
  const applyRedeemCodeFor = useCallback(
    (target: AdminRedeemTarget) => {
      setRedeemTarget(target);
      selectSection("billing");
    },
    [selectSection]
  );
  const consumeRedeemTarget = useCallback(() => {
    setRedeemTarget(undefined);
  }, []);

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
      <aside aria-label="Admin navigation" className="admin-sidebar">
        <div className="admin-sidebar-brand">
          <img alt="" aria-hidden="true" src={commaLogoUrl} />
          <div>
            <strong>Comma Admin</strong>
            <span>Operations</span>
          </div>
        </div>

        <nav className="admin-nav">
          <p>Platform</p>
          <AdminNavButton
            active={section === "users"}
            icon={<ListChecksIcon />}
            label="Users"
            onPress={() => selectSection("users")}
          />
          <AdminNavButton
            active={section === "compute"}
            icon={<ListChecksIcon />}
            label="Compute nodes"
            onPress={() => selectSection("compute")}
          />
          <AdminNavButton
            active={section === "oauth"}
            icon={<GlobeIcon />}
            label="OAuth clients"
            onPress={() => selectSection("oauth")}
          />
          <AdminNavButton
            active={section === "billing"}
            icon={<FileIcon />}
            label="Redeem codes"
            onPress={() => selectSection("billing")}
          />
          <AdminNavButton
            active={section === "models"}
            icon={<ListChecksIcon />}
            label="Models"
            onPress={() => selectSection("models")}
          />
          <p>Operations</p>
          <AdminNavButton
            active={section === "audit"}
            icon={<ShieldCheckIcon />}
            label="Audit log"
            onPress={() => selectSection("audit")}
          />
          {observabilityLinks.length ? (
            <>
              <p>Observability · staging</p>
              {observabilityLinks.map((link) => (
                <AdminExternalNavLink key={link.href} {...link} />
              ))}
            </>
          ) : null}
        </nav>

        <div className="admin-sidebar-account">
          <MenuTrigger>
            <Button
              aria-label={`Account menu for ${userEmail}`}
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
                  <span>Administrator</span>
                </span>
                <ChevronDownSmallIcon
                  aria-hidden="true"
                  className="admin-account-chevron"
                />
              </span>
            </Button>
            <MenuPopover className="admin-account-menu-popover" placement="top start">
              <Menu
                aria-label="Account actions"
                onAction={(key) => {
                  if (key === "sign-out") signOut();
                }}
              >
                <MenuItem id="sign-out" tone="destructive">
                  Sign out
                </MenuItem>
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </div>
      </aside>

      <button
        aria-hidden={sidebarOpen ? undefined : "true"}
        aria-label="Close navigation"
        className="admin-sidebar-overlay"
        onClick={() => setSidebarOpen(false)}
        tabIndex={sidebarOpen ? 0 : -1}
        type="button"
      />

      <main className="admin-main">
        <header className="admin-topbar">
          <div className="admin-topbar-leading">
            <Button
              aria-label="Toggle navigation"
              hierarchy="tertiary-gray"
              iconLeading={<PanelLeftIcon />}
              iconOnly
              onPress={toggleSidebar}
              size="sm"
            />
            <span aria-hidden="true" className="admin-topbar-divider" />
            <div className="admin-topbar-breadcrumb">
              <span>Admin</span>
              <strong>{sectionLabels[section]}</strong>
            </div>
          </div>
          <Button
            className="admin-audit-status"
            hierarchy="secondary-gray"
            iconLeading={<ShieldCheckIcon />}
            onPress={() => selectSection("audit")}
            size="sm"
          >
            Audited operations
          </Button>
        </header>

        <div className="admin-main-content">
          <div className="admin-view-content">
            {section === "users" ? (
              <UsersView
                api={api}
                onAccessDenied={onAccessDenied}
                onApplyRedeemCode={applyRedeemCodeFor}
              />
            ) : section === "oauth" ? (
              <OAuthClientsView api={api} onAccessDenied={onAccessDenied} />
            ) : section === "compute" ? (
              <ComputeNodesView api={api} onAccessDenied={onAccessDenied} />
            ) : section === "billing" ? (
              <BillingView
                api={api}
                applyTarget={redeemTarget}
                onAccessDenied={onAccessDenied}
                onApplyTargetConsumed={consumeRedeemTarget}
              />
            ) : section === "models" ? (
              <ModelSelectionView api={api} onAccessDenied={onAccessDenied} />
            ) : (
              <AuditLogView api={api} onAccessDenied={onAccessDenied} />
            )}
          </div>
        </div>
      </main>
    </div>
  );
}

function AdminExternalNavLink({ href, label }: AdminObservabilityLink) {
  return (
    <a
      className="admin-nav-link"
      href={href}
      rel="noreferrer"
      target="_blank"
      title={`${label} — staging Grafana`}
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
          <h1 id="admin-access-title">Admin access required</h1>
          <p>
            This signed-in account is not authorized for the Comma Admin surface. Use an
            active, unrestricted account on the configured admin email domain.
          </p>
        </div>
        <div className="admin-access-account">
          <span>Current account</span>
          <strong>{userEmail}</strong>
        </div>
        <Button onPress={onSignOut}>Sign out</Button>
      </section>
    </main>
  );
}
