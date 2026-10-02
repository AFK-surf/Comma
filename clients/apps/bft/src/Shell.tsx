import {
  Button,
  ChevronDownSmallIcon,
  CommandPalette,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  ScrollArea,
  SearchIcon,
  type CommandPaletteGroup,
} from "@comma/ui";
import { useEffect, useMemo, useState, type ReactNode } from "react";
import type { BftOrgContext } from "./api";
import { FlashNotice } from "./flash";
import { initials } from "./format";
import { messages } from "./messages";
import { navIcons } from "./navIcons";
import {
  buildOrgNav,
  flattenNav,
  isNavItemActive,
  isNavLinkActive,
  type NavItem,
  type NavLink,
} from "./navSpec";
import { go, normalizePath, spaLinkClick } from "./router";
import { signOut } from "./session";

const t = messages.topBar;

export function Shell({
  children,
  context,
  pathname,
}: {
  children: ReactNode;
  context: BftOrgContext | undefined;
  pathname: string;
}) {
  const nav = useMemo(
    () =>
      context
        ? buildOrgNav({
            org: context.org.slug,
            capabilities: context.capabilities,
            projects: context.projects,
            pathname,
          })
        : [],
    [context, pathname]
  );
  const [paletteOpen, setPaletteOpen] = useState(false);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setPaletteOpen((open) => !open);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  return (
    <div className="bft-shell">
      <header className="bft-topbar">
        <OrgSwitcher context={context} />
        <button
          aria-keyshortcuts="Meta+K Control+K"
          aria-label={t.searchLabel}
          className="bft-search"
          disabled={!context}
          onClick={() => setPaletteOpen(true)}
          type="button"
        >
          <SearchIcon className="bft-search-icon" />
          <span className="bft-search-text">{t.searchPlaceholder}</span>
          <kbd>{isApplePlatform() ? "⌘K" : "Ctrl K"}</kbd>
        </button>
        <div className="bft-topbar-end">
          {context ? <UserMenu user={context.user} /> : null}
        </div>
      </header>
      <div className="bft-body">
        <Sidebar nav={nav} pathname={pathname} />
        <main className="bft-main">
          <FlashNotice pathname={pathname} />
          {children}
        </main>
      </div>
      {context ? (
        <NavPalette nav={nav} onOpenChange={setPaletteOpen} open={paletteOpen} />
      ) : null}
    </div>
  );
}

function isApplePlatform() {
  return /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
}

