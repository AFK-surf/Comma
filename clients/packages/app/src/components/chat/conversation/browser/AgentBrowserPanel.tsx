import { useCommaMessages } from "@comma/i18n/react";
import { useState } from "react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import {
  CloudOffIcon,
  ExclamationTriangleIcon,
  GlobeIcon,
  MoreHorizontalIcon,
  ReloadIcon,
  WindowCursorIcon,
} from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { Tooltip } from "@comma/ui/components/tooltip";
import type {
  BrowserViewTab,
  SessionBrowserBinding as BrowserBinding,
} from "@comma/core/contract";
import {
  browserErrorText,
  browserStatusText,
  browserStorageErrorText,
  type BrowserError,
} from "./browserMessages";
import { BrowserScreen } from "./BrowserScreen";
import { useBrowserSession } from "./useBrowserSession";

export function AgentBrowserTrigger({
  open,
  panelId,
  onToggle,
}: {
  open: boolean;
  panelId: string;
  onToggle: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <Button
      hierarchy="tertiary-gray"
      size="xs"
      iconLeading={<GlobeIcon />}
      aria-expanded={open}
      {...(open ? { "aria-controls": panelId } : {})}
      className="shrink-0 aria-expanded:bg-quaternary aria-expanded:text-primary"
      onPress={onToggle}
    >
      {messages.chat_browser_open()}
    </Button>
  );
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

/** The tab on screen: a picker when the browser has several, else its title and site. */
function TabTitle({
  tabs,
  tab,
  onSelect,
}: {
  tabs: BrowserViewTab[];
  tab: string;
  onSelect: (tab: string) => void;
}) {
  const messages = useCommaMessages();
  const title = (item: BrowserViewTab) =>
    item.title || item.url || messages.chat_browser_new_tab();
  if (tabs.length > 1)
    return (
      <div className="flex min-w-0 flex-1">
        <Dropdown
          ariaLabel={messages.chat_browser_tab_picker()}
          className="min-w-0 max-w-[var(--container-xxs)] flex-1"
          items={tabs.map((item) => ({
            id: item.tab_id,
            label: title(item),
            subtitle: hostOf(item.url),
          }))}
          size="xs"
          value={tab}
          onChange={onSelect}
        />
      </div>
    );
  const shown = tabs.find((item) => item.tab_id === tab);
  return (
    <div className="flex min-w-0 flex-1 items-center gap-sm">
      <GlobeIcon className="size-4 shrink-0 text-fg-quaternary" />
      {/* The site comes first: it is what the reader signs in to. */}
      <span className="shrink-0 text-sm font-medium text-primary">
        {shown?.url ? hostOf(shown.url) : messages.chat_browser_panel()}
      </span>
      {shown?.title ? (
        <span className="min-w-0 truncate text-sm text-tertiary">{shown.title}</span>
      ) : null}
    </div>
  );
}

/** The core streams the browser (`browserView`); the panel draws it and sends the reader's control and input. */
export function AgentBrowserPanel({
  workspaceId,
  id,
  binding,
  onRefresh,
}: {
  workspaceId: string;
  id: string;
  binding: BrowserBinding;
  onRefresh: () => void;
}) {
  const messages = useCommaMessages();
  const session = useBrowserSession(workspaceId, binding, onRefresh);
  const [text, setText] = useState("");
  const [confirmClear, setConfirmClear] = useState(false);
  const status = browserStatusText(messages, session.status, session.controlling);
  const settled = session.status !== "loading" && session.status !== "connecting";
  // Only a view that stopped (its tabs or stream failed) covers the screen; a refused command leaves it live.
  const screenError: BrowserError | undefined =
    session.status === "disconnected" && session.error ? session.error : undefined;
  const notices = [
    ...(session.error && !screenError
      ? [browserErrorText(messages, session.error)]
      : []),
    ...(session.storageError
      ? [browserStorageErrorText(messages, session.storageError)]
      : []),
  ];
  return (
    <section
      id={id}
      aria-label={messages.chat_browser_panel()}
      className="mx-auto my-sm flex w-4/5 min-h-0 shrink-0 flex-col overflow-hidden rounded-xl border border-secondary bg-primary shadow-xs"
    >
      <div className="flex h-12 shrink-0 items-center gap-md border-b border-secondary pr-sm pl-lg">
        <TabTitle tabs={session.tabs} tab={session.tab} onSelect={session.selectTab} />
        {/* While it loads, the screen says so. */}
        <div className="flex shrink-0 items-center gap-xs">
          <Button
            hierarchy={session.status === "waiting" ? "primary" : "secondary-gray"}
            size="xs"
            isDisabled={!session.tab || session.pending}
            onPress={session.toggleControl}
          >
            {session.controlling
              ? messages.chat_browser_return_control()
              : messages.chat_browser_take_control()}
          </Button>
          <Tooltip content={messages.common_refresh()}>
            <Button
              aria-label={messages.common_refresh()}
              hierarchy="tertiary-gray"
              size="xs"
              iconOnly
              iconLeading={<ReloadIcon />}
              isDisabled={session.pending}
              onPress={session.reconnect}
            />
          </Tooltip>
          <MenuTrigger>
            <Button
              aria-label={messages.chat_browser_more()}
              hierarchy="tertiary-gray"
              size="xs"
              iconOnly
              iconLeading={<MoreHorizontalIcon />}
            />
            <MenuPopover placement="bottom end">
              <Menu>
                <MenuItem
                  id="close"
                  isDisabled={!session.browser || session.pending}
                  onAction={session.closeBrowser}
                >
                  {messages.chat_browser_close()}
                </MenuItem>
                {session.sharedStorage ? (
                  <MenuItem
                    id="clear"
                    tone="destructive"
                    isDisabled={session.pending}
                    onAction={() => setConfirmClear(true)}
                  >
                    {messages.chat_browser_clear_shared()}
                  </MenuItem>
                ) : null}
              </Menu>
            </MenuPopover>
          </MenuTrigger>
        </div>
      </div>
      <div className="relative flex justify-center bg-secondary">
        <BrowserScreen
          canvas={session.canvas}
          controlling={session.controlling}
          send={session.send}
          viewport={session.viewport}
        />
        {/* While the agent drives the browser, a thin brand edge marks the screen as its own. */}
        {session.status === "agent" && session.hasFrame && !screenError ? (
          <span
            aria-hidden
            className="pointer-events-none absolute inset-0 rounded-b-[calc(var(--radius-xl)-1px)] ring-1 ring-border-brand ring-inset"
          />
        ) : null}
        {settled && session.hasFrame && !screenError ? (
          <span className="pointer-events-none absolute bottom-md left-1/2 flex -translate-x-1/2 items-center gap-xs rounded-full border border-secondary bg-primary py-xxs pr-md pl-sm text-xs font-medium whitespace-nowrap text-secondary shadow-xs">
            {session.controlling ? (
              <WindowCursorIcon className="size-3.5 text-utility-brand-400" />
            ) : null}
            {/* The agent at work: the shared "still working" shine, which runs on the compositor. */}
            <output
              className={session.status === "agent" ? "comma-shiny-text" : undefined}
            >
              {status}
            </output>
          </span>
        ) : null}
        {screenError ? (
          <div className="absolute inset-0 flex items-center justify-center p-xl">
            <div className="flex max-w-[var(--container-xs)] flex-col items-center gap-md rounded-xl border border-secondary bg-primary p-xl text-center shadow-lg">
              <CloudOffIcon className="size-6 text-fg-quaternary" />
              <p className="text-sm text-secondary">
                {browserErrorText(messages, screenError)}
              </p>
              <Button
                hierarchy="secondary-gray"
                size="xs"
                iconLeading={<ReloadIcon />}
                onPress={session.reconnect}
              >
                {messages.chat_browser_reconnect()}
              </Button>
            </div>
          </div>
        ) : !session.hasFrame ? (
          <div className="absolute inset-0 flex items-center justify-center gap-sm text-sm text-tertiary">
            <LoadingIndicator label={status} />
            <span aria-hidden>{status}</span>
          </div>
        ) : null}
      </div>
      {notices.map((notice) => (
        <p
          key={notice}
          role="alert"
          className="flex items-start gap-sm border-t border-secondary px-lg py-sm text-xs text-warning-primary"
        >
          <ExclamationTriangleIcon className="mt-px size-4 shrink-0" />
          {notice}
        </p>
      ))}
      {session.controlling ? (
        <div className="flex flex-col gap-sm border-t border-secondary px-lg py-md">
          <form
            className="flex items-center gap-sm"
            onSubmit={(event) => {
              event.preventDefault();
              if (text) {
                session.send({ type: "text", text });
                setText("");
              }
            }}
          >
            <InputField
              aria-label={messages.chat_browser_text()}
              className="w-auto min-w-0 flex-1"
              fieldSize="sm"
              placeholder={messages.chat_browser_text()}
              value={text}
              maxLength={4096}
              onChange={(event) => setText(event.target.value)}
            />
            <Button
              type="submit"
              hierarchy="secondary-gray"
              size="sm"
              isDisabled={!text}
            >
              {messages.chat_browser_send_text()}
            </Button>
          </form>
          {/* What the reader signs in to here stays for the workspace's other tasks. */}
          <p className="text-xs text-tertiary">
            {session.sharedStorage
              ? messages.chat_browser_storage_shared()
              : messages.chat_browser_storage_temporary()}
          </p>
        </div>
      ) : null}
      <Dialog
        isOpen={confirmClear}
        isDismissable={!session.pending}
        onOpenChange={setConfirmClear}
        title={messages.chat_browser_clear_shared_label()}
        description={messages.chat_browser_clear_shared_confirm()}
        actions={[
          {
            label: messages.chat_browser_clear_cancel(),
            hierarchy: "secondary-gray",
            disabled: session.pending,
            onPress: () => setConfirmClear(false),
          },
          {
            label: messages.chat_browser_clear_and_close(),
            hierarchy: "destructive",
            disabled: session.pending,
            onPress: () => {
              setConfirmClear(false);
              session.clearStorage();
            },
          },
        ]}
      />
    </section>
  );
}
