import { useCommaMessages } from "@comma/i18n/react";
import {
  Tooltip,
  appKeybindingKeycaps,
  cx,
  LeftRailItemControl,
  leftRailNavClassName,
} from "@comma/ui";
import { useLocation, useNavigate, useRouter } from "@tanstack/react-router";
import {
  useCallback,
  useMemo,
  useRef,
  useState,
  type ReactElement,
  type RefObject,
} from "react";
import { driveSynchronicityAvailable } from "../drive/driveSynchronicityBackend";
import { AppIcon, type AppIconName } from "../icons";
import { useProductInboxSnapshot } from "../../product-inbox";
import {
  inboxHasUnread,
  useInboxDeletedMarks,
  useInboxUnreadMarks,
} from "../inbox/inboxDeletion";
import { useCommaAuth } from "../auth-context";
import { useCommaClientSettings } from "../commaClientSettings";
import { UserAvatar } from "../UserAvatar";
import { useProfileAvatarUrl } from "../useProfileAvatarUrl";
import { useCommaSettingsOverlay } from "../settingsOverlay";
import { useAppShortcutBinding } from "../shortcuts/commaAppShortcuts";
import type { AppShortcutId } from "../shortcuts/appShortcutRegistry";
import { useTaskReviewSeenMarks } from "../tasks/taskReviewAttention";
import { useCommaSidebar } from "./SidebarContext";
import { reconcileSidebarNavOrder, type SidebarNavItemId } from "./sidebarNavOrder";
import { useSidebarNavReorder } from "./useSidebarNavReorder";

type SidebarItem = {
  icon: AppIconName;
  id: SidebarNavItemId;
  shortcutId:
    | "go-comma-assistant"
    | "go-inbox"
    | "go-drive"
    | "go-tasks"
    | "go-plugins";
  to: "/" | "/inbox" | "/drive" | "/tasks" | "/plugins";
};

const sidebarItems: Record<SidebarNavItemId, SidebarItem> = {
  home: { icon: "home", id: "home", shortcutId: "go-comma-assistant", to: "/" },
  inbox: { icon: "inbox", id: "inbox", shortcutId: "go-inbox", to: "/inbox" },
  drive: { icon: "drive", id: "drive", shortcutId: "go-drive", to: "/drive" },
  tasks: { icon: "tasks", id: "tasks", shortcutId: "go-tasks", to: "/tasks" },
  plugins: { icon: "plugins", id: "plugins", shortcutId: "go-plugins", to: "/plugins" },
};

/**
 * The icon rail: primary navigation on top, Settings pinned to the foot. The
 * navigation items reorder by pointer drag; the order is a client setting, so
 * it follows the reader across launches.
 */
export function SidebarChrome() {
  const messages = useCommaMessages();
  const { collapsed } = useCommaSidebar();
  const { settings, update } = useCommaClientSettings();
  const inboxUnread = useInboxTabUnread();
  const { isGuest = false } = useCommaAuth();
  const storedOrder = settings.sidebarNavOrder;
  // Drive needs the synchronicity node only the Electron host runs, so the
  // web rail leaves it out. A guest Session has only Home's Router chat.
  const settledOrder = useMemo(
    () =>
      isGuest
        ? ["home"]
        : reconcileSidebarNavOrder(storedOrder).filter(
            (id) => id !== "drive" || driveSynchronicityAvailable()
          ),
    [isGuest, storedOrder]
  );
  // The drop shows its order at once; the setting owner acknowledges after a
  // round trip on Electron, and the rows must not snap back in between.
  const [committedOrder, setCommittedOrder] = useState<readonly string[] | null>(null);
  const order = committedOrder ?? settledOrder;
  const commitOrder = useCallback(
    (nextOrder: readonly string[]) => {
      setCommittedOrder(nextOrder);
      void update({ sidebarNavOrder: [...nextOrder] })
        .catch(() => {
          // The owner restored its last snapshot; the rows follow it below.
        })
        .finally(() => setCommittedOrder(null));
    },
    [update]
  );
  const { dragging, listRef, registerRow, rowProps } = useSidebarNavReorder({
    onOrderChange: commitOrder,
    order,
    suspended: collapsed || isGuest,
  });

  return (
    <div className="comma-sidebar-body flex min-h-0 flex-1 flex-col items-center justify-between pt-sm">
      <nav
        aria-label={messages.nav_primary()}
        className={cx("comma-sidebar-nav", leftRailNavClassName)}
        ref={listRef}
      >
        {order.map((id) => {
          const item = sidebarItems[id as SidebarNavItemId];
          return (
            <div
              className="comma-sidebar-nav-row"
              data-nav-id={id}
              data-testid="comma-sidebar-nav-row"
              key={id}
              ref={(element) => registerRow(id, element)}
              {...rowProps(id)}
            >
              <SidebarNavLink
                badge={item.id === "inbox" && inboxUnread}
                item={item}
                tooltipDisabled={dragging}
              />
            </div>
          );
        })}
      </nav>
      <SidebarSettingsItem />
    </div>
  );
}

