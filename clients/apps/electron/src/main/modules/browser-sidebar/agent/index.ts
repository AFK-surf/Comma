import { z } from "zod";
import { clockSleep, type MainClock } from "../../../clock";
import pageScript from "./page.js?raw";

/**
 * The agent's commands on an in-app browser tab, over the CDP session of one
 * client-control call. They follow the cloud browser's contract
 * (SalixAgent.Browser.Commands): every action returns a receipt with the
 * tab's URL, title and a viewport snapshot after the action; element refs
 * (`e12`) come from snapshots and stay valid until the document navigates;
 * `actions` runs up to ten steps in one call. Page scripts run in the
 * "comma-agent" isolated world, which outlives the debugger attachment, so a
 * ref from one call still names its element in the next.
 */

const WORLD_NAME = "comma-agent";
const RECEIPT_CHARS = 6_000;
const SNAPSHOT_CHARS = 12_000;
const MAX_SNAPSHOT_CHARS = 40_000;
const SETTLE_MS = 5_000;
const NAVIGATE_MS = 15_000;
const POLL_MS = 100;
// The station gives a client-control call 30 seconds: a batch and the
// receipt after it (its settle and snapshot) end before that.
export const BROWSER_AGENT_BATCH_MS = 20_000;
/** The longest one command can take: a batch, then its receipt. */
export const BROWSER_AGENT_COMMAND_TIMEOUT_MS = 28_000;
const MAX_STEPS = 10;

// Failures before any input reached the page. A batch reports them as its
// failed step; every other failure is an unknown outcome and fails the batch.
const LOCAL_FAILURES = new Set([
  "target_not_found",
  "ambiguous_target",
  "stale_element",
  "invalid_input",
  "invalid_url",
  "wait_timeout",
  "dialog_open",
  "batch_timeout",
]);

const targetFields = {
  ref: z.string().trim().min(1).max(32).optional(),
  target: z.string().trim().min(1).max(1_024).optional(),
};
const bounded = (max: number) => z.string().max(max);

const navigateStep = z
  .object({ op: z.literal("navigate"), url: bounded(4_096) })
  .strict();
const clickStep = z
  .object({
    op: z.literal("click"),
    ...targetFields,
    x: z.number().min(0).max(10_000).optional(),
    y: z.number().min(0).max(10_000).optional(),
  })
  .strict();
const fillStep = z
  .object({ op: z.literal("fill"), ...targetFields, text: bounded(4_096) })
  .strict();
const pressStep = z
  .object({ op: z.literal("press"), ...targetFields, key: bounded(128) })
  .strict();
const scrollStep = z
  .object({
    op: z.literal("scroll"),
    ...targetFields,
    x: z.number().min(-4_000).max(4_000).optional(),
    y: z.number().min(-4_000).max(4_000).optional(),
  })
  .strict();
const selectStep = z
  .object({ op: z.literal("select"), ...targetFields, value: bounded(1_024) })
  .strict();
const waitStep = z
  .object({
    op: z.literal("wait"),
    selector: bounded(1_024).optional(),
    text: bounded(256).optional(),
    timeoutMs: z.number().int().min(1).max(10_000).optional(),
    urlContains: bounded(4_096).optional(),
  })
  .strict();

const browserAgentStepSchema = z.discriminatedUnion("op", [
  navigateStep,
  clickStep,
  fillStep,
  pressStep,
  scrollStep,
  selectStep,
  waitStep,
]);
export type BrowserAgentStep = z.output<typeof browserAgentStepSchema>;

const tabId = z.string().trim().min(1).max(256);

/** Input schemas of the commands, by client-control API id. */
export const browserAgentInputSchemas = {
  snapshot: z
    .object({
      tabId,
      interactiveOnly: z.boolean().optional(),
      maxChars: z.number().int().min(500).max(MAX_SNAPSHOT_CHARS).optional(),
      ref: targetFields.ref,
      scope: z.enum(["viewport", "full", "subtree"]).optional(),
    })
    .strict(),
  navigate: navigateStep.omit({ op: true }).extend({ tabId }).strict(),
  click: clickStep.omit({ op: true }).extend({ tabId }).strict(),
  fill: fillStep.omit({ op: true }).extend({ tabId }).strict(),
  press: pressStep.omit({ op: true }).extend({ tabId }).strict(),
  scroll: scrollStep.omit({ op: true }).extend({ tabId }).strict(),
  select: selectStep.omit({ op: true }).extend({ tabId }).strict(),
  wait: waitStep.omit({ op: true }).extend({ tabId }).strict(),
  actions: z
    .object({ tabId, steps: z.array(browserAgentStepSchema).min(1).max(MAX_STEPS) })
    .strict(),
  dialog: z
    .object({
      tabId,
      action: z.enum(["accept", "dismiss"]),
      promptText: bounded(4_096).optional(),
    })
    .strict(),
} as const;

