import { SubscriptionOAuth } from "../../../salix_web/assets/js/subscription_oauth";
// BridgeForTeams dashboard LiveSocket entry. esbuild bundles phoenix +
// phoenix_live_view from deps (NODE_PATH) and topbar from ./vendor.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { animate } from "../vendor/anime.esm.js";
import { SkillComposer } from "./skill_composer";
import { PluginRefsEditor } from "./plugin_refs_editor";
import { ManagedRuntimeAuth, RuntimeAuth } from "./runtime_auth.mjs";
import { BrowserLocalTime } from "./browser_local_time.mjs";

const reducedMotion = () =>
  window.matchMedia("(prefers-reduced-motion: reduce)").matches;

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const Hooks = {};
Hooks.SubscriptionOAuth = SubscriptionOAuth;

Hooks.RuntimeAuth = RuntimeAuth;
Hooks.ManagedRuntimeAuth = ManagedRuntimeAuth;

Hooks.BrowserLocalTime = BrowserLocalTime;

// The dashboard shell exposes a small, navigation-only command surface. It is
// deliberately client-side: destinations are already authorized and rendered
// by the current LiveView, so filtering never needs a server round-trip.
Hooks.NavigationSearch = {
  mounted() {
    this.previousFocus = null;
    this.refreshElements();
    window.requestAnimationFrame(() => this.scrollCurrentIntoView());

    this.onClick = (event) => {
      if (event.target.closest("[data-navigation-open-trigger]")) {
        window.requestAnimationFrame(() =>
          this.scrollCurrentIntoView({ force: true }),
        );
        return;
      }

      if (event.target.closest("[data-navigation-search-trigger]")) {
        event.preventDefault();
        this.openDialog();
        return;
      }

      if (event.target.closest("[data-navigation-search-close]")) {
        event.preventDefault();
        this.closeDialog();
        return;
      }

      if (event.target.closest("[data-navigation-search-item]")) {
        this.closeDialog({ restoreFocus: false });
        document
          .querySelector("#dashboard-navigation")
          ?.classList.add("hidden");
      }
    };

    this.onInput = (event) => {
      if (event.target.matches("[data-navigation-search-input]")) {
        this.filter(event.target.value);
      }
    };

    this.onKeydown = (event) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        this.openDialog();
        return;
      }

      if (!this.isOpen()) return;

      if (event.key === "Escape") {
        event.preventDefault();
        this.closeDialog();
        return;
      }

      const items = this.visibleItems();
      if (
        event.target === this.input &&
        event.key === "ArrowDown" &&
        items[0]
      ) {
        event.preventDefault();
        items[0].focus();
        return;
      }
      if (
        event.target === this.input &&
        event.key === "ArrowUp" &&
        items.at(-1)
      ) {
        event.preventDefault();
        items.at(-1).focus();
        return;
      }

      const itemIndex = items.indexOf(document.activeElement);
      if (itemIndex >= 0 && event.key === "ArrowDown") {
        event.preventDefault();
        items[(itemIndex + 1) % items.length].focus();
        return;
      }
      if (itemIndex >= 0 && event.key === "ArrowUp") {
        event.preventDefault();
        items[(itemIndex - 1 + items.length) % items.length].focus();
        return;
      }

      if (event.key === "Tab") this.trapFocus(event);
    };

    this.el.addEventListener("click", this.onClick);
    this.el.addEventListener("input", this.onInput);
    document.addEventListener("keydown", this.onKeydown);
  },

  updated() {
    this.refreshElements();
    if (this.isOpen()) this.filter(this.input?.value || "");
    window.requestAnimationFrame(() => this.scrollCurrentIntoView());
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.el.removeEventListener("input", this.onInput);
    document.removeEventListener("keydown", this.onKeydown);
    document.body.style.overflow = "";
  },

  refreshElements() {
    this.dialog = this.el.querySelector("[data-navigation-search-dialog]");
    this.input = this.el.querySelector("[data-navigation-search-input]");
    this.empty = this.el.querySelector("[data-navigation-search-empty]");
  },

  isOpen() {
    return this.dialog && !this.dialog.classList.contains("hidden");
  },

  openDialog() {
    if (!this.dialog) return;
    this.previousFocus = document.activeElement;
    this.dialog.classList.remove("hidden");
    this.dialog.setAttribute("aria-hidden", "false");
    this.el
      .querySelectorAll("[data-navigation-search-trigger]")
      .forEach((trigger) => trigger.setAttribute("aria-expanded", "true"));
    document.body.style.overflow = "hidden";
    if (this.input) this.input.value = "";
    this.filter("");
    window.requestAnimationFrame(() => this.input?.focus());
  },

  closeDialog({ restoreFocus = true } = {}) {
    if (!this.dialog) return;
    this.dialog.classList.add("hidden");
    this.dialog.setAttribute("aria-hidden", "true");
    this.el
      .querySelectorAll("[data-navigation-search-trigger]")
      .forEach((trigger) => trigger.setAttribute("aria-expanded", "false"));
    document.body.style.overflow = "";
    if (restoreFocus && this.previousFocus instanceof HTMLElement) {
      this.previousFocus.focus();
    }
  },

  filter(query) {
    const normalized = query.trim().toLocaleLowerCase();
    let visible = 0;

    this.el
      .querySelectorAll("[data-navigation-search-item]")
      .forEach((item) => {
        const matches =
          !normalized || item.dataset.searchText.includes(normalized);
        item.classList.toggle("hidden", !matches);
        if (matches) visible += 1;
      });

    this.empty?.classList.toggle("hidden", visible !== 0);
  },

  visibleItems() {
    return [
      ...this.el.querySelectorAll("[data-navigation-search-item]"),
    ].filter((item) => !item.classList.contains("hidden"));
  },

  scrollCurrentIntoView({ force = false } = {}) {
    const current = this.el.querySelector(
      "#dashboard-navigation nav [aria-current='page']",
    );
    const route = current?.getAttribute("href") || null;
    if (!force && route === this.currentNavigationRoute) return;

    this.currentNavigationRoute = route;
    current?.scrollIntoView({ block: "nearest", inline: "nearest" });
  },

  trapFocus(event) {
    const focusable = [
      ...this.dialog.querySelectorAll(
        "section input:not([disabled]), section button:not([disabled]), section a[href]",
      ),
    ].filter((element) => !element.classList.contains("hidden"));
    if (focusable.length === 0) return;

    const first = focusable[0];
    const last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  },
};

