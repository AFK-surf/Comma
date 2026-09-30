// Open during the submit gesture, before the asynchronous authorization request.
export const SubscriptionOAuth = {
  mounted() {
    this.pollTimer = null;
    this.handleEvent("subscription-device-pending", ({ id, interval }) => {
      clearTimeout(this.pollTimer);
      this.closePending();
      this.pollTimer = setTimeout(() => this.pushEvent("poll-device", { id }), Math.max(5, interval) * 1000);
    });
    this.pendingWindow = null;
    this.onSubmit = (event) => {
      if (event.target.id !== "authorize" || this.pendingWindow) return;
      const provider = event.target.querySelector('[name="provider"]');
      if (!provider || provider.value === "codex") return;
      this.pendingWindow = window.open("about:blank", "_blank");
      if (this.pendingWindow) {
        this.pendingWindow.opener = null;
        this.pendingWindow.document.title = "Preparing authorization";
        this.pendingWindow.document.body.textContent = "Preparing authorization…";
      }
    };
    this.el.addEventListener("submit", this.onSubmit, true);
    this.handleEvent("subscription-oauth-ready", ({ url }) => {
      const popup = this.pendingWindow;
      this.pendingWindow = null;
      if (popup && !popup.closed) popup.location.replace(url);
    });
    this.handleEvent("subscription-oauth-error", () => this.closePending());
  },
  closePending() {
    if (this.pendingWindow && !this.pendingWindow.closed) this.pendingWindow.close();
    this.pendingWindow = null;
  },
  reconnected() {
    const id = this.el.dataset.deviceAttempt;
    if (id) {
      clearTimeout(this.pollTimer);
      this.pollTimer = setTimeout(() => this.pushEvent("poll-device", { id }), Math.max(5, Number(this.el.dataset.deviceInterval) || 5) * 1000);
    }
  },
  disconnected() {
    clearTimeout(this.pollTimer);
    this.closePending();
  },
  destroyed() {
    clearTimeout(this.pollTimer);
    this.el.removeEventListener("submit", this.onSubmit, true);
    this.closePending();
  },
};
