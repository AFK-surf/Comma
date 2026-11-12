// File I/O stays in the browser. The server validates tables and owns the draft.
export const RoutingTransfer = {
  mounted() {
    this.onClick = event => {
      if (event.target.closest("[data-routing-import]")) {
        this.el.querySelector("input[type=file]").click();
      }
    };
    this.onChange = async event => {
      const input = event.target;
      if (input.type !== "file") return;
      event.stopPropagation();
      const file = input.files[0];
      input.value = "";
      if (!file) return;
      if (file.size > Number(this.el.dataset.maxBytes)) {
        this.pushEvent("routing-file-error", { reason: "too_large" });
        return;
      }
      try {
        const json = await file.text();
        this.pushEvent("import-routing", { json });
      } catch {
        this.pushEvent("routing-file-error", { reason: "unreadable" });
      }
    };
    this.el.addEventListener("click", this.onClick);
    this.el.addEventListener("change", this.onChange);
    this.handleEvent("download-routing", ({ filename, json }) => {
      const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = filename;
      document.body.appendChild(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    });
  },
  destroyed() {
    this.el.removeEventListener("click", this.onClick);
    this.el.removeEventListener("change", this.onChange);
  },
};