export type BrowserAgentOperation = keyof typeof browserAgentInputSchemas;
export type BrowserAgentInput = {
  [Op in BrowserAgentOperation]: z.output<(typeof browserAgentInputSchemas)[Op]>;
};

/** The CDP session of one call, attached to the tab's WebContents. */
export interface BrowserAgentCdp {
  send(method: string, params?: Record<string, unknown>): Promise<unknown>;
  /** Subscribes to protocol events; the returned function unsubscribes. */
  onEvent(
    listener: (method: string, params: Record<string, unknown>) => void
  ): () => void;
}

/** What Main keeps per tab between calls: the document its refs belong to. */
export interface BrowserAgentRefs {
  document: string;
  next: number;
}

export interface BrowserAgentTab {
  readonly cdp: BrowserAgentCdp;
  readonly clock: MainClock;
  readonly platform: NodeJS.Platform;
  readonly tabId: string;
  /**
   * Navigates the way the tab's address bar does; settles when the load
   * does, with the error that stopped it (a DNS or connection failure).
   */
  navigate(url: string): Promise<string | undefined>;
  title(): string;
  url(): string;
  refs: BrowserAgentRefs | undefined;
}

interface Dialog {
  defaultPrompt?: string | undefined;
  message: string;
  type: string;
}

type Target =
  | { ref: string }
  | { selector: string }
  | { exact: boolean; text: string }
  | { name?: string | undefined; role: string };

export class BrowserAgentError extends Error {
  constructor(
    readonly reason: string,
    readonly details: Record<string, unknown> = {}
  ) {
    super(reason);
  }
}

const fail = (reason: string, details?: Record<string, unknown>): never => {
  throw new BrowserAgentError(reason, details);
};

/**
 * The agent's control of one tab while the debugger is attached to it.
 * Main attaches for one call and detaches after it, except while a dialog
 * the page opened is waiting: only the session that saw it open can answer
 * it, so Main keeps the session (`holding`) until the dialog closes.
 */
export class BrowserAgentSession {
  readonly #tab: BrowserAgentTab;
  #started = false;
  #unsubscribe: (() => void) | undefined;
  #dialog: Dialog | undefined;
  /** The last dialog that closed: something other than the agent may answer one. */
  #closedDialog: Dialog | undefined;
  #dialogWaiters = new Set<() => void>();
  #mainFrame: string | undefined;
  #document: string | undefined;
  /** The URL the current document's error page stands for, if it is one. */
  #unreachable: string | undefined;
  #loads = 0;
  #phase: "idle" | "navigating" | "committed" = "idle";
  /** When the running command must have ended: no command outlives Main's timeout. */
  #commandDeadline = Infinity;
  #stopped = false;
  #focusEmulated = false;

  constructor(tab: BrowserAgentTab) {
    this.#tab = tab;
  }

  /** True while a JavaScript dialog of the page waits for an answer. */
  get holding() {
    return !this.#stopped && this.#dialog !== undefined;
  }

