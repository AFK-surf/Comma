export const TemplateDraft = {
  mounted() {
    this.submitting = false;
    this.onInput = (event) => {
      if (event.target.name !== "model_search") this.el.dataset.dirty = "true";
    };
    this.onSubmit = () => {
      this.submitting = true;
    };
    this.isDirty = () => !this.submitting && this.el.dataset.dirty === "true";
    this.onHistory = (event) => {
      if (
        event.navigationType !== "traverse" ||
        !event.cancelable ||
        !this.isDirty()
      )
        return;
      if (!window.confirm("Discard unsaved template changes?"))
        event.preventDefault();
      else this.submitting = true;
    };
    this.onUnload = (event) => {
      if (!this.isDirty()) return;
      event.preventDefault();
      event.returnValue = "";
    };
    this.onNavigate = (event) => {
      const link = event.target.closest("a[href]");
      if (
        !link ||
        link.target === "_blank" ||
        event.metaKey ||
        event.ctrlKey ||
        !this.isDirty()
      )
        return;
      if (!window.confirm("Discard unsaved template changes?")) {
        event.preventDefault();
        event.stopImmediatePropagation();
      } else {
        this.submitting = true;
      }
    };
    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("change", this.onInput);
    this.el.addEventListener("submit", this.onSubmit);
    window.addEventListener("beforeunload", this.onUnload);
    window.navigation?.addEventListener("navigate", this.onHistory);
    document.addEventListener("click", this.onNavigate, true);
  },
  updated() {
    this.submitting = false;
  },
  destroyed() {
    this.el.removeEventListener("input", this.onInput);
    this.el.removeEventListener("change", this.onInput);
    this.el.removeEventListener("submit", this.onSubmit);
    window.removeEventListener("beforeunload", this.onUnload);
    window.navigation?.removeEventListener("navigate", this.onHistory);
    document.removeEventListener("click", this.onNavigate, true);
  },
};
