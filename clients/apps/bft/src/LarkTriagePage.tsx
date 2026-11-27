import { Button } from "@comma/ui/components/Button";
import { Dropdown, SearchSelect } from "@comma/ui/components/dropdown";
import { Toggle } from "@comma/ui/components/toggle";
import { useEffect, useRef, useState } from "react";
import type {
  BftLarkTriageAgent,
  BftLarkTriageChats,
  BftLarkTriageFilter,
  BftLarkTriageItem,
  BftLarkTriageKind,
  BftLarkTriageOverview,
  BftLarkTriageReveal,
  BftLarkTriageSource,
} from "./api";
import { ConfirmDialog, writeErrorMessage } from "./dialogs";
import { formatDateTime } from "./format";
import { NoSwarms, useSwarmChoice } from "./MeetingsPage";
import { messages } from "./messages";
import { orgHref } from "./navSpec";
import { useApi, useResource, type Resource } from "./resource";
import { spaLinkClick, type LarkTriageView } from "./router";
import { FormDialog, FormSection, SettingsPage, useWrite } from "./settingsForm";
import { Skeleton } from "./states";

const t = messages.larkTriage;

const pages: Record<LarkTriageView, [string, string]> = {
  overview: [t.overviewTitle, t.overviewDescription],
  timeline: [t.timelineTitle, t.timelineDescription],
};

const groupOrder = ["ready", "empty", "unavailable"];

const sourceLabel = (source: BftLarkTriageSource) =>
  source.app_name ?? t.providers[source.provider];

/**
 * Feishu / Lark triage: the pages of one Agent Swarm's Router, chosen in the
 * header and kept in `?agent=`. A write reads the roster again while the
 * page keeps showing what it had.
 */
export function LarkTriagePage({ org, view }: { org: string; view: LarkTriageView }) {
  const api = useApi();
  const [resource, reload] = useResource(`lark-triage:${org}`, (signal) =>
    api.larkTriage(org, signal)
  );
  const last = useRef<BftLarkTriageOverview | undefined>(undefined);
  if (resource.state === "ready") last.current = resource.data;
  const data = resource.state === "ready" ? resource.data : last.current;
  const agents = (data?.agents ?? []).toSorted(
    (a, b) => groupOrder.indexOf(a.state) - groupOrder.indexOf(b.state)
  );
  const [agent, choose] = useSwarmChoice(org, agents, "agent");
  const [refresh, setRefresh] = useState(0);
  const [title, description] = pages[view];

  return (
    <SettingsPage
      actions={
        <>
          {agents.length > 1 ? (
            <Dropdown
              ariaLabel={t.agent}
              items={agents.map((item) => ({
                id: item.id,
                label: item.name,
                subtitle: item.sources.map(sourceLabel).join(" · "),
              }))}
              onChange={choose}
              size="sm"
              width="content"
              {...(agent ? { value: agent.id } : {})}
            />
          ) : null}
          {agent && view === "timeline" ? (
            <button
              className="bft-btn"
              onClick={() => setRefresh((value) => value + 1)}
              type="button"
            >
              {t.refresh}
            </button>
          ) : null}
        </>
      }
      description={description}
      onRetry={reload}
      resource={data ? { state: "ready", data } : resource}
      title={title}
      wide
    >
      {() =>
        !agent ? (
          <NoSwarms body={t.noAgents} />
        ) : view === "overview" ? (
          <Overview agent={agent} key={agent.id} onChanged={reload} org={org} />
        ) : (
          <Timeline agent={agent} key={agent.id} org={org} refresh={refresh} />
        )
      }
    </SettingsPage>
  );
}

interface Notice {
  kind: "info" | "error";
  text: string;
}