// Native <details> provides keyboard and screen-reader semantics. This hook
// only persists the user's open/closed choice across LiveView navigation.
Hooks.PersistDisclosure = {
  mounted() {
    this.storageKey = this.el.dataset.storageKey;
    this.applyStoredState();
    this.onToggle = () => {
      if (!this.storageKey) return;
      try {
        localStorage.setItem(this.storageKey, String(this.el.open));
      } catch (_error) {
        // Private browsing or storage policy can disable localStorage.
      }
    };
    this.el.addEventListener("toggle", this.onToggle);
  },

  updated() {
    this.applyStoredState();
  },

  destroyed() {
    this.el.removeEventListener("toggle", this.onToggle);
  },

  applyStoredState() {
    if (!this.storageKey) return;
    if (this.el.dataset.forceOpen === "true") {
      this.el.open = true;
      return;
    }
    try {
      const stored = localStorage.getItem(this.storageKey);
      this.el.open =
        stored === null
          ? this.el.dataset.defaultOpen === "true"
          : stored === "true";
    } catch (_error) {
      this.el.open = this.el.dataset.defaultOpen === "true";
    }
  },
};

// Copy the text of a target element (data-copy-target selector) to the
// clipboard. Used by generated provider setup snippets.
Hooks.CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      if (this.el.dataset.copyStopPropagation === "true") {
        event.preventDefault();
        event.stopPropagation();
      }

      const selector = this.el.getAttribute("data-copy-target");
      const target = selector && document.querySelector(selector);
      if (!target || !navigator.clipboard) return;

      navigator.clipboard.writeText(target.innerText).then(() => {
        const original = this.el.textContent;
        this.el.textContent = "Copied";
        setTimeout(() => {
          this.el.textContent = original;
        }, 1200);
      });
    });
  },
};

// Clear a composer form right after its submit event is queued, so the input
// empties immediately instead of fighting the focused-input patch protection.
Hooks.ResetOnSubmit = {
  mounted() {
    this.el.addEventListener("submit", () => {
      window.requestAnimationFrame(() => this.el.reset());
    });
  },
};

Hooks.ScrollToBottom = {
  mounted() {
    this.lastScrollKey = this.el.dataset.scrollKey || "";

    if (this.ownsScroll()) this.scrollToBottom();
  },

  updated() {
    const key = this.el.dataset.scrollKey || "";
    if (key === this.lastScrollKey) return;
    this.scrollToBottom();
  },

  scrollToBottom() {
    this.lastScrollKey = this.el.dataset.scrollKey || "";
    window.requestAnimationFrame(() => {
      const container = this.scrollContainer();
      container.scrollTop = container.scrollHeight;
    });
  },

  ownsScroll() {
    const overflowY = window.getComputedStyle(this.el).overflowY;
    return overflowY === "auto" || overflowY === "scroll";
  },

  scrollContainer() {
    return this.ownsScroll()
      ? this.el
      : this.el.closest("[data-scroll-main]") || this.el;
  },
};

Hooks.SessionTimeline = {
  mounted() {
    this.pageKey = this.el.dataset.pageKey;
    this.loading = false;
    this.requestedPageKeys = new Set();
    this.el.querySelectorAll("details[open]").forEach((detail) => {
      detail.open = false;
    });
    this.onScroll = () => this.maybeLoadOlder();
    this.el.addEventListener("scroll", this.onScroll, { passive: true });
    window.requestAnimationFrame(() => {
      this.el.scrollTop = this.el.scrollHeight;
      this.maybeLoadOlder({ ifUnderfilled: true });
    });
  },

  maybeLoadOlder({ ifUnderfilled = false } = {}) {
    const pageKey = this.el.dataset.pageKey;
    const isUnderfilled = this.el.scrollHeight <= this.el.clientHeight + 1;
    const isAtStart = this.el.scrollTop <= 80;

    if (
      this.el.dataset.hasMore !== "true" ||
      this.loading ||
      !pageKey ||
      this.requestedPageKeys.has(pageKey) ||
      (!isAtStart && !(ifUnderfilled && isUnderfilled))
    ) {
      return;
    }

    this.previousHeight = this.el.scrollHeight;
    this.previousTop = this.el.scrollTop;
    this.loading = true;
    this.requestedPageKeys.add(pageKey);
    this.pushEvent("load_older");
  },

  beforeUpdate() {
    if (!this.loading) {
      this.previousHeight = this.el.scrollHeight;
      this.previousTop = this.el.scrollTop;
    }
  },

  updated() {
    const pageKey = this.el.dataset.pageKey;
    if (pageKey !== this.pageKey) {
      this.el.scrollTop =
        this.previousTop + this.el.scrollHeight - this.previousHeight;
      this.pageKey = pageKey;
    }
    if (this.el.dataset.loading !== "true") {
      this.loading = false;
      window.requestAnimationFrame(() =>
        this.maybeLoadOlder({ ifUnderfilled: true }),
      );
    }
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll);
  },
};

// New Home composers: contenteditable editor with /-skill mention chips —
// Enter sends (Shift+Enter breaks the line, IME-safe), clears at submit, and
// mirrors its content into the hidden chat[text]/chat[skills] inputs.
Hooks.SkillComposer = SkillComposer;
Hooks.PluginRefsEditor = PluginRefsEditor;

// Composer forms without mentions: Enter sends (Shift+Enter breaks the line;
// IME composition Enter never sends), and the form clears itself at submit
// time — same focused-input rationale as ResetOnSubmit. Submits only once the
// chat is ready (data-ready), so nothing typed is ever silently dropped.
Hooks.ComposerKeys = {
  mounted() {
    const textarea = this.el.querySelector("textarea");
    textarea?.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.isComposing) return;
      e.preventDefault();
      if (this.el.dataset.ready === "true") this.el.requestSubmit();
    });
    this.el.addEventListener("submit", () => {
      window.requestAnimationFrame(() => this.el.reset());
    });
  },
};

// "Send" on the draft editor: open Gmail compose with the CURRENT (possibly
// unsaved) form values. Must run synchronously inside the submit gesture —
// window.open from a later server round-trip gets popup-blocked.
Hooks.GmailHandoff = {
  mounted() {
    this.el.addEventListener("submit", (e) => {
      if (e.submitter?.value !== "send") return;
      const data = new FormData(this.el);
      const params = new URLSearchParams({
        view: "cm",
        fs: "1",
        to: data.get("draft[to]") || "",
        su: data.get("draft[subject]") || "",
        body: data.get("draft[body]") || "",
      });
      window.open(
        `https://mail.google.com/mail/?${params}`,
        "_blank",
        "noopener",
      );
    });
  },
};