// Settings is a modal over the current surface, so its rail item is a button:
// pressing it must not take the user off the route they are working on.
function SidebarSettingsItem() {
  const messages = useCommaMessages();
  const auth = useCommaAuth();
  const avatarUrl = useProfileAvatarUrl(auth.avatarRevision);
  const { open, openSettings } = useCommaSettingsOverlay();
  const iconRef = useRef<HTMLSpanElement>(null);

  return (
    <SidebarItemTooltip
      label={messages.nav_go_settings()}
      shortcutId="go-settings"
      triggerRef={iconRef}
    >
      <LeftRailItemControl
        item={{
          className: cx("comma-sidebar-link", open && "comma-sidebar-link-active"),
          hideLabel: true,
          icon: (
            <span aria-hidden="true" className="flex">
              <UserAvatar
                displayName={auth.userDisplayName}
                email={auth.userEmail}
                size="sm"
                {...(avatarUrl ? { avatarUrl } : {})}
              />
            </span>
          ),
          iconRef,
          id: "settings",
          label: messages.nav_settings(),
          onPress: openSettings,
          selected: open,
        }}
      />
    </SidebarItemTooltip>
  );
}

function SidebarNavLink({
  badge = false,
  item,
  tooltipDisabled,
}: {
  badge?: boolean;
  item: SidebarItem;
  tooltipDisabled: boolean;
}) {
  // A link reads only whether it is current, so a page switch re-renders the
  // two links it moves between, not every link in the rail. A press reads the
  // location when it happens.
  const active = useLocation({
    select: (location) =>
      location.pathname === item.to ||
      (item.to !== "/" &&
        item.to !== "/tasks" &&
        location.pathname.startsWith(`${item.to}/`)),
  });
  const router = useRouter();
  const messages = useCommaMessages();
  const navigate = useNavigate();
  const label = {
    home: messages.nav_home(),
    inbox: messages.nav_inbox(),
    drive: messages.nav_drive(),
    tasks: messages.nav_tasks(),
    plugins: messages.nav_plugins(),
  }[item.id];
  const tooltipLabel = {
    home: messages.nav_go_home(),
    inbox: messages.nav_go_inbox(),
    drive: messages.nav_go_drive(),
    tasks: messages.nav_go_tasks(),
    plugins: messages.nav_go_plugins(),
  }[item.id];
  const iconRef = useRef<HTMLSpanElement>(null);

  return (
    <SidebarItemTooltip
      isDisabled={tooltipDisabled}
      label={tooltipLabel}
      shortcutId={item.shortcutId}
      triggerRef={iconRef}
    >
      <LeftRailItemControl
        item={{
          badge,
          className: cx("comma-sidebar-link", active && "comma-sidebar-link-active"),
          href: item.to === "/" ? "#/" : `#${item.to}`,
          icon: <AppIcon className="comma-sidebar-icon" name={item.icon} />,
          iconRef,
          id: item.to,
          label,
          onPress: () => {
            if (router.state.location.pathname === item.to) return;
            void navigate({ to: item.to });
          },
          selected: active,
        }}
      />
    </SidebarItemTooltip>
  );
}

// The row spans the rail's full width while only its centred icon slot is
// painted, so the bubble anchors on that slot: a row-anchored tooltip would
// open a rail's worth of empty space away from the glyph the pointer is on.
function SidebarItemTooltip({
  children,
  isDisabled = false,
  label,
  shortcutId,
  triggerRef,
}: {
  children: ReactElement;
  isDisabled?: boolean;
  label: string;
  shortcutId: AppShortcutId;
  triggerRef: RefObject<HTMLSpanElement | null>;
}) {
  const shortcut = useAppShortcutBinding(shortcutId);
  return (
    <Tooltip
      content={label}
      isDisabled={isDisabled}
      placement="right"
      triggerRef={triggerRef}
      {...(shortcut ? { shortcut: appKeybindingKeycaps(shortcut) } : {})}
    >
      {children}
    </Tooltip>
  );
}

/**
 * The authenticated session already retains ProductInbox (NotchTaskSync).
 * The rail reads that snapshot so the Inbox tab can show unread without a
 * second retain.
 */
function useInboxTabUnread() {
  const { productLease } = useCommaAuth();
  const envelope = useProductInboxSnapshot();
  const deletedMarks = useInboxDeletedMarks();
  const unreadMarks = useInboxUnreadMarks();
  const seenMarks = useTaskReviewSeenMarks();
  const items = useMemo(() => {
    if (
      !envelope ||
      productLeaseKey(envelope.session) !== productLeaseKey(productLease)
    ) {
      return [];
    }
    return envelope.snapshot.items;
  }, [envelope, productLease]);
  return inboxHasUnread(items, seenMarks, unreadMarks, deletedMarks);
}

function productLeaseKey(lease: {
  audience: string;
  authorityInstanceId: string;
  generation: number;
  sessionId: string;
}) {
  return JSON.stringify([
    lease.authorityInstanceId,
    lease.generation,
    lease.sessionId,
    lease.audience,
  ]);
}