function Overview({
  org,
  agent,
  onChanged,
}: {
  org: string;
  agent: BftLarkTriageAgent;
  onChanged: () => void;
}) {
  const api = useApi();
  const sources = agent.sources.map((source) => ({ ...source, id: source.connect_id }));
  const [source, chooseSource] = useSwarmChoice(org, sources, "connect");
  const [notice, setNotice] = useState<Notice>();
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [adding, setAdding] = useState(false);

  // Every write reads the roster again, failed or not: a failed write may
  // still have changed the source.
  const run = (write: () => Promise<string>) => {
    setBusy(true);
    write()
      .then(
        (text) => setNotice({ kind: "info", text }),
        (error: unknown) =>
          setNotice({ kind: "error", text: writeErrorMessage(error) ?? "" })
      )
      .finally(() => {
        setBusy(false);
        setConfirming(false);
        onChanged();
      });
  };

  if (agent.state === "unavailable")
    return <p className="bft-notice">{t.agentUnavailable}</p>;

  if (!source)
    return (
      <FormSection description={t.noSourcesBody} title={t.noSourcesTitle}>
        <a className="bft-link" href={orgHref(org, "/projects")} onClick={spaLinkClick}>
          {t.connectBot}
        </a>
      </FormSection>
    );

  return (
    <>
      {notice?.text ? (
        <p
          className="bft-notice"
          data-kind={notice.kind}
          role={notice.kind === "error" ? "alert" : "status"}
        >
          {notice.text}
        </p>
      ) : null}
      <div className="bft-settings-grid">
        <div>
          <FormSection
            action={
              <Toggle
                aria-label={source.enabled ? t.turnOff : t.turnOn}
                checked={source.enabled}
                disabled={busy}
                label={source.enabled ? t.monitoringOn : t.monitoringOff}
                onChange={() => setConfirming(true)}
                size="sm"
              />
            }
            description={[t.providers[source.provider], agent.project_name]
              .filter(Boolean)
              .join(" · ")}
            title={sourceLabel(source)}
          >
            {sources.length > 1 ? (
              <Dropdown
                className="bft-form-field"
                disabled={busy}
                items={sources.map((item) => ({
                  id: item.connect_id,
                  label: sourceLabel(item),
                  subtitle: t.providers[item.provider],
                }))}
                label={t.source}
                onChange={chooseSource}
                size="sm"
                value={source.connect_id}
              />
            ) : null}
          </FormSection>
        </div>
        <div>
          <FormSection
            action={
              <button
                className="bft-btn bft-btn-sm"
                disabled={busy}
                onClick={() => setAdding(true)}
                type="button"
              >
                {t.addChats}
              </button>
            }
            description={t.chatsHint}
            title={t.chatsTitle}
          >
            {source.chats.length > 0 ? (
              <ul className="bft-list">
                {source.chats.map((chat) => {
                  const name = chat.name ?? chat.id;
                  return (
                    <li className="bft-setting-row" key={chat.id}>
                      <span className="bft-setting-row-main">
                        <span className="bft-row-title">
                          <span className="bft-truncate">{name}</span>
                          <span className="bft-tag">
                            {chat.enabled ? t.chatOn : t.chatOff}
                          </span>
                        </span>
                      </span>
                      <Toggle
                        aria-label={name}
                        checked={chat.enabled}
                        disabled={busy}
                        onChange={(event) =>
                          run(() =>
                            api.setLarkTriageChat(
                              org,
                              agent.id,
                              source.connect_id,
                              chat.id,
                              event.target.checked
                            )
                          )
                        }
                        size="sm"
                      />
                    </li>
                  );
                })}
              </ul>
            ) : (
              <div className="bft-quiet bft-quiet-inline">
                <p>{t.noChatsTitle}</p>
                <p>{t.noChatsBody}</p>
              </div>
            )}
          </FormSection>
        </div>
      </div>
      {confirming ? (
        <ConfirmDialog
          busy={busy}
          confirmLabel={source.enabled ? t.turnOff : t.turnOn}
          description={source.enabled ? t.confirmOff : t.confirmOn}
          destructive={source.enabled}
          error={undefined}
          onClose={() => setConfirming(false)}
          onConfirm={() =>
            run(() =>
              api.setLarkTriageSource(org, agent.id, source.connect_id, !source.enabled)
            )
          }
          title={source.enabled ? t.turnOff : t.turnOn}
        />
      ) : null}
      {adding ? (
        <AddChats
          agent={agent.id}
          onClose={() => setAdding(false)}
          onDone={(text) => {
            setAdding(false);
            setNotice({ kind: "info", text });
            onChanged();
          }}
          org={org}
          source={source}
        />
      ) : null}
    </>
  );
}