// A task row leaves the working list with a quick exit (ease-in, under
// 300ms) before the server removes it. Buttons carry data-exit-action +
// data-task-id instead of phx-click so the animation can run first;
// reduced-motion users get the instant removal.
Hooks.RowExit = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-exit-action]");
      if (!btn || !this.el.contains(btn)) return;
      e.preventDefault();

      const action = btn.dataset.exitAction;
      const payload = { id: btn.dataset.taskId };
      const row = btn.closest("[data-task-row]");

      if (!row || reducedMotion()) {
        this.pushEvent(action, payload);
        return;
      }

      // presence-disable-interactions: the exiting row takes no more clicks.
      // Compositor props only (opacity/transform) — the list closes up when
      // the server removes the already-invisible row.
      row.style.pointerEvents = "none";
      animate(row, {
        opacity: 0,
        x: 8,
        duration: 180,
        ease: "inQuad",
        onComplete: () => this.pushEvent(action, payload),
      });
    });
  },
};

// Toast lifecycle: auto-dismiss after 5s, paused while the pointer is over
// the toast (Linear's behavior), resuming with a short grace period. Dismiss
// goes through the close button's JS.push("lv:clear-flash") so the server
// clears the flash and removal plays the phx-remove exit transition — one
// code path for timer, click, and Escape-free consistency.
Hooks.Flash = {
  mounted() {
    const DWELL_MS = 5000;
    const RESUME_MS = 2000;
    const dismiss = () => this.el.querySelector("[data-flash-close]")?.click();
    this.arm = (ms) => {
      clearTimeout(this.timer);
      this.timer = setTimeout(dismiss, ms);
    };
    this.onEnter = () => clearTimeout(this.timer);
    this.onLeave = () => this.arm(RESUME_MS);
    this.el.addEventListener("mouseenter", this.onEnter);
    this.el.addEventListener("mouseleave", this.onLeave);
    this.arm(DWELL_MS);
  },

  // A replaced message (same flash kind re-set) restarts the clock.
  updated() {
    this.arm(5000);
  },

  destroyed() {
    clearTimeout(this.timer);
  },
};

// Drag-to-resize for the My Space chat rail: the left-gutter grip drags the
// rail between 280 and 450px. Pure pointer events + setPointerCapture on the
// grip — no DOM reorder happens mid-gesture, so capture survives (the DashGrid
// resize precedent). The width is client chrome stored in localStorage and
// applied as a CSS custom property on <html> (the aside's class reads
// var(--bft-rail-w)): LiveView patches re-sync element attributes and would
// strip an inline style, but they never touch the document element.
Hooks.RailResize = {
  MIN: 280,
  MAX: 450,
  STORE: "bft:rail-width",

  mounted() {
    this.clampWidth = (w) =>
      Math.round(Math.min(this.MAX, Math.max(this.MIN, w)));
    const stored = parseInt(localStorage.getItem(this.STORE), 10);
    if (Number.isFinite(stored)) this.setWidth(this.clampWidth(stored));

    const grip = this.el.querySelector("[data-rail-resize]");
    if (!grip) return;

    grip.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      e.preventDefault();
      grip.setPointerCapture(e.pointerId);
      const startX = e.clientX;
      const startWidth = this.el.getBoundingClientRect().width;
      document.body.style.cursor = "col-resize";
      document.body.style.userSelect = "none";

      const move = (ev) => {
        // The rail sits on the right: dragging left widens it.
        this.setWidth(this.clampWidth(startWidth + (startX - ev.clientX)));
      };

      const finish = () => {
        grip.removeEventListener("pointermove", move);
        grip.removeEventListener("pointerup", finish);
        grip.removeEventListener("pointercancel", finish);
        document.body.style.cursor = "";
        document.body.style.userSelect = "";
        if (this.width) localStorage.setItem(this.STORE, String(this.width));
      };

      grip.addEventListener("pointermove", move);
      grip.addEventListener("pointerup", finish);
      grip.addEventListener("pointercancel", finish);
    });
  },

  setWidth(w) {
    this.width = w;
    document.documentElement.style.setProperty("--bft-rail-w", `${w}px`);
  },
};