function OrgSwitcher({ context }: { context: BftOrgContext | undefined }) {
  if (!context) {
    return (
      <div className="bft-org-switcher">
        <span className="bft-skeleton" style={{ width: 120, height: 14 }} />
      </div>
    );
  }
  return (
    <MenuTrigger>
      <Button
        aria-label={`${t.orgSwitcher}: ${context.org.name}`}
        className="bft-org-switcher bft-org-trigger"
        hierarchy="tertiary-gray"
        size="sm"
      >
        <span className="bft-org-trigger-content">
          <span className="bft-org-name">{context.org.name}</span>
          <ChevronDownSmallIcon className="bft-org-chevron" />
        </span>
      </Button>
      <MenuPopover className="bft-menu-popover" placement="bottom start">
        <Menu aria-label={t.orgSwitcher}>
          {context.orgs.map((org) => (
            <MenuItem
              href={`/orgs/${encodeURIComponent(org.slug)}`}
              id={`org:${org.slug}`}
              key={org.slug}
              textValue={org.name}
            >
              <span className="bft-menu-row">
                <span className="bft-truncate">{org.name}</span>
                {org.slug === context.org.slug ? (
                  <span className="bft-menu-current" aria-hidden="true" />
                ) : null}
              </span>
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

function UserMenu({ user }: { user: BftOrgContext["user"] }) {
  const label = user.name ?? user.email ?? "";
  return (
    <MenuTrigger>
      <Button
        aria-label={`${t.accountMenu}: ${label}`}
        className="bft-avatar-button"
        hierarchy="tertiary-gray"
        size="sm"
      >
        <span aria-hidden="true" className="bft-avatar">
          {initials(user.name, user.email)}
        </span>
      </Button>
      <MenuPopover className="bft-menu-popover" placement="bottom end">
        <Menu aria-label={t.accountMenu}>
          <MenuItem id="identity" isDisabled textValue={label}>
            <span className="bft-identity">
              {user.name ? <strong className="bft-truncate">{user.name}</strong> : null}
              {user.email ? <span className="bft-truncate">{user.email}</span> : null}
            </span>
          </MenuItem>
          <MenuSeparator />
          <MenuItem id="sign-out" onAction={signOut}>
            {t.signOut}
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

function Sidebar({ nav, pathname }: { nav: NavItem[]; pathname: string }) {
  return (
    <ScrollArea
      className="bft-sidebar"
      contentClassName="bft-sidebar-content"
      edgeEffect="none"
      orientation="vertical"
      scrollbarVisibility="hover"
      viewportClassName="bft-scroll-viewport"
    >
      <nav aria-label={messages.nav.label} className="bft-nav">
        {nav.length === 0
          ? Array.from({ length: 7 }, (_, index) => (
              <span className="bft-nav-skeleton" key={index}>
                <span className="bft-skeleton" />
              </span>
            ))
          : nav.map((item) => {
              const active = isNavItemActive(item, pathname);
              const expanded = active && item.children.length > 0;
              const childActive = item.children.some((child) =>
                isNavLinkActive(child, pathname)
              );
              const Icon = navIcons[item.icon];
              return (
                <div className="bft-nav-group" key={item.id}>
                  <a
                    aria-current={active && !childActive ? "page" : undefined}
                    className="bft-nav-item"
                    data-state={
                      active ? (childActive ? "parent" : "active") : undefined
                    }
                    href={item.href}
                    onClick={item.spa ? spaLinkClick : undefined}
                    title={item.label}
                  >
                    <Icon className="bft-nav-icon" />
                    <span className="bft-nav-label">{item.label}</span>
                    {item.children.length > 0 ? (
                      <ChevronDownSmallIcon className="bft-nav-chevron" />
                    ) : null}
                  </a>
                  {expanded ? (
                    <SubNav links={item.children} pathname={pathname} />
                  ) : null}
                </div>
              );
            })}
      </nav>
    </ScrollArea>
  );
}

function SubNav({
  links,
  nested = false,
  pathname,
}: {
  links: NavLink[];
  nested?: boolean;
  pathname: string;
}) {
  const current = normalizePath(pathname);
  return (
    <div className={nested ? "bft-subnav bft-subnav-nested" : "bft-subnav"}>
      {links.map((link) => {
        const pages = link.children ?? [];
        // An entry with its own pages hands "current page" to the matching page.
        const exact = current === link.href && pages.length === 0;
        return (
          <div className="bft-subnav-group" key={link.id}>
            <a
              aria-current={exact ? "page" : undefined}
              className="bft-subnav-item"
              data-state={
                !exact && isNavLinkActive(link, pathname) ? "parent" : undefined
              }
              href={link.href}
              onClick={link.spa ? spaLinkClick : undefined}
              title={link.label}
            >
              {link.label}
            </a>
            {pages.length > 0 ? (
              <SubNav links={pages} nested pathname={pathname} />
            ) : null}
          </div>
        );
      })}
    </div>
  );
}

function NavPalette({
  nav,
  onOpenChange,
  open,
}: {
  nav: NavItem[];
  onOpenChange: (open: boolean) => void;
  open: boolean;
}) {
  const [query, setQuery] = useState("");
  const entries = useMemo(() => flattenNav(nav), [nav]);
  const groups = useMemo<CommandPaletteGroup[]>(() => {
    const needle = query.trim().toLowerCase();
    const matches = entries.filter(({ link, parent }) =>
      needle
        ? // The last path segment makes short forms such as "sso" findable.
          `${parent?.label ?? ""} ${link.label} ${link.href.split("/").pop()}`
            .toLowerCase()
            .includes(needle)
        : true
    );
    return [
      {
        id: "pages",
        heading: t.paletteGroupPages,
        items: matches.map(({ icon, link, parent }) => {
          const Icon = navIcons[icon];
          return {
            value: link.href,
            title: link.label,
            icon: <Icon />,
            ...(parent ? { subtitle: parent.label } : {}),
          };
        }),
      },
    ];
  }, [entries, query]);

  const close = (next: boolean) => {
    onOpenChange(next);
    if (!next) setQuery("");
  };

  return (
    <CommandPalette
      emptyTitle={t.paletteEmpty}
      groups={groups}
      label={t.paletteLabel}
      onOpenChange={close}
      onQueryChange={setQuery}
      onSelect={(item) => {
        close(false);
        go(item.value);
      }}
      open={open}
      placeholder={t.palettePlaceholder}
      query={query}
    />
  );
}