  /**
   * Runs one command and returns its result: a receipt for an action, the
   * snapshot for `snapshot`. A failure returns `{ error }` with its reason
   * instead of throwing, so the CLI shows it to the agent.
   */
  async command<Op extends BrowserAgentOperation>(
    op: Op,
    input: BrowserAgentInput[Op]
  ): Promise<Record<string, unknown>> {
    // A second before Main gives up on the call, the command stops sending.
    this.#commandDeadline =
      this.#tab.clock.now() + BROWSER_AGENT_COMMAND_TIMEOUT_MS - 1_000;
    try {
      if (!this.#started) await this.#start();
      return await this.#run(op, input);
    } catch (error) {
      if (error instanceof BrowserAgentError) {
        return { tabId: this.#tab.tabId, error: error.reason, ...error.details };
      }
      throw error;
    }
  }

  async #start() {
    this.#started = true;
    this.#unsubscribe = this.#tab.cdp.onEvent((method, params) =>
      this.#event(method, params)
    );
    // Enabling the domain reports a dialog that is already open.
    await this.#send("Page.enable", {}, { raceDialog: false });
    if (!this.#dialog) await this.#readFrame();
  }

  /** Ends the session: its event subscription, and any command still running sends nothing more. */
  stop() {
    this.#stopped = true;
    this.#unsubscribe?.();
  }

  async #run<Op extends BrowserAgentOperation>(op: Op, input: BrowserAgentInput[Op]) {
    if (op === "snapshot") {
      return this.#observe(input as BrowserAgentInput["snapshot"]);
    }
    const mark = this.#loads;
    if (op === "dialog") {
      const { action, promptText } = input as BrowserAgentInput["dialog"];
      const dialog =
        this.#dialog ??
        fail(
          "invalid_input",
          this.#closedDialog
            ? {
                closedDialog: this.#closedDialog,
                message: "No dialog is open: this one closed before the call.",
              }
            : { message: "No dialog is open." }
        );
      const params: Record<string, unknown> = { accept: action === "accept" };
      if (action === "accept" && dialog.type === "prompt" && promptText !== undefined) {
        params.promptText = promptText;
      }
      await this.#send("Page.handleJavaScriptDialog", params, { raceDialog: false });
      this.#dialog = undefined;
      return this.#receipt(mark, { handledDialog: dialog });
    }
    if (op === "actions") {
      return this.#batch(mark, (input as BrowserAgentInput["actions"]).steps);
    }
    const { tabId: _tabId, ...step } = input as BrowserAgentInput["click"];
    const deadline = this.#tab.clock.now() + BROWSER_AGENT_BATCH_MS;
    await this.#act({ op, ...step } as BrowserAgentStep, deadline);
    return this.#receipt(mark, {});
  }