// Drag-to-reorder for the New Home widget wall bento grid. Input pipeline:
// press a card ~350ms to lift it (the header handle lifts instantly); a
// transparent full-screen shield keeps pointer events alive over the report
// iframes; move/end listen to mouse+touch events, NOT pointer events —
// reordering the pressed element mid-drag makes the browser cancel its
// pointer stream, while mouse/touch events keep flowing. The drag itself is
// Notion multi-column: the grid holds still while a blue guide marks the
// drop — vertical in the gap beside a card (join its row as a column; the
// card adopts the neighbor's spans, so a large slotted next to a small
// becomes small), or horizontal across the grid (start a new row; the card
// keeps its size). The drop FLIP-inserts and resizes in one pass. Server
// size patches (S/M/L) FLIP too, morphing position AND size.
Hooks.DashGrid = {
  mounted() {
    const HOLD_MS = 350;
    const grid = this.el;
    const state = (this.drag = {
      dragging: null,
      ghost: null,
      shield: null,
      finish: null,
    });
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    const cards = () => [
      ...grid.querySelectorAll(":scope > [data-dash-widget]"),
    ];

    // One card's FLIP run. Cleanup is a token-guarded timeout, NOT
    // transitionend — bubbled child transitions (hover fades on the grip,
    // button color tweens) would fire a bubbling listener early and strand
    // the card mid-animation. Shared with updated() via `this`.
    const flipEl = (this.flipEl = (el, dx, dy, sx = 1, sy = 1) => {
      clearTimeout(el._dashFlipTimer);
      el.style.transition = "none";
      el.style.transformOrigin = "top left";
      el.style.transform = `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`;
      el.getBoundingClientRect();
      el.style.transition = "transform 250ms cubic-bezier(0.22, 1, 0.36, 1)";
      el.style.transform = "";
      el._dashFlipTimer = setTimeout(() => {
        el.style.transition = "";
        el.style.transformOrigin = "";
      }, 300);
    });

    // FLIP: capture rects, mutate the DOM, then run each moved card from its
    // inverted old rect to its new one. Compositor-only (transform), 250ms
    // smooth-out — the shared "position change" motion token.
    const flip = (mutate, { scale = false, skip = null } = {}) => {
      if (reduceMotion.matches) return mutate();
      const before = new Map(
        cards().map((el) => [
          el.dataset.dashWidget,
          el.getBoundingClientRect(),
        ]),
      );
      mutate();
      for (const el of cards()) {
        if (el === skip) continue;
        const prev = before.get(el.dataset.dashWidget);
        if (!prev) continue;
        const next = el.getBoundingClientRect();
        const dx = prev.left - next.left;
        const dy = prev.top - next.top;
        const sx = scale && next.width ? prev.width / next.width : 1;
        const sy = scale && next.height ? prev.height / next.height : 1;
        if (!dx && !dy && sx === 1 && sy === 1) continue;
        flipEl(el, dx, dy, sx, sy);
      }
    };

    const preventTouch = (e) => e.preventDefault();

    const positionGhost = (x, y) => {
      state.ghost.style.left = `${x - state.ghost.dataset.offsetX}px`;
      state.ghost.style.top = `${y - state.ghost.dataset.offsetY}px`;
    };

    const beginDrag = (widget, x, y) => {
      state.releaseCapture?.();
      state.dragging = widget;
      state.drop = null;
      const styles = getComputedStyle(grid);
      state.colGap = parseFloat(styles.columnGap) || 12;
      state.rowGap = parseFloat(styles.rowGap) || 12;
      const rect = widget.getBoundingClientRect();

      state.shield = document.createElement("div");
      state.shield.style.cssText =
        "position:fixed;inset:0;z-index:70;cursor:grabbing;";
      document.body.appendChild(state.shield);

      state.ghost = widget.cloneNode(true);
      state.ghost.style.cssText = `position:fixed;z-index:71;pointer-events:none;width:${rect.width}px;height:${rect.height}px;opacity:.92;transform:rotate(1deg);box-shadow:0 12px 32px rgb(0 0 0 / .18);border-radius:12px;`;
      state.ghost.dataset.offsetX = x - rect.left;
      state.ghost.dataset.offsetY = y - rect.top;
      document.body.appendChild(state.ghost);
      positionGhost(x, y);

      // Notion-style insertion guide: a brand-blue bar riding the gap beside
      // (or above/below) the hovered card. The drag never repacks the grid
      // live — the guide states intent, the drop commits it.
      state.guide = document.createElement("div");
      state.guide.style.cssText =
        "position:fixed;z-index:71;width:3px;border-radius:2px;background:#205bff;box-shadow:0 0 0 1px rgb(32 91 255 / .2);pointer-events:none;display:none;";
      document.body.appendChild(state.guide);

      widget.style.opacity = "0.35";
      document.body.style.userSelect = "none";
      window.addEventListener("touchmove", preventTouch, { passive: false });

      // Edge auto-scroll: the shield eats wheel events, so a drag can never
      // scroll the page by itself — parking the pointer near the viewport's
      // top/bottom edge scrolls the wall's column instead. Runs on rAF (mouse
      // events stop when the pointer holds still); after each scroll the
      // guide is recomputed from the fresh rects. Armed only once the pointer
      // has moved mid-drag: lifting a card whose grab point already sits in
      // the edge band must not scroll under a motionless pointer.
      state.lastX = x;
      state.lastY = y;
      state.scrollArmed = false;
      state.scroller = (() => {
        let node = grid.parentElement;
        while (node && node !== document.body) {
          const s = getComputedStyle(node);
          if (
            /(auto|scroll)/.test(s.overflowY) &&
            node.scrollHeight > node.clientHeight
          ) {
            return node;
          }
          node = node.parentElement;
        }
        return null;
      })();
      const EDGE = 72;
      const MAX_STEP = 14;
      const autoScroll = () => {
        if (!state.dragging) return;
        const s = state.scroller;
        if (s && state.scrollArmed) {
          const h = window.innerHeight;
          // Band depth is clamped to EDGE: a held mouse drag keeps reporting
          // coordinates past the viewport, and unclamped they would scale the
          // step far beyond MAX_STEP.
          let dy = 0;
          if (state.lastY < EDGE)
            dy = -Math.ceil(
              (Math.min(EDGE - state.lastY, EDGE) / EDGE) * MAX_STEP,
            );
          else if (state.lastY > h - EDGE)
            dy = Math.ceil(
              (Math.min(state.lastY - (h - EDGE), EDGE) / EDGE) * MAX_STEP,
            );
          if (dy) {
            const before = s.scrollTop;
            s.scrollTop = before + dy;
            if (s.scrollTop !== before) moveDrag(state.lastX, state.lastY);
          }
        }
        state.scrollRaf = requestAnimationFrame(autoScroll);
      };
      state.scrollRaf = requestAnimationFrame(autoScroll);
    };

    // Two guide orientations, one element: a vertical bar in the column gap
    // beside `target`, or a horizontal bar across the grid above/below it.
    const showGuide = (opts) => {
      const rect = opts.target.getBoundingClientRect();
      if (opts.mode === "col") {
        const mid = opts.before
          ? rect.left - state.colGap / 2
          : rect.right + state.colGap / 2;
        Object.assign(state.guide.style, {
          display: "block",
          left: `${mid - 1.5}px`,
          top: `${rect.top}px`,
          width: "3px",
          height: `${rect.height}px`,
        });
      } else {
        const g = grid.getBoundingClientRect();
        const y = opts.above
          ? rect.top - state.rowGap / 2
          : rect.bottom + state.rowGap / 2;
        Object.assign(state.guide.style, {
          display: "block",
          left: `${g.left}px`,
          top: `${y - 1.5}px`,
          width: `${g.width}px`,
          height: "3px",
        });
      }
    };

    // Cards sharing the target's top (above) or bottom (below) row band, in
    // DOM order — the insertion anchors for horizontal (new-row) drops. Never
    // empty: the target itself is in its own band.
    const rowBandCards = (target, above) => {
      const rowH = parseFloat(getComputedStyle(grid).gridAutoRows) || 176;
      const r = target.getBoundingClientRect();
      const top = (above ? r.top : r.bottom - rowH) + 8;
      const bottom = (above ? r.top + rowH : r.bottom) - 8;
      return cards().filter((el) => {
        if (el === state.dragging) return false;
        const c = el.getBoundingClientRect();
        return c.top < bottom && c.bottom > top;
      });
    };

    const moveDrag = (x, y) => {
      state.lastX = x;
      state.lastY = y;
      state.scrollArmed = true;
      positionGhost(x, y);
      state.ghost.style.display = "none";
      state.shield.style.display = "none";
      const under = document.elementFromPoint(x, y);
      state.shield.style.display = "";
      state.ghost.style.display = "";

      // Off the grid entirely: no drop — the guide disappears and release
      // puts the card back, like Notion.
      if (!under || !grid.contains(under)) {
        state.drop = null;
        state.guide.style.display = "none";
        return;
      }

      const target = under.closest("[data-dash-widget]");
      if (!target || target.parentElement !== grid) {
        // In the padding below the last row, "append as a new bottom row" is
        // the only reading. In the 12px gaps between cards, keep the last
        // guide — clearing there would make it flicker on every crossing.
        const all = cards().filter((el) => el !== state.dragging);
        const last = all[all.length - 1];
        if (last && y > last.getBoundingClientRect().bottom) {
          state.drop = { mode: "row", anchor: null, target: null };
          showGuide({ mode: "row", target: last, above: false });
        }
        return;
      }
      if (target === state.dragging) return;

      // Nearest edge picks the axis, Notion-style: left/right edges mean
      // "join this row as a column" (vertical guide), top/bottom mean "start
      // a new row" (horizontal guide). Corners resolve to the closer edge.
      const rect = target.getBoundingClientRect();
      const px = (x - rect.left) / rect.width;
      const py = (y - rect.top) / rect.height;

      if (Math.min(px, 1 - px) < Math.min(py, 1 - py)) {
        const before = px < 0.5;
        let anchor = before ? target : target.nextElementSibling;
        // insertBefore(node, node) throws; the equivalent slot is one over.
        if (anchor === state.dragging)
          anchor = state.dragging.nextElementSibling;
        state.drop = { mode: "col", anchor, target };
        showGuide({ mode: "col", target, before });
      } else {
        const above = py < 0.5;
        const band = rowBandCards(target, above);
        let anchor = above ? band[0] : band[band.length - 1].nextElementSibling;
        if (anchor === state.dragging)
          anchor = state.dragging.nextElementSibling;
        state.drop = { mode: "row", anchor, target: null };
        showGuide({ mode: "row", target, above });
      }
    };

    const endDrag = (commit) => {
      cancelAnimationFrame(state.scrollRaf);
      state.scroller = null;
      if (state.ghost) state.ghost.remove();
      if (state.shield) state.shield.remove();
      if (state.guide) state.guide.remove();
      state.ghost = null;
      state.shield = null;
      state.guide = null;
      if (state.dragging) state.dragging.style.opacity = "";
      document.body.style.userSelect = "";
      window.removeEventListener("touchmove", preventTouch);

      if (commit && state.dragging && state.drop) {
        const widget = state.dragging;
        const { anchor, target, mode } = state.drop;
        // Column drops adopt the neighbor's cell, never growing — Notion's
        // "a block takes its column's width" mapped to spans: a large card
        // slotted beside a small becomes small, beside a medium becomes
        // medium. Row drops start their own row, so the card keeps its size.
        const cur = spansOf(widget);
        let next = cur;
        // Row members that must shrink with the join to make room.
        let shrink = [];
        if (mode === "col" && target) {
          const t = spansOf(target);
          next = {
            cols: Math.min(cur.cols, t.cols),
            rows: Math.min(cur.rows, t.rows),
          };
          // The guide promises "this card beside the target", and that only
          // needs room for the row members ahead of the target, the target,
          // and the card — anything after the target is displaced by the
          // insert and wraps out on its own (row flow). When those
          // participants exceed the grid's tracks, the row splits into
          // columns and they all drop to 1x1 — before this, medium-beside-
          // medium on the 2-col wall was a silent no-op (no width change,
          // the card just stacked below). Counting the whole band here would
          // over-shrink on the 3-col wall: a drop beside a large would
          // needlessly flatten it when the trailing card could simply wrap.
          const gridCols =
            getComputedStyle(grid).gridTemplateColumns.split(" ").length;
          const band = rowBandCards(target, true);
          const participants = band.slice(0, band.indexOf(target) + 1);
          const used = participants.reduce(
            (sum, el) => sum + spansOf(el).cols,
            0,
          );
          if (used + next.cols > gridCols) {
            next = { cols: 1, rows: 1 };
            shrink = participants.filter((el) => {
              const s = spansOf(el);
              return s.cols !== 1 || s.rows !== 1;
            });
          }
        }
        const resized = next.cols !== cur.cols || next.rows !== cur.rows;
        flip(() => {
          grid.insertBefore(widget, anchor);
          if (resized) setSpans(widget, next.cols, next.rows);
          for (const el of shrink) setSpans(el, 1, 1);
        });
        const order = cards().map((el) => el.dataset.dashWidget);
        this.pushEvent("reorder_dash_widgets", { order });
        if (resized) {
          this.pushEvent("set_widget_size", {
            category: widget.dataset.dashWidget,
            size: sizeOf(next),
          });
        }
        for (const el of shrink) {
          this.pushEvent("set_widget_size", {
            category: el.dataset.dashWidget,
            size: "small",
          });
        }
      }
      state.dragging = null;
      state.drop = null;
      state.finish = null;
    };

    // --- Notion-style corner resize: drag the grip, the card snaps live
    // between 1x1 / 2x1 / 2x2 spans (siblings FLIP out of the way), release
    // commits the mapped size. No DOM reorder happens, so plain pointer
    // capture is safe here — it also keeps events flowing over iframes.
    const spansOf = (el) => ({
      cols: el.classList.contains("col-span-2") ? 2 : 1,
      rows: el.classList.contains("row-span-2") ? 2 : 1,
    });

    const setSpans = (el, cols, rows) => {
      el.classList.toggle("col-span-1", cols === 1);
      el.classList.toggle("col-span-2", cols === 2);
      el.classList.toggle("row-span-1", rows === 1);
      el.classList.toggle("row-span-2", rows === 2);
    };

    // (1,2) has no size of its own — a pull downward means "bigger", so it
    // rounds up to large.
    const sizeOf = ({ cols, rows }) =>
      rows === 2 ? "large" : cols === 2 ? "medium" : "small";

    grid.addEventListener("pointerdown", (e) => {
      const handle = e.target.closest("[data-resize-handle]");
      if (!handle) return;
      if (e.button !== undefined && e.button !== 0) return;
      if (state.dragging || state.resize) return;
      const widget = handle.closest("[data-dash-widget]");
      if (!widget || widget.parentElement !== grid) return;
      // The visible skin: it tracks the pointer pixel-for-pixel while the
      // grid item underneath (the slot) snaps between spans.
      const skin = widget.firstElementChild;
      if (!skin) return;

      e.preventDefault();
      try {
        handle.setPointerCapture(e.pointerId);
      } catch {}

      const styles = getComputedStyle(grid);
      const colW = parseFloat(styles.gridTemplateColumns.split(" ")[0]);
      const colGap = parseFloat(styles.columnGap) || 0;
      const rowH = parseFloat(styles.gridAutoRows) || 176;
      const rowGap = parseFloat(styles.rowGap) || 0;
      // A re-grab may land mid-settle: kill the pending style reset and the
      // inherited tween so tracking is instant, and measure the SKIN (its
      // current visual size) for gesture continuity, not the slot.
      clearTimeout(state.settleTimer);
      skin.style.transition = "none";
      const startRect = skin.getBoundingClientRect();
      const start = spansOf(widget);
      let current = { ...start };

      const slotPx = ({ cols, rows }) => ({
        w: cols * colW + (cols - 1) * colGap,
        h: rows * rowH + (rows - 1) * rowGap,
      });
      const clamp = (v, min, max) => Math.min(max, Math.max(min, v));

      widget.style.zIndex = "40";
      // Active state: the card's own hairline turns brand blue — no dashed
      // outline ring.
      skin.style.borderColor = "#205bff";
      skin.style.willChange = "width, height";
      document.body.style.userSelect = "none";
      document.body.style.cursor = "nwse-resize";

      const onMove = (ev) => {
        // 1:1 live tracking — the card follows the pointer continuously,
        // gently clamped just past the smallest/largest slot.
        const w = clamp(
          startRect.width + (ev.clientX - e.clientX),
          colW * 0.75,
          2 * colW + colGap + 16,
        );
        const h = clamp(
          startRect.height + (ev.clientY - e.clientY),
          rowH * 0.75,
          2 * rowH + rowGap + 16,
        );
        skin.style.width = `${w}px`;
        skin.style.height = `${h}px`;

        // The slot underneath snaps to the nearest spans; siblings glide.
        // The widget itself is NOT skipped: with grid-flow-dense a span
        // change can relocate its slot, and the translate-only FLIP keeps
        // that move animated (the skin's pixel size is untouched).
        const cols = clamp(Math.round((w + colGap) / (colW + colGap)), 1, 2);
        const rows = clamp(Math.round((h + rowGap) / (rowH + rowGap)), 1, 2);
        if (cols === current.cols && rows === current.rows) return;
        current = { cols, rows };
        flip(() => setSpans(widget, cols, rows));
      };

      // Ease the skin into the final slot, then hand sizing back to the grid.
      const settle = (spans) => {
        if (!skin.isConnected) return;
        const clear = () => {
          skin.style.transition = "";
          skin.style.width = "";
          skin.style.height = "";
          skin.style.willChange = "";
          widget.style.zIndex = "";
        };
        if (reduceMotion.matches || !skin.style.width) return clear();
        const target = slotPx(spans);
        skin.style.transition =
          "width 180ms cubic-bezier(0.22, 1, 0.36, 1), height 180ms cubic-bezier(0.22, 1, 0.36, 1)";
        skin.style.width = `${target.w}px`;
        skin.style.height = `${target.h}px`;
        state.settleTimer = setTimeout(clear, 200);
      };

      const finish = (commit) => {
        try {
          handle.releasePointerCapture(e.pointerId);
        } catch {}
        handle.removeEventListener("pointermove", onMove);
        handle.removeEventListener("pointerup", onUp);
        handle.removeEventListener("pointercancel", onCancel);
        window.removeEventListener("keydown", onKey, true);
        window.removeEventListener("blur", onCancel);
        window.removeEventListener("contextmenu", onCancel);
        skin.style.borderColor = "";
        document.body.style.userSelect = "";
        document.body.style.cursor = "";
        state.resize = null;

        if (commit && sizeOf(current) !== sizeOf(start)) {
          // Normalize the preview to the committed size's canonical spans
          // (a 1x2 preview becomes large 2x2) before the server echoes it.
          const size = sizeOf(current);
          const spans = { small: [1, 1], medium: [2, 1], large: [2, 2] }[size];
          flip(() => setSpans(widget, spans[0], spans[1]));
          settle({ cols: spans[0], rows: spans[1] });
          this.pushEvent("set_widget_size", {
            category: widget.dataset.dashWidget,
            size,
          });
        } else {
          if (!commit) flip(() => setSpans(widget, start.cols, start.rows));
          settle(commit ? current : start);
        }
      };
      state.resize = { finish };

      const onUp = () => finish(true);
      const onCancel = () => finish(false);
      // Capture phase + stopPropagation: Escape mid-resize cancels the
      // gesture only — page-level phx-window-keydown closes (the task
      // drawer's) must not fire.
      const onKey = (ev) => {
        if (ev.key !== "Escape") return;
        ev.stopPropagation();
        finish(false);
      };

      handle.addEventListener("pointermove", onMove);
      handle.addEventListener("pointerup", onUp);
      handle.addEventListener("pointercancel", onCancel);
      window.addEventListener("keydown", onKey, true);
      window.addEventListener("blur", onCancel);
      window.addEventListener("contextmenu", onCancel);
    });

    grid.addEventListener("pointerdown", (e) => {
      if (e.button !== undefined && e.button !== 0) return;
      if (state.dragging || state.resize) return;
      const widget = e.target.closest("[data-dash-widget]");
      if (!widget || widget.parentElement !== grid) return;

      // Never preventDefault here: cancelling pointerdown suppresses the
      // compatibility mouse events the drag listens to. Resize owns its grip.
      if (e.target.closest("[data-resize-handle]")) return;
      const onHandle = !!e.target.closest("[data-drag-handle]");
      if (
        !onHandle &&
        e.target.closest("a,button,input,textarea,select,iframe,label")
      ) {
        return;
      }

      try {
        widget.setPointerCapture(e.pointerId);
      } catch {}
      const releaseCapture = () => {
        try {
          widget.releasePointerCapture(e.pointerId);
        } catch {}
      };
      state.releaseCapture = releaseCapture;

      const startX = e.clientX;
      const startY = e.clientY;
      const pressTimer = setTimeout(
        () => {
          // Re-check at fire time: a patch may have replaced the card, and on
          // multi-touch a resize (or another drag) may have started mid-hold.
          if (grid.contains(widget) && !state.dragging && !state.resize) {
            beginDrag(widget, startX, startY);
          }
        },
        onHandle ? 0 : HOLD_MS,
      );

      const handleMove = (x, y) => {
        if (state.dragging) {
          moveDrag(x, y);
        } else if (Math.abs(x - startX) > 8 || Math.abs(y - startY) > 8) {
          clearTimeout(pressTimer);
        }
      };

      const onMouseMove = (ev) => handleMove(ev.clientX, ev.clientY);
      const onTouchMove = (ev) => {
        const t = ev.touches[0];
        if (t) handleMove(t.clientX, t.clientY);
      };

      const finish = (commit) => {
        clearTimeout(pressTimer);
        releaseCapture();
        window.removeEventListener("mousemove", onMouseMove);
        window.removeEventListener("mouseup", onMouseUp);
        window.removeEventListener("pointerup", onPointerUp);
        window.removeEventListener("pointercancel", onPointerCancel);
        window.removeEventListener("touchmove", onTouchMove);
        window.removeEventListener("touchend", onTouchEnd);
        window.removeEventListener("touchcancel", onTouchCancel);
        window.removeEventListener("blur", onCancel);
        window.removeEventListener("contextmenu", onCancel);
        window.removeEventListener("keydown", onKey, true);
        endDrag(commit);
      };
      state.finish = finish;

      const onMouseUp = () => finish(true);
      const onTouchEnd = () => finish(true);
      const onTouchCancel = () => finish(false);
      const onPointerUp = () => {
        if (!state.dragging) finish(false);
      };
      const onPointerCancel = () => {
        if (!state.dragging) finish(false);
      };
      const onCancel = () => finish(false);
      // Capture + stopPropagation: Escape cancels the drag only, without
      // also triggering phx-window-keydown behaviors (drawer close).
      const onKey = (ev) => {
        if (ev.key !== "Escape") return;
        ev.stopPropagation();
        finish(false);
      };

      window.addEventListener("mousemove", onMouseMove);
      window.addEventListener("mouseup", onMouseUp);
      window.addEventListener("pointerup", onPointerUp);
      window.addEventListener("pointercancel", onPointerCancel);
      window.addEventListener("touchmove", onTouchMove);
      window.addEventListener("touchend", onTouchEnd);
      window.addEventListener("touchcancel", onTouchCancel);
      window.addEventListener("blur", onCancel);
      window.addEventListener("contextmenu", onCancel);
      window.addEventListener("keydown", onKey, true);
    });
  },

  // A server patch (an S/M/L click, a reorder ack) re-renders the grid: FLIP
  // every card from its pre-patch rect — including width/height, so a resized
  // card morphs into its new span instead of snapping. Rects captured during
  // a live gesture (inline-sized skin) would be garbage — skip both.
  beforeUpdate() {
    if (this.drag?.dragging || this.drag?.resize) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    // Layout boxes (offset*), NOT getBoundingClientRect: a bounding rect
    // captured mid-FLIP includes the in-flight transform, so back-to-back
    // patches (agent streaming → board refresh bursts) would re-launch every
    // card from a moving baseline — cards visibly twitch in width. offset*
    // is transform-free and integer, which also drops sub-pixel noise.
    this.prevRects = new Map(
      [...this.el.querySelectorAll(":scope > [data-dash-widget]")].map((el) => [
        el.dataset.dashWidget,
        {
          left: el.offsetLeft,
          top: el.offsetTop,
          width: el.offsetWidth,
          height: el.offsetHeight,
        },
      ]),
    );
  },

  updated() {
    if (this.drag?.dragging && this.drag.finish) return this.drag.finish(false);
    // A patch mid-resize (chat poll) re-renders the server's spans under the
    // preview — end the gesture cleanly and skip the FLIP: prevRects from
    // before the gesture no longer describe reality.
    if (this.drag?.resize) {
      this.prevRects = null;
      return this.drag.resize.finish(false);
    }

    const prev = this.prevRects;
    this.prevRects = null;
    if (!prev) return;
    for (const el of this.el.querySelectorAll(":scope > [data-dash-widget]")) {
      const old = prev.get(el.dataset.dashWidget);
      if (!old) continue;
      const dx = old.left - el.offsetLeft;
      const dy = old.top - el.offsetTop;
      const sx = el.offsetWidth ? old.width / el.offsetWidth : 1;
      const sy = el.offsetHeight ? old.height / el.offsetHeight : 1;
      // Noise floor: deltas under a pixel are re-render jitter, not layout
      // movement — animating them is exactly what reads as twitching.
      if (
        Math.abs(dx) < 1 &&
        Math.abs(dy) < 1 &&
        Math.abs(sx - 1) < 0.005 &&
        Math.abs(sy - 1) < 0.005
      )
        continue;
      this.flipEl(el, dx, dy, sx, sy);
    }
  },

  destroyed() {
    if (this.drag?.dragging && this.drag.finish) this.drag.finish(false);
    if (this.drag?.resize) this.drag.resize.finish(false);
  },
};