const maxNewChats = 20;
const chatIdPattern = /^oc_[A-Za-z0-9_-]{2,125}$/;

interface Pending {
  id: string;
  name: string | null;
}

/**
 * Adds group chats from the bot's list, searched by name. A pasted `oc_` ID
 * is offered as an option and resolved to its name before it is added.
 */
function AddChats({
  org,
  agent,
  source,
  onClose,
  onDone,
}: {
  org: string;
  agent: string;
  source: BftLarkTriageSource;
  onClose: () => void;
  onDone: (notice: string) => void;
}) {
  const api = useApi();
  const write = useWrite();
  const [list, setList] = useState<Resource<BftLarkTriageChats>>({ state: "loading" });
  const [pending, setPending] = useState<Pending[]>([]);
  const [resolving, setResolving] = useState(false);
  const [resolveError, setResolveError] = useState<string>();

  useEffect(() => {
    const controller = new AbortController();
    api.larkTriageChats(org, agent, source.connect_id, null).then(
      (data) => !controller.signal.aborted && setList({ state: "ready", data }),
      (error: unknown) =>
        !controller.signal.aborted && setList({ state: "error", error })
    );
    return () => controller.abort();
  }, [api, org, agent, source.connect_id]);

  const listed = list.state === "ready" ? list.data.chats : [];
  const taken = new Set([
    ...source.chats.map((chat) => chat.id),
    ...pending.map((p) => p.id),
  ]);

  const items = (query: string) => {
    const needle = query.trim();
    const matches = (text: string) => text.toLowerCase().includes(needle.toLowerCase());
    const pasted =
      chatIdPattern.test(needle) &&
      !listed.some((chat) => chat.id === needle) &&
      !taken.has(needle)
        ? needle
        : null;
    return [
      ...listed
        .filter(
          (chat) =>
            !taken.has(chat.id) &&
            (!needle || matches(chat.name ?? "") || chat.id === needle)
        )
        .map((chat) => ({ id: chat.id, label: chat.name ?? chat.id })),
      ...(pasted ? [{ id: pasted, label: t.useChatId(pasted) }] : []),
    ];
  };

  const pick = (id: string) => {
    setResolveError(undefined);
    const known = listed.find((chat) => chat.id === id);
    if (known) {
      setPending((value) => [...value, { id, name: known.name }]);
      return;
    }
    setResolving(true);
    api.larkTriageChats(org, agent, source.connect_id, id).then(
      (data) => {
        setResolving(false);
        const chat = data.chats[0];
        if (chat) setPending((value) => [...value, { id, name: chat.name }]);
        else setResolveError(t.resolveFailed);
      },
      () => {
        setResolving(false);
        setResolveError(t.resolveFailed);
      }
    );
  };

  const hint =
    list.state === "error"
      ? t.chatsUnavailable
      : list.state === "ready" && !list.data.complete
        ? t.chatListPartial
        : undefined;

  return (
    <FormDialog
      description={t.addChatsDescription}
      onClose={onClose}
      onSubmit={() =>
        pending.length > 0 &&
        pending.length <= maxNewChats &&
        write.run(
          () => api.addLarkTriageChats(org, agent, source.connect_id, pending),
          onDone
        )
      }
      submitLabel={t.addSelected}
      title={t.addChats}
      wide
      write={write}
    >
      <SearchSelect
        className="bft-form-field"
        disabled={resolving || pending.length >= maxNewChats}
        display={
          list.state === "loading"
            ? t.chatLoading
            : resolving
              ? t.resolving
              : t.chatChoose
        }
        emptyText={t.chatNoMatches}
        items={items}
        label={t.chatPicker}
        muted
        onChange={pick}
        searchPlaceholder={t.chatSearch}
        value=""
        {...(hint ? { hint } : {})}
      />
      {resolveError ? (
        <p className="bft-dialog-error" role="alert">
          {resolveError}
        </p>
      ) : null}
      {pending.length > 0 ? (
        <>
          <p className="bft-field-label">{t.selected(pending.length)}</p>
          <ul className="bft-list">
            {pending.map((chat) => (
              <li className="bft-setting-row" key={chat.id}>
                <span className="bft-setting-row-main">
                  <span className="bft-truncate">{chat.name ?? chat.id}</span>
                </span>
                <button
                  className="bft-btn bft-btn-sm"
                  disabled={write.busy}
                  onClick={() =>
                    setPending((value) => value.filter((item) => item.id !== chat.id))
                  }
                  type="button"
                >
                  {t.remove}
                </button>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </FormDialog>
  );
}

const kinds = ["all", "reply", "reaction", "silence", "delegate"] as const;
const allChats = "all";

function outcome(item: BftLarkTriageItem) {
  if (item.state === "stale")
    return item.reason_code === "source_disabled" ? t.staleDisabled : t.stale;
  if (item.state === "failed") return t.failed;
  switch (item.kind) {
    case "reply":
      return t.replied;
    case "reaction":
      return t.reacted;
    case "silence":
      return t.silent(
        t.reasons[item.reason_code ?? ""] ?? t.reasons.no_useful_addition ?? ""
      );
    case "delegate":
      return item.reason_code === "worker_unavailable"
        ? t.workerUnavailable
        : t.delegated;
    default:
      return t.failed;
  }
}

function detail(item: BftLarkTriageItem) {
  if (item.kind === "reaction" && item.reaction)
    return t.emoji[item.reaction] ?? item.reaction;
  if (item.kind === "delegate" && item.task_title) return item.task_title;
  return null;
}

/** The Agent's settled batches, newest first, one cursor page at a time. */
function Timeline({
  org,
  agent,
  refresh,
}: {
  org: string;
  agent: BftLarkTriageAgent;
  refresh: number;
}) {
  const api = useApi();
  const [kind, setKind] = useState<(typeof kinds)[number]>("all");
  const [chat, setChat] = useState<string>(allChats);
  const [cursor, setCursor] = useState<string | null>(null);
  const [earlier, setEarlier] = useState<BftLarkTriageItem[]>([]);
  const filter: BftLarkTriageFilter = {
    kind: kind === "all" ? null : (kind as BftLarkTriageKind),
    chat: chat === allChats ? null : chat,
    cursor,
  };
  const [page] = useResource(
    `lark-triage-activity:${org}:${agent.id}:${filter.kind}:${filter.chat}:${cursor}:${refresh}`,
    (signal) => api.larkTriageActivity(org, agent.id, filter, signal)
  );
  const [texts, setTexts] = useState<
    Record<string, BftLarkTriageReveal | { error: string }>
  >({});
  const [open, setOpen] = useState<Record<string, boolean>>({});

  const chats = new Map<string, string>();
  for (const source of agent.sources)
    for (const item of source.chats) chats.set(item.id, item.name ?? item.id);

  const reset = () => {
    setCursor(null);
    setEarlier([]);
  };

  const reveal = (id: string) => {
    if (texts[id] && !("error" in texts[id])) {
      setOpen((value) => ({ ...value, [id]: !value[id] }));
      return;
    }
    api.revealLarkTriageText(org, agent.id, id).then(
      (data) => {
        setTexts((value) => ({ ...value, [id]: data }));
        setOpen((value) => ({ ...value, [id]: true }));
      },
      (error: unknown) =>
        setTexts((value) => ({
          ...value,
          [id]: { error: writeErrorMessage(error) ?? "" },
        }))
    );
  };

  const items = [...earlier, ...(page.state === "ready" ? page.data.items : [])];

  return (
    <div className="bft-triage-main">
      <div className="bft-triage-filters">
        <Dropdown
          ariaLabel={t.show}
          items={kinds.map((id) => ({ id, label: t.kinds[id] }))}
          onChange={(id) => {
            setKind(id as (typeof kinds)[number]);
            reset();
          }}
          size="sm"
          value={kind}
          width="content"
        />
        {chats.size > 0 ? (
          <Dropdown
            ariaLabel={t.chat}
            items={[
              { id: allChats, label: t.allChats },
              ...[...chats].map(([id, label]) => ({ id, label })),
            ]}
            onChange={(id) => {
              setChat(id);
              reset();
            }}
            size="sm"
            value={chat}
            width="content"
          />
        ) : null}
      </div>
      {page.state === "error" ? (
        <p className="bft-notice">{writeErrorMessage(page.error)}</p>
      ) : page.state === "loading" && items.length === 0 ? (
        <Skeleton height={14} />
      ) : items.length === 0 ? (
        <div className="bft-quiet bft-quiet-inline">
          <p>{t.emptyTitle}</p>
          <p>{kind !== "all" || chat !== allChats ? t.noMatchBody : t.emptyBody}</p>
        </div>
      ) : (
        <ol className="bft-list" data-role="lark-triage-feed">
          {items.map((item) => {
            const revealed = texts[item.id];
            const shown =
              open[item.id] === true && revealed && !("error" in revealed)
                ? revealed
                : null;
            const extra = detail(item);
            return (
              <li className="bft-lark-triage-row" key={item.id}>
                <div className="bft-lark-triage-head">
                  <strong className="bft-lark-triage-title bft-truncate">
                    {item.chat_name ?? item.chat_id}
                  </strong>
                  <button
                    className="bft-btn bft-btn-sm"
                    onClick={() => reveal(item.id)}
                    type="button"
                  >
                    {shown ? t.hide : t.reveal}
                  </button>
                </div>
                <p className="bft-setting-row-sub bft-lark-triage-facts">
                  {[
                    outcome(item),
                    extra,
                    item.target
                      ? t.newest(
                          item.target.sender_name ?? t.unknownSender,
                          item.target.sent_at_ms
                            ? formatDateTime(item.target.sent_at_ms)
                            : ""
                        )
                      : null,
                    t.messageCount(item.message_count),
                  ]
                    .filter((part): part is string => Boolean(part))
                    .map((part, index) => (
                      <span
                        key={part}
                        {...(index === 0 ? { "data-role": "outcome" } : {})}
                      >
                        {part}
                      </span>
                    ))}
                </p>
                {shown ? (
                  <div className="bft-lark-triage-text" data-section="lark-triage-text">
                    {shown.messages.map((message) => (
                      <div className="bft-lark-triage-message" key={message.id}>
                        <p className="bft-row-title">
                          <span className="bft-plugin-name">
                            {message.sender_name ?? t.unknownSender}
                          </span>
                          {message.sent_at_ms ? (
                            <time className="bft-tag">
                              {formatDateTime(message.sent_at_ms)}
                            </time>
                          ) : null}
                        </p>
                        <p className="bft-report">{message.text}</p>
                      </div>
                    ))}
                    {shown.reply_text ? (
                      <div className="bft-lark-triage-message">
                        <p className="bft-row-title">
                          <span className="bft-plugin-name">{t.botReply}</span>
                        </p>
                        <p className="bft-report">{shown.reply_text}</p>
                      </div>
                    ) : null}
                    <p className="bft-form-section-note">{t.revealNote}</p>
                  </div>
                ) : revealed && "error" in revealed ? (
                  <p className="bft-dialog-error" role="alert">
                    {revealed.error}
                  </p>
                ) : null}
              </li>
            );
          })}
        </ol>
      )}
      {page.state === "ready" && page.data.next_cursor ? (
        <div className="bft-form-actions">
          <Button
            hierarchy="secondary-gray"
            onPress={() => {
              setEarlier(items);
              setCursor(page.data.next_cursor);
            }}
            size="sm"
          >
            {t.more}
          </Button>
        </div>
      ) : null}
    </div>
  );
}