  async #batch(mark: number, steps: BrowserAgentStep[]) {
    const deadline = this.#tab.clock.now() + BROWSER_AGENT_BATCH_MS;
    let completed = 0;
    let failedStep: Record<string, unknown> | undefined;
    for (const [index, step] of steps.entries()) {
      try {
        // A step starts only within the batch's budget.
        if (this.#tab.clock.now() >= deadline) fail("batch_timeout");
        await this.#act(step, deadline);
        completed = index + 1;
      } catch (error) {
        if (
          !(error instanceof BrowserAgentError) ||
          !LOCAL_FAILURES.has(error.reason)
        ) {
          throw error;
        }
        failedStep = { ...error.details, index, op: step.op, error: error.reason };
        break;
      }
    }
    return this.#receipt(mark, {
      stepsCompleted: completed,
      ...(failedStep ? { failedStep } : {}),
    });
  }

  async #act(step: BrowserAgentStep, deadline: number) {
    const loads = this.#loads;
    switch (step.op) {
      case "navigate":
        return this.#navigate(step.url, deadline);
      case "click": {
        const target = targetOf(step);
        if (!target) {
          if (step.x === undefined || step.y === undefined)
            return fail("invalid_input");
          this.#noDialog();
          return this.#click(step.x, step.y);
        }
        const ref = await this.#resolve(target);
        const point = await this.#waitUntil(this.#remaining(deadline), async () => {
          const result = (await this.#elementCall(ref, "clickPoint")) as {
            error?: string;
            x: number;
            y: number;
          };
          if (result.error === "browser_operation_failed") return undefined;
          if (result.error) return fail(result.error);
          return result;
        });
        this.#noDialog();
        await this.#elementCall(ref, "armClick");
        await this.#click(point.x, point.y);
        // A window that is not on screen drops mouse input. The element then
        // gets the click from the page instead.
        if (!this.#dialog && this.#loads === loads) {
          // The click may have removed the element: it was not missed then.
          await this.#elementCall(ref, "clickIfMissed").catch((error: unknown) => {
            if (!(error instanceof BrowserAgentError)) throw error;
          });
        }
        return;
      }
      case "fill": {
        const ref = await this.#resolve(targetOf(step) ?? fail("invalid_input"));
        this.#noDialog();
        const reason =
          (await this.#elementCall(ref, "numberFill", [step.text])) ??
          (await this.#elementCall(ref, "prepareFill"));
        if (reason) fail(reason as string);
        if (step.text === "") await this.#press("Backspace");
        else await this.#send("Input.insertText", { text: step.text });
        return;
      }
      case "press": {
        const chord = parseChord(step.key, this.#tab.platform);
        const target = targetOf(step);
        if (target) {
          const ref = await this.#resolve(target);
          await this.#elementCall(ref, "focus");
        }
        this.#noDialog();
        return this.#pressChord(chord);
      }
      case "scroll": {
        const target = targetOf(step);
        if (target) {
          const ref = await this.#resolve(target);
          const reason = await this.#elementCall(ref, "scrollTo");
          if (reason) fail(reason as string);
          return;
        }
        if (step.y === undefined) return fail("invalid_input");
        this.#noDialog();
        await this.#evaluate(`__commaAgent.scrollBy(${step.x ?? 0}, ${step.y})`);
        return;
      }
      case "select": {
        const ref = await this.#resolve(targetOf(step) ?? fail("invalid_input"));
        this.#noDialog();
        // A dialog opened by the change handler means the option was selected.
        try {
          const reason = await this.#elementCall(ref, "selectOption", [step.value]);
          if (reason) fail(reason as string);
        } catch (error) {
          if (!(error instanceof BrowserAgentError && error.reason === "dialog_open")) {
            throw error;
          }
        }
        return;
      }
      case "wait":
        return this.#wait(step, deadline);
    }
  }

  async #navigate(url: string, deadline: number) {
    let parsed: URL;
    try {
      parsed = new URL(url);
    } catch {
      return fail("invalid_url");
    }
    if (
      (parsed.protocol !== "http:" && parsed.protocol !== "https:") ||
      parsed.username ||
      parsed.password
    ) {
      return fail("invalid_url");
    }
    this.#noDialog();
    const document = this.#document;
    let settled = false;
    let loadError: string | undefined;
    void this.#tab.navigate(parsed.toString()).then((error) => {
      settled = true;
      loadError = error;
    });
    // The new document is ready once it is parsed, or once the navigation
    // settled (a same-document or failed one makes no new document). A
    // dialog (beforeunload, or one the new document opens) holds the
    // navigation: the receipt reports it.
    await this.#waitUntil(
      Math.min(NAVIGATE_MS, this.#remaining(deadline)),
      async () => {
        if (this.#dialog || settled) return true;
        if (this.#document === document || this.#phase === "navigating")
          return undefined;
        return (await this.#evaluate("document.readyState !== 'loading'")) === true
          ? true
          : undefined;
      }
    );
    if (loadError !== undefined)
      fail("browser_operation_failed", { message: loadError });
    // Chromium commits its error page before the load reports the error.
    if (this.#unreachable !== undefined && this.#document !== document) {
      fail("browser_operation_failed", {
        message: `${this.#unreachable} could not be loaded.`,
      });
    }
  }

  async #wait(step: Extract<BrowserAgentStep, { op: "wait" }>, deadline: number) {
    const timeout = Math.min(step.timeoutMs ?? 5_000, this.#remaining(deadline));
    const condition =
      step.text !== undefined
        ? { text: step.text }
        : step.selector !== undefined
          ? { selector: step.selector }
          : undefined;
    if (!condition && step.urlContains === undefined) fail("invalid_input");
    const until = this.#tab.clock.now() + timeout;
    for (;;) {
      this.#noDialog();
      const urlHolds =
        step.urlContains === undefined || this.#tab.url().includes(step.urlContains);
      if (urlHolds && this.#phase !== "navigating") {
        if (!condition) return;
        const result = await this.#evaluate(
          `__commaAgent.check(${JSON.stringify(condition)})`
        );
        if (result === true) return;
        if (isRecord(result) && typeof result.error === "string") fail(result.error);
      }
      if (this.#tab.clock.now() >= until) fail("wait_timeout");
      await clockSleep(this.#tab.clock, POLL_MS);
    }
  }

  // Resolves a target to a ref of the current document. Refs need the
  // snapshot that issued them to belong to the current document.
  async #resolve(target: Target) {
    this.#noDialog();
    const entry = this.#tab.refs;
    if ("ref" in target && entry?.document !== this.#document) fail("stale_element");
    const result = await this.#evaluate(
      `__commaAgent.resolve(${JSON.stringify(target)}, ${JSON.stringify(this.#refOptions())})`
    );
    if (!isRecord(result)) return fail("browser_operation_failed");
    if (typeof result.next === "number") this.#keepRefs(result.next);
    if (typeof result.error === "string") {
      // The candidates carry refs the agent may use next.
      return fail(
        result.error,
        result.candidates ? { candidates: result.candidates, count: result.count } : {}
      );
    }
    return typeof result.ref === "string"
      ? result.ref
      : fail("browser_operation_failed");
  }

  #refOptions() {
    const entry = this.#tab.refs;
    if (!entry) return { next: 1, reset: true };
    return { next: entry.next, reset: entry.document !== this.#document };
  }

  // An ended session writes nothing back: a newer one may own the refs.
  #keepRefs(next: number) {
    if (this.#document && !this.#stopped) {
      this.#tab.refs = { document: this.#document, next };
    }
  }

  // The receipt of an action: tab, URL, title and a viewport snapshot. A
  // failed observation never fails the action that already happened.
  async #receipt(mark: number, extra: Record<string, unknown>) {
    await this.#settle(mark);
    let value: Record<string, unknown>;
    if (this.#dialog) {
      value = { tabId: this.#tab.tabId, dialog: this.#dialog };
    } else if (this.#phase === "navigating") {
      // The old document answers no page command until the new one commits.
      value = { tabId: this.#tab.tabId, loading: true };
    } else {
      try {
        value = await this.#observe({
          tabId: this.#tab.tabId,
          maxChars: RECEIPT_CHARS,
          scope: "viewport",
        });
      } catch (error) {
        if (!(error instanceof BrowserAgentError)) throw error;
        value = { tabId: this.#tab.tabId, snapshotError: error.reason };
      }
    }
    return {
      url: this.#tab.url(),
      title: this.#tab.title(),
      ...value,
      ...extra,
    };
  }

  // An action that started a navigation waits for the new document before
  // observing it: until the load ends or the new document is parsed. A page
  // command would block while a JavaScript dialog is open.
  async #settle(mark: number) {
    try {
      await this.#waitUntil(SETTLE_MS, async () => {
        if (this.#dialog || this.#loads === mark || this.#phase === "idle") return true;
        if (this.#phase === "navigating") return undefined;
        return (await this.#evaluate("document.readyState !== 'loading'")) === true
          ? true
          : undefined;
      });
    } catch (error) {
      if (!(error instanceof BrowserAgentError)) throw error;
    }
  }

  async #observe(input: BrowserAgentInput["snapshot"]) {
    this.#noDialog();
    const scope = input.scope ?? "viewport";
    const options: Record<string, unknown> = {
      ...this.#refOptions(),
      interactiveOnly: input.interactiveOnly === true,
      maxChars: input.maxChars ?? SNAPSHOT_CHARS,
      scope,
    };
    if (scope === "subtree") {
      if (this.#tab.refs?.document !== this.#document) fail("stale_element");
      options.root = refName(input.ref ?? fail("invalid_input"));
    }
    const result = await this.#evaluate(
      `__commaAgent.snapshot(${JSON.stringify(options)})`
    );
    if (!isRecord(result)) return fail("browser_operation_failed");
    if (typeof result.error === "string") return fail(result.error);
    if (typeof result.next === "number") this.#keepRefs(result.next);
    const value: Record<string, unknown> = {
      tabId: this.#tab.tabId,
      url: result.url,
      title: result.title,
      scope,
      snapshot: result.text,
      truncated: result.truncated === true,
    };
    if (
      scope === "viewport" &&
      typeof result.pageHeight === "number" &&
      typeof result.viewportHeight === "number" &&
      result.pageHeight > result.viewportHeight
    ) {
      value.scroll = {
        y: result.scrollY,
        viewportHeight: result.viewportHeight,
        pageHeight: result.pageHeight,
      };
    }
    return value;
  }

  #event(method: string, params: Record<string, unknown>) {
    switch (method) {
      case "Page.javascriptDialogOpening":
        this.#dialog = {
          message: String(params.message ?? "").slice(0, 2_000),
          type: String(params.type ?? "alert"),
          ...(typeof params.defaultPrompt === "string" && params.type === "prompt"
            ? { defaultPrompt: params.defaultPrompt.slice(0, 2_000) }
            : {}),
        };
        for (const wake of this.#dialogWaiters) wake();
        return;
      case "Page.javascriptDialogClosed":
        this.#closedDialog = this.#dialog ?? this.#closedDialog;
        this.#dialog = undefined;
        return;
      case "Page.frameStartedLoading":
        if (params.frameId === this.#mainFrame) {
          this.#loads += 1;
          this.#phase = "navigating";
        }
        return;
      case "Page.frameNavigated": {
        const frame = params.frame;
        if (isRecord(frame) && frame.parentId === undefined) {
          this.#mainFrame = String(frame.id);
          this.#document = String(frame.loaderId);
          this.#unreachable =
            typeof frame.unreachableUrl === "string" ? frame.unreachableUrl : undefined;
          if (this.#phase === "navigating") this.#phase = "committed";
        }
        return;
      }
      case "Page.frameStoppedLoading":
        if (params.frameId === this.#mainFrame) this.#phase = "idle";
        return;
    }
  }

  async #readFrame() {
    const tree = (await this.#send("Page.getFrameTree")) as {
      frameTree?: { frame?: { id?: string; loaderId?: string } };
    };
    const frame = tree.frameTree?.frame;
    if (!frame?.id || !frame.loaderId) return fail("browser_operation_failed");
    this.#mainFrame = frame.id;
    this.#document = frame.loaderId;
  }

  #noDialog() {
    if (this.#dialog) fail("dialog_open", { dialog: this.#dialog });
  }

  // Evaluates an expression after the page helpers in the agent's world. A
  // document that commits between creating the world and evaluating in it
  // destroys the world: the next attempt evaluates in the new document's.
  async #evaluate(expression: string): Promise<unknown> {
    for (let attempt = 1; ; attempt += 1) {
      try {
        return await this.#evaluateOnce(expression);
      } catch (error) {
        const lostContext =
          error instanceof BrowserAgentError &&
          typeof error.details.message === "string" &&
          /context/i.test(error.details.message);
        if (!lostContext || attempt === 3) throw error;
      }
    }
  }

  async #evaluateOnce(expression: string) {
    if (!this.#mainFrame) await this.#readFrame();
    const world = (await this.#send("Page.createIsolatedWorld", {
      frameId: this.#mainFrame,
      worldName: WORLD_NAME,
    })) as { executionContextId?: number };
    const result = (await this.#send("Runtime.evaluate", {
      awaitPromise: true,
      contextId: world.executionContextId,
      expression: `${pageScript}\n${expression}`,
      returnByValue: true,
    })) as { exceptionDetails?: unknown; result?: { value?: unknown } };
    if (result.exceptionDetails) return fail("browser_operation_failed");
    return result.result?.value;
  }

  // Calls a page helper, or one of ELEMENT_CALLS, on the element a ref names.
  async #elementCall(ref: string, method: string, args: unknown[] = []) {
    const call =
      ELEMENT_CALLS[method] ??
      `__commaAgent.${method}(el${args.map((arg) => `, ${JSON.stringify(arg)}`).join("")})`;
    const result = await this.#evaluate(
      `(async () => { const el = __commaAgent.element(${JSON.stringify(ref)}); if (!el) return { stale: true }; return { value: await ${call} }; })()`
    );
    if (!isRecord(result) || result.stale) return fail("stale_element");
    return result.value;
  }

  async #click(x: number, y: number) {
    // Chromium drops a press that no move brought the pointer to. A dialog
    // the press opened holds the page: the release cannot reach it.
    for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
      if (this.#dialog) return;
      await this.#send("Input.dispatchMouseEvent", {
        button: "left",
        clickCount: 1,
        type,
        x,
        y,
      });
    }
  }

  async #press(key: string) {
    return this.#pressChord(parseChord(key, this.#tab.platform));
  }

  async #pressChord(chord: Chord) {
    const { key, mask, modifiers } = chord;
    // A dialog that a key opened holds the page: the remaining key events
    // cannot reach it, and the key counts as pressed.
    for (const modifier of modifiers) {
      await this.#keyEvent("rawKeyDown", modifier, mask);
    }
    const printable = key.key.length === 1 && (mask & 7) === 0;
    const value = key.key === "Enter" ? "\r" : key.key;
    await this.#keyEvent(
      "keyDown",
      key,
      mask,
      printable || key.key === "Enter" ? value : undefined
    );
    await this.#keyEvent("keyUp", key, mask);
    for (const modifier of modifiers.toReversed()) {
      await this.#keyEvent("keyUp", modifier, 0);
    }
  }

  async #keyEvent(type: string, key: Key, modifiers: number, text?: string) {
    if (this.#dialog) return;
    await this.#send("Input.dispatchKeyEvent", {
      code: key.code,
      key: key.key,
      modifiers,
      type,
      windowsVirtualKeyCode: key.keyCode,
      ...(text === undefined ? {} : { text }),
    });
  }

  // A dialog holds the page: a command fails with dialog_open, except input
  // that opened the dialog, which reached the page. Only Page.enable and
  // Page.handleJavaScriptDialog are answered while a dialog is open.
  async #send(
    method: string,
    params: Record<string, unknown> = {},
    { raceDialog = true }: { raceDialog?: boolean } = {}
  ) {
    if (this.#stopped) {
      return fail("browser_operation_failed", { message: "The session ended." });
    }
    if (this.#tab.clock.now() >= this.#commandDeadline) {
      return fail("browser_operation_failed", {
        message: "The command ran out of time.",
      });
    }
    // The page answers nothing while a dialog is open.
    if (raceDialog && this.#dialog)
      return fail("dialog_open", { dialog: this.#dialog });
    // A tab in a window that is not on screen takes input only while it
    // counts as focused. The emulation ends when the debugger detaches.
    if (method.startsWith("Input.") && !this.#focusEmulated) {
      await this.#send("Emulation.setFocusEmulationEnabled", { enabled: true });
      this.#focusEmulated = true;
    }
    let wake: (() => void) | undefined;
    const dialogOpened = new Promise<typeof DIALOG_OPENED>((resolve) => {
      wake = () => resolve(DIALOG_OPENED);
      if (raceDialog) this.#dialogWaiters.add(wake);
    });
    const command = this.#tab.cdp.send(method, params);
    try {
      const result = await Promise.race([command, dialogOpened]);
      if (result !== DIALOG_OPENED) return result;
      command.catch(() => undefined);
      if (method.startsWith("Input.")) return {};
      return fail("dialog_open", { dialog: this.#dialog });
    } catch (error) {
      if (error instanceof BrowserAgentError) throw error;
      return fail("browser_operation_failed", {
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      if (wake) this.#dialogWaiters.delete(wake);
    }
  }

  #remaining(deadline: number) {
    return Math.max(1, deadline - this.#tab.clock.now());
  }

  // Polls until `check` returns a value or the timeout passes.
  async #waitUntil<T>(
    timeout: number,
    check: () => Promise<T | undefined>
  ): Promise<T> {
    const until = this.#tab.clock.now() + timeout;
    for (;;) {
      const value = await check();
      if (value !== undefined) return value;
      if (this.#tab.clock.now() >= until) return fail("browser_operation_failed");
      await clockSleep(this.#tab.clock, POLL_MS);
    }
  }
}

const DIALOG_OPENED = Symbol("dialog opened");

// Element calls that are not page.js helpers, so page.js stays the cloud
// browser's copy. `armClick` notes whether the next press reaches the
// element's window; `clickIfMissed` clicks from the page when it did not.
// Pointer events always fire, while a page that cancels pointerdown gets no
// mousedown, so pointerdown (or the click itself) counts as reached.
const ELEMENT_CALLS: Record<string, string> = {
  focus: "(el.focus(), null)",
  armClick:
    "(() => { const win = el.ownerDocument.defaultView; const token = (__commaAgent.clickToken || 0) + 1; " +
    "__commaAgent.clickToken = token; __commaAgent.pressed = false; " +
    "const reached = () => { if (__commaAgent.clickToken === token) __commaAgent.pressed = true; }; " +
    "for (const type of ['pointerdown', 'mousedown', 'click']) win.addEventListener(type, reached, { capture: true, once: true }); " +
    "return null; })()",
  clickIfMissed:
    "(() => { if (__commaAgent.pressed) return false; el.focus(); el.click(); return true; })()",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

// Targets: `ref` or `target` ("e12", "text=Save", "role=button[name=\"Save\"]",
// "css=.item", or a CSS selector).
function targetOf(step: { ref?: string | undefined; target?: string | undefined }) {
  if (step.ref !== undefined) return { ref: refName(step.ref) };
  if (step.target !== undefined) return parseTarget(step.target);
  return undefined;
}

function refName(ref: string) {
  const name = ref.trim().replace(/^@/, "").replace(/^\[/, "").replace(/\]$/, "");
  return /^e\d{1,9}$/.test(name) ? name : fail("stale_element");
}

export function parseTarget(raw: string): Target {
  const target = raw.trim();
  if (!target) return fail("invalid_input");
  if (/^@?\[?e\d{1,9}\]?$/.test(target)) return { ref: refName(target) };
  if (target.startsWith("text=")) {
    const value = target.slice("text=".length).trim();
    const quoted = /^"(.*)"$|^'(.*)'$/s.exec(value);
    return quoted
      ? { exact: true, text: quoted[1] ?? quoted[2] ?? "" }
      : { exact: false, text: value };
  }
  if (target.startsWith("role=")) {
    const match = /^role=([\w-]+)(?:\[name=(?:"([^"]*)"|'([^']*)'|([^\]]*))\])?$/.exec(
      target
    );
    if (!match) return fail("invalid_input");
    const name = match[2] ?? match[3] ?? match[4]?.trim();
    return name === undefined ? { role: match[1]! } : { name, role: match[1]! };
  }
  if (target.startsWith("css=")) return { selector: target.slice("css=".length) };
  return { selector: target };
}

interface Key {
  code: string;
  key: string;
  keyCode: number;
}

interface Chord {
  key: Key;
  mask: number;
  modifiers: Key[];
}

const NAMED_KEYS: Record<string, [code: string, keyCode: number]> = {
  Enter: ["Enter", 13],
  Tab: ["Tab", 9],
  Backspace: ["Backspace", 8],
  Delete: ["Delete", 46],
  Escape: ["Escape", 27],
  ArrowLeft: ["ArrowLeft", 37],
  ArrowUp: ["ArrowUp", 38],
  ArrowRight: ["ArrowRight", 39],
  ArrowDown: ["ArrowDown", 40],
  Home: ["Home", 36],
  End: ["End", 35],
  PageUp: ["PageUp", 33],
  PageDown: ["PageDown", 34],
  Shift: ["ShiftLeft", 16],
  Control: ["ControlLeft", 17],
  Alt: ["AltLeft", 18],
  Meta: ["MetaLeft", 91],
};
const MODIFIER_BITS: Record<string, number> = { Alt: 1, Control: 2, Meta: 4, Shift: 8 };

/** A key or chord such as "Enter", "a", "Shift+Tab" or "ControlOrMeta+a". */
export function parseChord(chord: string, platform: NodeJS.Platform): Chord {
  const parts = chord === "+" ? ["+"] : chord.split("+");
  const name = parts.pop()!;
  const modifierNames = parts.map((part) =>
    part === "ControlOrMeta" ? (platform === "darwin" ? "Meta" : "Control") : part
  );
  let mask = 0;
  for (const modifier of modifierNames) {
    mask |= MODIFIER_BITS[modifier] ?? fail("invalid_input");
  }
  const key = keyOf(name);
  if (mask & 8 && key.key.length === 1) key.key = key.key.toUpperCase();
  return { key, mask, modifiers: modifierNames.map(keyOf) };
}

function keyOf(name: string): Key {
  if (name === "Space") return { code: "Space", key: " ", keyCode: 32 };
  const named = NAMED_KEYS[name];
  if (named) return { code: named[0], key: name, keyCode: named[1] };
  if (/^[a-zA-Z]$/.test(name)) {
    return {
      code: `Key${name.toUpperCase()}`,
      key: name,
      keyCode: name.toUpperCase().charCodeAt(0),
    };
  }
  if (/^Key[A-Z]$/.test(name)) {
    return {
      code: name,
      key: name.slice(3).toLowerCase(),
      keyCode: name.charCodeAt(3),
    };
  }
  if (/^[0-9]$/.test(name))
    return { code: `Digit${name}`, key: name, keyCode: name.charCodeAt(0) };
  const fn = /^F([1-9]|1[0-2])$/.exec(name);
  if (fn) return { code: name, key: name, keyCode: 111 + Number(fn[1]) };
  if ([...name].length === 1) return { code: "", key: name, keyCode: 0 };
  return fail("invalid_input");
}