Hooks.OrgIconUpload = {
  mounted() {
    this.fileInput = this.el.querySelector('input[type="file"]');
    this.valueInput = this.el.querySelector("[data-org-icon-value]");
    this.preview = this.el.querySelector("[data-org-icon-preview]");
    this.fallback = this.el.querySelector("[data-org-icon-fallback]");
    this.clearButton = this.el.querySelector("[data-org-icon-clear]");

    this.fileInput?.addEventListener("change", (event) => {
      event.stopPropagation();
      this.readSelectedFile();
    });
    this.clearButton?.addEventListener("click", () => this.clearIcon());
    this.syncPreview();
  },

  readSelectedFile() {
    const file = this.fileInput?.files?.[0];
    if (!file) return;

    if (!file.type.startsWith("image/")) {
      this.fileInput.value = "";
      return;
    }

    const reader = new FileReader();
    reader.addEventListener("load", () => {
      if (typeof reader.result !== "string") return;

      this.valueInput.value = reader.result;
      this.syncPreview();
    });
    reader.readAsDataURL(file);
  },

  clearIcon() {
    if (this.fileInput) this.fileInput.value = "";
    this.valueInput.value = "";
    this.syncPreview();
  },

  syncPreview() {
    const value = this.valueInput?.value;
    const hasIcon = typeof value === "string" && value.length > 0;

    if (this.preview) {
      this.preview.src = hasIcon ? value : "";
      this.preview.classList.toggle("hidden", !hasIcon);
    }

    this.fallback?.classList.toggle("hidden", hasIcon);
    this.clearButton?.classList.toggle("hidden", !hasIcon);
  },
};

