import { useCommaMessages } from "@comma/i18n/react";
import { useState } from "react";
import { Button, GlobeIcon, ScrollArea } from "@comma/ui";
import type { CommaApiClient } from "../../../../api";
import type { BrowserBinding } from "../../../../api/browser";
import {
  browserErrorText,
  browserStatusText,
  browserStorageErrorText,
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

/** Uses the existing main-owned /v1 transport. No renderer bearer or provider URL. */
export function AgentBrowserPanel({
  api,
  workspaceId,
  id,
  binding,
  onRefresh,
}: {
  api: CommaApiClient;
  workspaceId: string;
  id: string;
  binding: BrowserBinding;
  onRefresh: () => void;
}) {
  const messages = useCommaMessages();
  const session = useBrowserSession(api, workspaceId, binding, onRefresh);
  const [text, setText] = useState("");
  const [confirmClear, setConfirmClear] = useState(false);
  return (
    <section
      id={id}
      aria-label={messages.chat_browser_panel()}
      className="mx-xl my-sm min-h-0 shrink-0 rounded-md border border-secondary bg-main-panel-bg p-sm"
    >
      <div className="flex flex-wrap items-center gap-sm">
        <label>
          {messages.chat_browser_tab()}{" "}
          <select
            aria-label={messages.chat_browser_tab_picker()}
            value={session.tab}
            onChange={(event) => session.selectTab(event.target.value)}
          >
            {session.tabs.map((item) => (
              <option key={item.tab_id} value={item.tab_id}>
                {item.title || item.url || messages.chat_browser_new_tab()}
              </option>
            ))}
          </select>
        </label>
        <Button
          size="sm"
          isDisabled={!session.tab || session.pending}
          onPress={session.toggleControl}
        >
          {session.controlling
            ? messages.chat_browser_return_control()
            : messages.chat_browser_take_control()}
        </Button>
        <Button size="sm" isDisabled={session.pending} onPress={session.reconnect}>
          {messages.common_refresh()}
        </Button>
        <Button
          size="sm"
          isDisabled={!session.browser || session.pending}
          onPress={session.closeBrowser}
        >
          {messages.chat_browser_close()}
        </Button>
        {session.sharedStorage ? (
          <Button
            size="sm"
            isDisabled={session.pending}
            onPress={() => setConfirmClear(true)}
          >
            {messages.chat_browser_clear_shared()}
          </Button>
        ) : null}
        <output>{browserStatusText(messages, session.status)}</output>
      </div>
      <p>
        {session.sharedStorage
          ? messages.chat_browser_storage_shared()
          : messages.chat_browser_storage_temporary()}
      </p>
      {confirmClear ? (
        <fieldset aria-label={messages.chat_browser_clear_shared_label()}>
          <p>{messages.chat_browser_clear_shared_confirm()}</p>
          <Button size="sm" isDisabled={session.pending} onPress={session.clearStorage}>
            {messages.chat_browser_clear_and_close()}
          </Button>
          <Button
            size="sm"
            isDisabled={session.pending}
            onPress={() => setConfirmClear(false)}
          >
            {messages.chat_browser_clear_cancel()}
          </Button>
        </fieldset>
      ) : null}
      {session.storageError ? (
        <p role="alert">{browserStorageErrorText(messages, session.storageError)}</p>
      ) : null}
      {session.error ? (
        <p role="alert">{browserErrorText(messages, session.error)}</p>
      ) : null}
      <ScrollArea className="max-h-[65vh]" edgeEffect="none">
        <BrowserScreen
          canvas={session.canvas}
          controlling={session.controlling}
          send={session.send}
          viewport={session.viewport}
        />
      </ScrollArea>
      <form
        className="mt-sm flex gap-sm"
        onSubmit={(event) => {
          event.preventDefault();
          if (text) {
            session.send({ type: "text", text });
            setText("");
          }
        }}
      >
        <input
          aria-label={messages.chat_browser_text()}
          placeholder={messages.chat_browser_text_placeholder()}
          value={text}
          maxLength={4096}
          disabled={!session.controlling}
          onChange={(event) => setText(event.target.value)}
          className="min-w-0 flex-1 rounded border p-xs"
        />
        <Button type="submit" size="sm" isDisabled={!session.controlling || !text}>
          {messages.chat_browser_send_text()}
        </Button>
      </form>
    </section>
  );
}
