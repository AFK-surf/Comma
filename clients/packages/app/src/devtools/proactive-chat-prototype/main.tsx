// Throwaway UI: five fictional scenarios in Comma Home, with three presentation
// variants selected by ?variant=A|B|C. No provider, model, or product mutations.
// Visual thesis: Comma's warm neutral Home, quiet typography, one useful message.
// Content: scenario controls, existing Home composition, observable result.
// Interaction: message entrance, card settlement, source drawer reveal.
import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { ScrollArea } from "../../../../ui/src/components/scroll-area/ScrollArea";
import { CommaMascot } from "../../../../ui/src/components/comma-mascot/CommaMascot";
import {
  HomeIcon,
  ListChecksIcon,
  CalendarIcon,
  InboxIcon,
  BellIcon,
  ClockIcon,
  CheckIcon,
  ArrowRightIcon,
  ArrowLeftIcon,
  ArrowUpIcon,
  PaperclipIcon,
  XIcon,
  ChevronDownIcon,
  ReloadIcon,
  FileTextIcon,
  CreditCard2Icon,
} from "../../../../ui/src/components/icons";
import "../../../../ui/src/styles.css";
import "./prototype.css";

type SceneId = "urgent" | "bill" | "unhandled" | "waiting" | "quiet";
type Phase = "new" | "snoozed" | "draft" | "done" | "replied";
type Variant = "A" | "B" | "C";
type Scene = {
  label: string;
  kicker: string;
  title: string;
  time: string;
  intro: string;
  previous: string;
  reply: string;
  message: string;
  source: string;
  sender: string;
  sourceDate: string;
  body: string;
  detail: string;
  primary: string;
  snooze: string;
  done: string;
  draft: string;
  task: string;
  note: string;
};
const scenes: Record<SceneId, Scene> = {
  urgent: {
    label: "重要邮件",
    kicker: "新邮件到达",
    title: "今天 17:00 前，确认试点排期",
    time: "14:32",
    intro: "林澈的邮件刚到，今天需要你确认。",
    previous: "帮我留意 Nimbus 的试点邮件，需要我确认的进展直接叫我。",
    reply: "好，有需要你确认的进展，我会在这里提醒。",
    message:
      "林澈刚发来试点排期，需要你今天 17:00 前确认。上线日从周四改到了周五，其他条件没变。\n\n我可以先起草一封确认回复，你看过再发。",
    source: "Nimbus 试点 · 排期确认",
    sender: "林澈 · Nimbus",
    sourceDate: "今天 14:31",
    body: "Peng 你好，\n\n试点上线时间需要从本周四调整到周五，合作范围和费用保持不变。请在今天 17:00 前确认，方便我们锁定实施排期。\n\n林澈",
    detail: "今天 17:00 前确认",
    primary: "帮我起草",
    snooze: "16:00 再提醒",
    done: "我已处理",
    draft:
      "林澈你好，\n\n收到排期调整，周五上线可以，合作范围和费用按原约定执行。请按这个时间安排，谢谢。\n\nPeng",
    task: "起草 Nimbus 排期确认回复",
    note: "新事件 → 一条主动消息；点击起草后，才出现 Comma Task。",
  },
  bill: {
    label: "账单到期",
    kicker: "约定的提醒时间到了",
    title: "明天到期的信用卡账单",
    time: "09:00",
    intro: "这是你之前约定的还款提醒。",
    previous: "这期信用卡还款前一天提醒我，付完就不用再提醒。",
    reply: "好。账单到期前一天提醒你，确认还款后就停止这次提醒。",
    message:
      "你的明川银行信用卡账单明天（9 月 22 日）到期，应还 ¥3,680。邮件里还没有还款确认。\n\n如果已经还了，告诉我一声，我就停止这次提醒。",
    source: "明川银行 · 9 月信用卡账单",
    sender: "明川银行（虚构）",
    sourceDate: "9 月 8 日 08:00",
    body: "本期账单\n\n应还金额：人民币 3,680.00 元\n到期还款日：2026 年 9 月 22 日\n\n此邮件是账单通知，不是还款凭证。",
    detail: "明天到期 · ¥3,680",
    primary: "查看账单",
    snooze: "今晚 20:00 提醒",
    done: "我已还款",
    draft: "",
    task: "",
    note: "简单定时提醒；点“我已还款”后，卡片收起，下次检查停止。",
  },
  unhandled: {
    label: "待你处理",
    kicker: "到期前复查",
    title: "合同修订意见还等你确认",
    time: "10:15",
    intro: "周三要定稿，先留一点处理时间。",
    previous: "合同周三要定稿，周一帮我检查一下还有没有没处理的意见。",
    reply: "好，周一检查最新邮件线程，只提醒还需要你处理的部分。",
    message:
      "林澈周四发来的合同修订意见，还没看到你的邮件回复，周三需要定稿。\n\n如果已在其他地方处理，告诉我就好；否则我可以先整理三处改动，方便你确认。",
    source: "合作合同 v3 · 三处修订待确认",
    sender: "林澈 · Nimbus",
    sourceDate: "9 月 17 日 16:20",
    body: "Peng 你好，\n\nv3 有三处修订：\n1. 项目交付日期改为 10 月 15 日。\n2. 付款节点改为验收后 15 天。\n3. 增加交付资料清单。\n\n请在下周三定稿前确认，谢谢。",
    detail: "周三定稿 · 3 处修订",
    primary: "整理三处改动",
    snooze: "明天上午再看",
    done: "我已处理",
    draft:
      "需要你确认的三处变化：\n\n交付时间：10 月 15 日。\n付款节点：验收后 15 天。\n交付范围：增加资料清单。\n\n原邮件没有说明这些变化是否已经线下达成一致，仍需你确认。",
    task: "整理合同 v3 修订意见",
    note: "没有邮件回复不等于没有处理；用户确认后停止，不用“未读”推断状态。",
  },
  waiting: {
    label: "等待回复",
    kicker: "等待满 3 天",
    title: "报价发出 3 天，尚无邮件回复",
    time: "11:00",
    intro: "Alex 的报价确认可以跟进一下。",
    previous: "报价发给 Alex 了，三天没回复的话，帮我跟进一下。",
    reply: "好，三天后先检查这个邮件线程，有回复就不再催。",
    message:
      "你周五发给 Alex 的报价确认，还没收到邮件回复，现在过去 3 天了。\n\n要我起草一封简短跟进吗？如果线下已经确认，就不用再追。",
    source: "Re: Nimbus 年度方案报价",
    sender: "Peng → Alex",
    sourceDate: "9 月 18 日 11:00",
    body: "Alex 你好，\n\n附件是我们讨论的年度方案报价。方便时请确认是否可以按此推进。\n\nPeng\n\n当前线程尚无后续邮件回复。",
    detail: "等 Alex 回复 · 已 3 天",
    primary: "起草跟进",
    snooze: "明天再看",
    done: "已经确认",
    draft:
      "Alex 你好，\n\n想跟进一下上周五发来的年度方案报价。你看过了吗？如有需要调整的地方，欢迎告诉我。\n\nPeng",
    task: "跟进 Alex 的报价确认",
    note: "同一 Task 继续跟进；试试“模拟收到回复”，检查会停止，聊天不会多发一句。",
  },
  quiet: {
    label: "无需打扰",
    kicker: "新邮件到达，但已处理",
    title: "邮件到了，这次不打扰",
    time: "15:08",
    intro: "聊天已经有结论，保持安静。",
    previous: "刚在 Slack 和林澈确认了，排期就按周五走，这件事处理好了。",
    reply: "收到，按周五的排期。这件事不再提醒。",
    message: "",
    source: "Re: Nimbus 试点 · 排期确认",
    sender: "林澈 · Nimbus",
    sourceDate: "今天 15:08",
    body: "收到，按刚才 Slack 确认的排期，周五上线。\n\n没有其他需要确认的事项。",
    detail: "已在聊天中确认",
    primary: "查看邮件",
    snooze: "",
    done: "",
    draft: "",
    task: "",
    note: "新邮件只是重复已确认的信息：聊天 0 条新增消息，Routine 不重新生成待办。",
  },
};
const inlineSummary: Record<SceneId, string> = {
  urgent: "上线由周四改到周五，范围与费用不变。请在今天 17:00 前确认。",
  bill: "应还 ¥3,680，9 月 22 日到期。邮件中尚无还款确认；如果已还款，告诉我即可。",
  unhandled:
    "周三要定稿，邮件内有三处修订，还没看到你的回复。若已在线下处理，可直接确认。",
  waiting: "周五的报价邮件尚无回复，可以先起草一封跟进。若已在线下确认，就停止催办。",
  quiet: "",
};
const variantNames: Record<Variant, string> = {
  A: "聊天 + Routine",
  B: "消息内行动卡",
  C: "轻提示后展开",
};
const phases: Record<Phase, string> = {
  new: "需要你留意",
  snoozed: "稍后再检查",
  draft: "草稿待你查看",
  done: "已确认处理",
  replied: "收到回复，停止跟进",
};
const qs = new URLSearchParams(location.search);
const initialScene = (
  Object.keys(scenes).includes(qs.get("scene") ?? "") ? qs.get("scene") : "urgent"
) as SceneId;
const initialVariant = (
  ["A", "B", "C"].includes(qs.get("variant") ?? "") ? qs.get("variant") : "A"
) as Variant;