// A server-rendered alert the user can dismiss for the rest of the browser
// session: hidden until mount, stays hidden if its data-dismiss-key was
// already stored, and the [data-dismiss] button stores the key. The server
// stops rendering it entirely once the underlying condition clears.
Hooks.SessionDismissible = {
  mounted() {
    this.key = this.el.getAttribute("data-dismiss-key");
    if (!this.dismissed()) this.el.classList.remove("hidden");
    this.el.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      try {
        sessionStorage.setItem(this.key, "1");
      } catch (_e) {
        // Storage unavailable: hide for this render only.
      }
      this.el.classList.add("hidden");
    });
  },

  updated() {
    this.el.classList.toggle("hidden", this.dismissed());
  },

  dismissed() {
    try {
      return this.key && sessionStorage.getItem(this.key) === "1";
    } catch (_e) {
      return false;
    }
  },
};

// Guided onboarding tour: the server renders hidden tooltip "candidates"
// (each with a data-target CSS selector); this hook shows the first candidate
// whose target exists in the DOM, then positions a fixed spotlight + tooltip
// around the target. Re-measures on LiveView updates (MutationObserver),
// resize, and scroll.
Hooks.OnboardingTour = {
  mounted() {
    this.spotlight = this.el.querySelector("[data-tour-spotlight]");
    this.lastKey = null;
    this.raf = null;
    this.schedule = this.schedule.bind(this);

    window.addEventListener("resize", this.schedule);
    window.addEventListener("scroll", this.schedule, true);
    // childList only: targets appear/disappear via server-conditional
    // rendering; observing attributes would loop on our own style writes.
    this.observer = new MutationObserver(this.schedule);
    this.observer.observe(document.body, { childList: true, subtree: true });
    this.schedule();
  },

  updated() {
    this.schedule();
  },

  destroyed() {
    window.removeEventListener("resize", this.schedule);
    window.removeEventListener("scroll", this.schedule, true);
    this.observer?.disconnect();
    if (this.raf) cancelAnimationFrame(this.raf);
  },

  schedule() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = null;
      this.measure();
    });
  },

  activeCandidate() {
    for (const candidate of this.el.querySelectorAll("[data-tour-candidate]")) {
      const target = document.querySelector(
        candidate.getAttribute("data-target"),
      );
      if (target) return { candidate, target };
    }
    return null;
  },

  measure() {
    const active = this.activeCandidate();
    for (const c of this.el.querySelectorAll("[data-tour-candidate]")) {
      if (!active || c !== active.candidate) c.classList.add("hidden");
    }
    if (!active) {
      this.spotlight.classList.add("hidden");
      this.lastKey = null;
      return;
    }

    const { candidate, target } = active;
    const key = candidate.getAttribute("data-key");

    // First time we point at this step: scroll the target into the main
    // scrollable area so the spotlight isn't off-screen.
    if (this.lastKey !== key) {
      const main = document.querySelector("[data-scroll-main]");
      if (main && main.contains(target)) {
        const mr = main.getBoundingClientRect();
        const tr = target.getBoundingClientRect();
        if (tr.top < mr.top + 8 || tr.bottom > mr.bottom - 8) {
          main.scrollTop += tr.top - mr.top - 96;
        }
      }
      this.lastKey = key;
    }

    const pad = 6;
    const rect = target.getBoundingClientRect();
    const spot = {
      x: rect.left - pad,
      y: rect.top - pad,
      w: rect.width + pad * 2,
      h: rect.height + pad * 2,
    };
    Object.assign(this.spotlight.style, {
      left: `${spot.x}px`,
      top: `${spot.y}px`,
      width: `${spot.w}px`,
      height: `${spot.h}px`,
    });
    this.spotlight.classList.remove("hidden");

    candidate.classList.remove("hidden");
    const tw = 296;
    const gap = 14;
    const th = candidate.offsetHeight || 150;
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    let placement = candidate.getAttribute("data-placement") || "bottom";
    if (placement === "right" && spot.x + spot.w + gap + tw > vw - 12)
      placement = "left";
    if (placement === "left" && spot.x - gap - tw < 12) placement = "bottom";

    let tx;
    let ty;
    if (placement === "right") {
      tx = spot.x + spot.w + gap;
      ty = spot.y;
    } else if (placement === "left") {
      tx = spot.x - gap - tw;
      ty = spot.y;
    } else if (placement === "top") {
      tx = spot.x;
      ty = spot.y - gap - th;
    } else {
      tx = spot.x;
      ty = spot.y + spot.h + gap;
    }
    tx = Math.max(12, Math.min(tx, vw - tw - 12));
    ty = Math.max(12, Math.min(ty, vh - th - 12));
    candidate.style.left = `${tx}px`;
    candidate.style.top = `${ty}px`;
  },
};

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

