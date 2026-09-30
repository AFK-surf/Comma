import { ActivityTooltip } from "./activity_tooltip.mjs";
import { SubscriptionOAuth } from "./subscription_oauth";
// Salix admin dashboard LiveSocket entry. esbuild bundles phoenix +
// phoenix_live_view from deps (NODE_PATH) and topbar from ./vendor. The socket
// path is /dash/live because the dashboard endpoint is mounted under /dash on
// the shared Bandit listener.
import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import topbar from "../vendor/topbar";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

import { BrowserLocalTime } from "./browser_local_time.mjs";

import { ResponsiveNavigation } from "./responsive_navigation.mjs";

import { CommandDraft } from "./command_draft.mjs";

import { TemplateDraft } from "./template_draft.mjs";

import { PersistentDetails } from "./persistent_details.mjs";
import { FloatingDropdown } from "./floating_dropdown.mjs";

const Hooks = { ResponsiveNavigation, CommandDraft, TemplateDraft, FloatingDropdown, PersistentDetails };

Hooks.CatalogPage = {
  mounted() { this.cursor = this.el.dataset.cursor; },
  updated() {
    if (this.cursor !== this.el.dataset.cursor) {
      this.cursor = this.el.dataset.cursor;
      const main = this.el.closest("main");
      if (main) main.scrollTop += this.el.getBoundingClientRect().top - main.getBoundingClientRect().top - 16;
    }
  },
};

// Rewrites server-rendered UTC times into the viewer's time zone; attached to
// the dashboard shell so every page gets it.
Hooks.BrowserLocalTime = BrowserLocalTime;

Hooks.SubscriptionOAuth = SubscriptionOAuth;
Hooks.ActivityTooltip = ActivityTooltip;

// Keep a scroll container pinned to the bottom as new content streams in
// (used by the conversation live chat). Set phx-hook="ScrollBottom" on the
// scrollable element.
Hooks.ScrollBottom = {
  mounted() {
    this.scroll();
  },
  updated() {
    this.scroll();
  },
  scroll() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

const liveSocket = new LiveSocket("/dash/live", Socket, {
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
