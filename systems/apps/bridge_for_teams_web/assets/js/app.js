// BridgeForTeams dashboard LiveSocket entry. esbuild bundles phoenix +
// phoenix_live_view from deps (NODE_PATH) and topbar from ./vendor.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";
import { PluginRefsEditor } from "./plugin_refs_editor";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const Hooks = {};

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

Hooks.PluginRefsEditor = PluginRefsEditor;

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

liveSocket.connect();
window.liveSocket = liveSocket;