// Page-load progress bar.
topbar.config({ barColors: { 0: "#205bff" }, shadowColor: "rgba(0,0,0,.3)" });
window.addEventListener("phx:page-loading-start", () => topbar.show(300));
window.addEventListener("phx:page-loading-stop", () => topbar.hide());

// Server-pushed navigation to an external product (e.g. hand a drafted email
// to Gmail compose for the actual send).
window.addEventListener("phx:open_url", (e) => {
  if (e.detail?.url) window.open(e.detail.url, "_blank", "noopener");
});

// Print the drawer's document (browser print → save as PDF). Dispatched via
// JS.dispatch on the #drawer-print-content element.
window.addEventListener("bft:print-drawer", (e) => {
  const content = e.target;
  if (!content) return;
  const title = content.dataset.printTitle || document.title;
  const w = window.open("", "_blank");
  if (!w) return;
  w.document.write(`<!doctype html><html><head><meta charset="utf-8"/>
    <title>${title}</title>
    <style>
      body{font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;color:#18181b;
           max-width:680px;margin:40px auto;padding:0 24px;line-height:1.6;font-size:14px}
      h1{font-size:22px;letter-spacing:-.01em} h2{font-size:15px;margin-top:24px}
      pre{white-space:pre-wrap;font-family:ui-monospace,monospace;font-size:12px;
          background:#f7f7f8;border-radius:8px;padding:12px}
      li{margin-bottom:4px}
    </style></head><body>${content.innerHTML}</body></html>`);
  w.document.close();
  w.focus();
  setTimeout(() => w.print(), 150);
});