function App() {
  const [sceneId, setSceneId] = useState<SceneId>(initialScene);
  const [variant, setVariant] = useState<Variant>(initialVariant);
  const [phase, setPhase] = useState<Phase>("new");
  const [drawer, setDrawer] = useState<"source" | "task" | null>(null);
  const [expanded, setExpanded] = useState(false);
  const [input, setInput] = useState("");
  const [notice, setNotice] = useState("");
  const [advanced, setAdvanced] = useState(false);
  const [delegated, setDelegated] = useState(false);
  const chatViewport = useRef<HTMLDivElement>(null);
  const scene = scenes[sceneId];
  const quiet = sceneId === "quiet";
  const greeting = ["bill", "unhandled", "waiting"].includes(sceneId)
    ? "上午好，Peng"
    : "下午好，Peng";
  const settled = phase === "done" || phase === "replied" || quiet;
  const actionable = !settled && phase !== "snoozed" && phase !== "draft";
  const taskExists = sceneId === "waiting" || delegated;
  const timestamp = advanced
    ? sceneId === "bill"
      ? "20:00"
      : sceneId === "urgent"
        ? "16:00"
        : "明天 09:00"
    : scene.time;

  function reset(nextScene = sceneId) {
    setSceneId(nextScene);
    setPhase("new");
    setDrawer(null);
    setExpanded(false);
    setInput("");
    setNotice("");
    setAdvanced(false);
    setDelegated(false);
  }
  const switchVariant = useCallback((delta: number) => {
    const list: Variant[] = ["A", "B", "C"];
    setVariant((current) => list[(list.indexOf(current) + delta + 3) % 3]!);
  }, []);
  useEffect(() => {
    const url = new URL(location.href);
    url.searchParams.set("variant", variant);
    url.searchParams.set("scene", sceneId);
    history.replaceState(null, "", url);
  }, [variant, sceneId]);
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDrawer(null);
      if (
        (e.target as HTMLElement).closest(
          "input,textarea,select,[contenteditable],button"
        )
      )
        return;
      if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        switchVariant(e.key === "ArrowLeft" ? -1 : 1);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [switchVariant]);
  useEffect(() => {
    const frame = requestAnimationFrame(() => {
      const viewport = chatViewport.current;
      if (viewport) viewport.scrollTo({ top: viewport.scrollHeight });
    });
    return () => cancelAnimationFrame(frame);
  }, [sceneId, phase, variant, expanded, advanced]);
  function action(kind: "primary" | "snooze" | "done") {
    setNotice("");
    if (kind === "primary") {
      if (!scene.draft) setDrawer("source");
      else {
        setDelegated(true);
        setPhase("draft");
        setExpanded(true);
      }
    }
    if (kind === "snooze") {
      setPhase("snoozed");
      setExpanded(true);
    }
    if (kind === "done") {
      setPhase("done");
      setExpanded(true);
    }
  }
  function send() {
    if (!input.trim()) return;
    if (/已|还了|停止|不用/.test(input)) action("done");
    else if (/明天|稍后|晚上|再提醒|再看/.test(input)) action("snooze");
    else if (/起草|整理/.test(input)) action("primary");
    else
      setNotice("自由聊天未接入模型。请用快捷操作体验，或输入“我已处理”“稍后提醒”。");
    setInput("");
  }
  function renderSourceLink() {
    return (
      <button className="source-link" onClick={() => setDrawer("source")}>
        <span className="mail-mark">M</span>
        <span>{scene.source}</span>
        <ArrowRightIcon />
      </button>
    );
  }
  function renderActions() {
    return (
      <div className="actions">
        <button className="action primary" onClick={() => action("primary")}>
          {scene.primary}
          <ArrowRightIcon />
        </button>
        <button className="action" onClick={() => action("snooze")}>
          <ClockIcon />
          {scene.snooze}
        </button>
        <button className="action text-action" onClick={() => action("done")}>
          <CheckIcon />
          {scene.done}
        </button>
      </div>
    );
  }
  function renderRoutineCard({ compact = false }: { compact?: boolean }) {
    return (
      <article
        className={`routine-card ${settled ? "settled" : ""} ${compact ? "compact" : ""}`}
      >
        <div className="card-source">
          <span className="mail-mark">M</span>Gmail<span className="card-dot">·</span>
          <span>
            {phase === "snoozed" ? "已安排" : settled ? "已处理" : "需要留意"}
          </span>
        </div>
        <button
          className="card-title"
          onClick={() => {
            if (variant === "C") setExpanded(true);
            else setDrawer("source");
          }}
        >
          {phase === "replied" ? "Alex 已回复报价确认" : scene.title}
        </button>
        <p>
          {settled
            ? phase === "replied"
              ? "对方已回复，本次催办停止"
              : "这件事不再提醒"
            : phase === "snoozed"
              ? scene.snooze
              : phase === "draft"
                ? "草稿已准备好，等你查看"
                : scene.detail}
        </p>
        {settled ? (
          <div className="settled-row">
            <CheckIcon />
            {quiet ? "已确认，无需再提醒" : "已从待处理移除"}
          </div>
        ) : (
          <button
            className="card-open"
            onClick={() =>
              phase === "draft"
                ? setDrawer("task")
                : variant === "C"
                  ? setExpanded(true)
                  : setDrawer("source")
            }
          >
            {phase === "draft"
              ? "查看草稿"
              : variant === "C"
                ? "看看怎么回事"
                : "查看原邮件"}
            <ArrowRightIcon />
          </button>
        )}
      </article>
    );
  }
  function renderRoutineRail() {
    return (
      <aside className="routine-rail">
        <ScrollArea
          className="rail-scroll"
          edgeEffect="none"
          scrollbarVisibility="hover"
        >
          <div className="rail-label">
            Routine<span>{settled ? 0 : 1}</span>
          </div>
          <div className="greeting">
            {greeting}
            <span>9 月 21 日，星期一</span>
          </div>
          <p className="daily-brief">
            {settled ? "这件事已经有了结果，今天少一件需要惦记的事。" : scene.intro}
          </p>
          {renderRoutineCard({})}
          <div className="routine-other">
            <span className="section-caption">稍后可以看看</span>
            <button onClick={() => setNotice("这是背景内容；本稿只演示主动提醒场景。")}>
              整理本周的产品反馈
              <ArrowRightIcon />
            </button>
            <small>来自你上周保存的 4 条反馈</small>
          </div>
          <div className="rail-foot">
            <span className="live-dot" />
            已连接 Gmail
          </div>
        </ScrollArea>
      </aside>
    );
  }
  function renderTaskRail() {
    return (
      <aside className="task-rail">
        <div className="rail-label">
          Tasks<span>{taskExists ? 1 : 0}</span>
        </div>
        {taskExists ? (
          <button className="task-item" onClick={() => setDrawer("task")}>
            <span className="task-state">
              <span
                className={`state-ring ${phase === "draft" || phase === "replied" ? "review" : ""}`}
              />
              {phase === "draft" || phase === "replied"
                ? "待你验收"
                : phase === "done"
                  ? "已完成"
                  : "进行中"}
            </span>
            <strong>{scene.task}</strong>
            <small>
              {phase === "draft"
                ? "草稿已准备好"
                : phase === "replied"
                  ? "收到回复，跟进已停止"
                  : phase === "done"
                    ? "你已确认结果"
                    : "到期检查同一邮件线程"}
            </small>
            <span className="task-open">
              查看任务
              <ArrowRightIcon />
            </span>
          </button>
        ) : (
          <div className="task-empty">
            <ListChecksIcon />
            <p>暂时没有进行中的任务</p>
            <small>把需要做的事交给 Comma</small>
          </div>
        )}
      </aside>
    );
  }
  function renderChat({ inline = false }: { inline?: boolean }) {
    return (
      <section className={`chat ${inline ? "wide-chat" : ""}`} aria-label="Comma 聊天">
        <ScrollArea
          ref={chatViewport}
          className="chat-scroll"
          edgeEffect="none"
          scrollbarVisibility="hover"
        >
          <div className="transcript">
            <div className="day-divider">今天 · 9 月 21 日</div>
            <details className="previous-conversation" open={quiet}>
              <summary>
                此前的对话
                <ChevronDownIcon />
              </summary>
              <div className="user-message">{scene.previous}</div>
              <div className="past-reply">{scene.reply}</div>
            </details>
            {!quiet && (
              <div className="new-divider">
                <span />
                {advanced ? "到约定的复查时间了" : "Comma 有一件事想提醒你"}
                <span />
              </div>
            )}
            {!quiet && (
              <div className="assistant-message enter" key={`${sceneId}-${advanced}`}>
                <div className="message-author">
                  <span className="comma-avatar">
                    <CommaMascot />
                  </span>
                  <strong>Comma</strong>
                  <time>{timestamp}</time>
                  <span className="trigger-label">{scene.kicker}</span>
                </div>
                {inline ? (
                  <>
                    <article
                      className={`inline-action-card ${settled ? "settled" : ""}`}
                    >
                      <div className="inline-card-header">
                        {sceneId === "bill" ? <CreditCard2Icon /> : <InboxIcon />}
                        <span>{scene.detail}</span>
                      </div>
                      <h2>{scene.title}</h2>
                      <p>{inlineSummary[sceneId]}</p>
                      {renderSourceLink()}
                      {actionable && renderActions()}
                      {!actionable && (
                        <div className="inline-status">
                          <CheckIcon />
                          {phases[phase]}
                        </div>
                      )}
                    </article>
                  </>
                ) : (
                  <>
                    <div className="message-text">{scene.message}</div>
                    {renderSourceLink()}
                    {actionable && renderActions()}
                  </>
                )}
              </div>
            )}
            {!quiet && phase !== "new" && phase !== "replied" && (
              <div className="result enter">
                <div className="user-message">
                  {phase === "done"
                    ? scene.done
                    : phase === "snoozed"
                      ? scene.snooze
                      : scene.primary}
                </div>
                <div className="result-answer">
                  <span className="comma-avatar mini">
                    <CommaMascot />
                  </span>
                  <div>
                    {phase === "done" ? (
                      <p>
                        {sceneId === "bill"
                          ? "知道了，按你的确认记为已还款。这期账单不再提醒。"
                          : "收到，这件事不再提醒。"}
                      </p>
                    ) : phase === "snoozed" ? (
                      <p>
                        好，
                        {scene.snooze
                          .replace("再提醒", "再检查")
                          .replace("提醒", "检查")}
                        。到时先确认有没有新进展，已经处理就不再打扰。
                      </p>
                    ) : (
                      <>
                        <p>
                          {sceneId === "unhandled"
                            ? "三处改动整理好了，等你确认。"
                            : "草稿准备好了，还没有发送。"}
                        </p>
                        <button
                          className="draft-preview"
                          onClick={() => setDrawer("task")}
                        >
                          <FileTextIcon />
                          <span>
                            <strong>{scene.task}</strong>
                            <small>
                              {sceneId === "unhandled"
                                ? "整理结果 · 待你查看"
                                : "邮件草稿 · 待你查看"}
                            </small>
                          </span>
                          <ArrowRightIcon />
                        </button>
                      </>
                    )}
                  </div>
                </div>
              </div>
            )}
            {quiet && (
              <div className="quiet-space">
                <span className="quiet-line" />
              </div>
            )}
          </div>
        </ScrollArea>
        <form
          className="composer"
          onSubmit={(e) => {
            e.preventDefault();
            send();
          }}
        >
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            aria-label="回复 Comma"
            placeholder="回复 Comma，或告诉我下一步…"
            rows={2}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send();
              }
            }}
          />
          <div className="composer-bottom">
            <span className="composer-scope">
              <PaperclipIcon />
              当前工作空间
            </span>
            <button type="submit" aria-label="发送回复" disabled={!input.trim()}>
              <ArrowUpIcon />
            </button>
          </div>
        </form>
      </section>
    );
  }
  return (
    <div className="prototype-page">
      <header className="prototype-header">
        <div>
          <span className="study-dot" />
          <strong>主动提醒</strong>
          <span className="prototype-tag">交互稿</span>
        </div>
        <span className="fiction-label">虚构邮件与账单 · 操作仅在本页生效</span>
        <button className="reset" onClick={() => reset()}>
          <ReloadIcon />
          重置场景
        </button>
      </header>
      <nav className="scenario-tabs" aria-label="示例场景">
        {(Object.keys(scenes) as SceneId[]).map((id, i) => (
          <button key={id} aria-pressed={sceneId === id} onClick={() => reset(id)}>
            <span>0{i + 1}</span>
            {scenes[id].label}
          </button>
        ))}
      </nav>
      <div className="product-frame">
        <aside className="app-nav">
          <div className="brand">
            <CommaMascot />
            <span>comma</span>
          </div>
          <button
            className="workspace"
            onClick={() =>
              setNotice("当前为 Peng 的演示工作空间，示例邮件仅在此展示。")
            }
          >
            Peng’s workspace
            <ChevronDownIcon />
          </button>
          <nav>
            <button className="selected">
              <HomeIcon />
              Home
            </button>
            <button onClick={() => setDrawer("task")}>
              <ListChecksIcon />
              Tasks{taskExists && <span className="nav-count">1</span>}
            </button>
            <button
              onClick={() =>
                setNotice("Calendar 为背景导航，本稿的日期变化由场景控制。")
              }
            >
              <CalendarIcon />
              Calendar
            </button>
          </nav>
          <div className="nav-separator" />
          <div className="nav-caption">最近的对话</div>
          <button
            className="history-link"
            onClick={() =>
              setNotice("这是背景对话；当前演示提醒始终进入同一个 Home 聊天。")
            }
          >
            本周产品反馈
          </button>
          <button
            className="history-link"
            onClick={() => setNotice("这是背景对话，不会切换真实工作空间。")}
          >
            9 月发布准备
          </button>
          <div className="nav-bottom">
            <span className="profile">P</span>
            <span>
              Peng Xiao<small>个人工作空间</small>
            </span>
          </div>
        </aside>
        <main className={`home-surface variant-${variant}`}>
          <header className="home-header">
            <span>Comma assistant</span>
            <div className="home-meta">
              <span className="live-dot" />
              Home
              <button aria-label="查看来源邮件" onClick={() => setDrawer("source")}>
                <InboxIcon />
              </button>
            </div>
          </header>
          {variant === "A" && (
            <div className="home-columns">
              {renderRoutineRail()}
              {renderChat({})}
              {renderTaskRail()}
            </div>
          )}
          {variant === "B" && (
            <div className="inline-layout">
              {renderChat({ inline: true })}
              <div className="inline-task-aside">{renderTaskRail()}</div>
            </div>
          )}
          {variant === "C" && (
            <div className={`ambient-layout ${expanded ? "expanded" : ""}`}>
              <ScrollArea
                className="ambient-home"
                edgeEffect="none"
                scrollbarVisibility="hover"
              >
                <div className="ambient-heading">
                  <CommaMascot />
                  <span>{greeting}</span>
                </div>
                <p>
                  {settled
                    ? "这件事已处理，继续你手上的事吧。"
                    : "有一件事，留给你方便的时候看。"}
                </p>
                {!settled && (
                  <button
                    className="attention-banner"
                    onClick={() => setExpanded(true)}
                  >
                    <BellIcon />
                    <span>
                      <strong>{scene.title}</strong>
                      <small>
                        {scene.sender} · {timestamp}
                      </small>
                    </span>
                    <ArrowRightIcon />
                  </button>
                )}
                <div className="ambient-routine">
                  <div className="rail-label">
                    Routine<span>{settled ? 0 : 1}</span>
                  </div>
                  {renderRoutineCard({ compact: true })}
                </div>
                <div className="ambient-background">
                  <span className="section-caption">接下来</span>
                  <div>
                    <CalendarIcon />
                    <span>
                      产品例会<small>今天 16:30 · 30 分钟</small>
                    </span>
                  </div>
                </div>
              </ScrollArea>
              {expanded ? (
                <div className="peek-chat">
                  <div className="peek-title">
                    继续这件事
                    <button aria-label="收起聊天" onClick={() => setExpanded(false)}>
                      <XIcon />
                    </button>
                  </div>
                  {renderChat({})}
                </div>
              ) : (
                <button className="chat-dock" onClick={() => setExpanded(true)}>
                  <CommaMascot />
                  <span>和 Comma 聊聊</span>
                  <ArrowUpIcon />
                </button>
              )}
            </div>
          )}
        </main>
      </div>
      <footer className="scenario-state" aria-live="polite">
        <div>
          <span className={`state-dot ${settled ? "closed" : ""}`} />
          <strong>{quiet ? "保持安静" : phases[phase]}</strong>
          <span>
            {notice ||
              (phase === "replied"
                ? "检测到 Alex 回复，停止本次催办；原 Task 待你验收，聊天没有新增消息。"
                : phase === "done"
                  ? "聊天与卡片已同步，后续提醒已停止。"
                  : scene.note)}
          </span>
        </div>
        <div>
          {sceneId === "waiting" && !settled && (
            <button
              onClick={() => {
                setPhase("replied");
                setNotice("");
              }}
            >
              模拟收到回复
              <ArrowRightIcon />
            </button>
          )}
          {phase === "snoozed" && (
            <button
              onClick={() => {
                setAdvanced(true);
                setPhase("new");
                setNotice(
                  "约定时间到，重新检查后仍需行动，再次提醒。实际调度未接入此稿。"
                );
              }}
            >
              推进到提醒时间
              <ArrowRightIcon />
            </button>
          )}
          {quiet && (
            <button onClick={() => setDrawer("source")}>
              看看这封新邮件
              <ArrowRightIcon />
            </button>
          )}
        </div>
      </footer>
      {(import.meta.env.DEV || import.meta.env.MODE === "prototype") && (
        <div className="variant-switcher" aria-label="提醒形态">
          <button aria-label="上一种形态" onClick={() => switchVariant(-1)}>
            <ArrowLeftIcon />
          </button>
          {(["A", "B", "C"] as Variant[]).map((v) => (
            <button key={v} aria-pressed={variant === v} onClick={() => setVariant(v)}>
              <b>{v}</b>
              {variantNames[v]}
              {v === "A" && <small>推荐</small>}
            </button>
          ))}
          <button aria-label="下一种形态" onClick={() => switchVariant(1)}>
            <ArrowRightIcon />
          </button>
        </div>
      )}
      {drawer && (
        <div className="drawer-backdrop">
          <button
            className="drawer-dismiss"
            aria-label="关闭详情背景"
            onClick={() => setDrawer(null)}
          />
          <dialog
            open
            className="source-drawer enter"
            aria-modal="true"
            aria-label={drawer === "source" ? "来源邮件" : "任务详情"}
          >
            <header>
              <span>{drawer === "source" ? "来源邮件" : "任务详情"}</span>
              <button aria-label="关闭详情" autoFocus onClick={() => setDrawer(null)}>
                <XIcon />
              </button>
            </header>
            <ScrollArea className="drawer-scroll" edgeEffect="none">
              <div className="drawer-content">
                <div className="drawer-eyebrow">
                  {drawer === "source" ? "GMAIL" : "COMMA TASK"}
                </div>
                <h2>
                  {drawer === "source"
                    ? scene.source
                    : taskExists
                      ? scene.task
                      : "还没有创建任务"}
                </h2>
                {drawer === "source" ? (
                  <>
                    <p className="source-meta">
                      {phase === "replied" ? "Alex → Peng" : scene.sender}
                      <br />
                      {phase === "replied" ? "今天 11:04" : scene.sourceDate}
                    </p>
                    <div className="mail-body">
                      {phase === "replied"
                        ? "Peng 你好，\n\n报价已经确认，可以按此推进。谢谢你的跟进。\n\nAlex"
                        : scene.body}
                    </div>
                    <div className="source-foot">
                      <span className="mail-mark">M</span>虚构邮件 · 没有读取真实邮箱
                    </div>
                  </>
                ) : taskExists ? (
                  <>
                    <div className="task-detail-state">
                      {phase === "draft" || phase === "replied"
                        ? "待你验收"
                        : phase === "done"
                          ? "已完成"
                          : "进行中"}
                    </div>
                    <p className="source-meta">
                      {sceneId === "waiting"
                        ? "沿用周五创建的跟进任务"
                        : "由你刚才的操作创建"}
                    </p>
                    <div className="mail-body">
                      {phase === "draft"
                        ? scene.draft
                        : phase === "replied"
                          ? "Alex 已回复并确认报价。本次催办已经停止，等待你确认结果。"
                          : phase === "done"
                            ? "你已确认这件事处理完毕。"
                            : "下一次检查同一个邮件线程。收到回复或你确认已处理后，停止催办。"}
                    </div>
                    {renderSourceLink()}
                    {phase === "replied" && (
                      <button
                        className="action primary drawer-primary"
                        onClick={() => {
                          setPhase("done");
                          setDrawer(null);
                        }}
                      >
                        确认结果，完成任务
                        <CheckIcon />
                      </button>
                    )}
                    {phase === "draft" && (
                      <p className="draft-notice">此稿只预览草稿。没有发送邮件。</p>
                    )}
                  </>
                ) : (
                  <p>
                    收到提醒不自动创建任务。选择“帮我起草”等操作后，再由 Comma
                    承接工作。
                  </p>
                )}
              </div>
            </ScrollArea>
          </dialog>
        </div>
      )}
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<App />);