// Clicking a board task whose work lives in the assistant thread (no
// conversation of its own) answers with this event: scroll the visible chat
// thread to the task's hand-off message and flash it, so the click always
// lands somewhere. Searches the last matching user message; falls back to the
// newest message when the hand-off scrolled out of the fetch window.
window.addEventListener("phx:bft:reveal-chat-message", (e) => {
  const title = (e.detail?.title || "").trim();
  // The sheet's thread sits over the rail's — reveal in the one on top.
  const thread = [...document.querySelectorAll("[data-chat-thread]")]
    .filter((el) => el.offsetParent !== null)
    .pop();
  if (!thread) return;

  const bubbles = [...thread.querySelectorAll("[data-user-message]")];
  const target =
    (title && bubbles.filter((el) => el.textContent.includes(title)).pop()) ||
    bubbles.pop();
  if (!target) return;

  const reduceMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;
  target.scrollIntoView({
    block: "center",
    behavior: reduceMotion ? "auto" : "smooth",
  });

  if (!reduceMotion) {
    target.animate(
      [
        { boxShadow: "0 0 0 3px rgba(32, 91, 255, 0.45)" },
        { boxShadow: "0 0 0 3px rgba(32, 91, 255, 0)" },
      ],
      { duration: 1200, easing: "ease-out" },
    );
  }
});

liveSocket.connect();
window.liveSocket = liveSocket;
