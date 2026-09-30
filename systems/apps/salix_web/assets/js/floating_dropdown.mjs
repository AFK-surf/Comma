// Native popovers escape table clipping and supply outside-click dismissal.
export const FloatingDropdown = {
  mounted() {
    this.trigger = this.el.querySelector("[popovertarget]");
    this.menu = this.el.querySelector("[popover]");
    this.items = () => [
      ...this.menu.querySelectorAll("[role=menuitem]:not(:disabled)"),
    ];
    this.close = () => {
      if (this.menu.matches(":popover-open")) this.menu.hidePopover();
    };
    this.beforeToggle = (event) => {
      if (event.newState === "open") this.menu.style.visibility = "hidden";
    };
    this.onToggle = (event) => {
      const open = event.newState === "open";
      this.trigger.setAttribute("aria-expanded", String(open));
      if (open) {
        const anchor = this.trigger.getBoundingClientRect();
        const box = this.menu.getBoundingClientRect();
        this.menu.style.left = `${Math.max(8, Math.min(anchor.right - box.width, window.innerWidth - box.width - 8))}px`;
        this.menu.style.top = `${anchor.bottom + 4 + box.height <= window.innerHeight - 8 ? anchor.bottom + 4 : Math.max(8, anchor.top - box.height - 4)}px`;
        this.menu.style.visibility = "visible";
        this.items()[0]?.focus({ preventScroll: true });
        window.addEventListener("resize", this.close);
        document.addEventListener("scroll", this.close, true);
      } else {
        window.removeEventListener("resize", this.close);
        document.removeEventListener("scroll", this.close, true);
      }
    };
    this.onTriggerKey = (event) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.menu.showPopover();
      }
    };
    this.onMenuKey = (event) => {
      const items = this.items();
      const current = items.indexOf(document.activeElement);
      if (["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)) {
        event.preventDefault();
        const index =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? items.length - 1
              : (current +
                  (event.key === "ArrowDown" ? 1 : -1) +
                  items.length) %
                items.length;
        items[index]?.focus();
      } else if (event.key === "Escape" || event.key === "Tab") {
        this.close();
        this.trigger.focus({ preventScroll: true });
        if (event.key === "Escape") event.preventDefault();
      }
    };
    this.menu.addEventListener("beforetoggle", this.beforeToggle);
    this.menu.addEventListener("toggle", this.onToggle);
    this.menu.addEventListener("keydown", this.onMenuKey);
    this.menu.addEventListener("click", this.close);
    this.trigger.addEventListener("keydown", this.onTriggerKey);
  },
  destroyed() {
    window.removeEventListener("resize", this.close);
    document.removeEventListener("scroll", this.close, true);
    this.menu.removeEventListener("beforetoggle", this.beforeToggle);
    this.menu.removeEventListener("toggle", this.onToggle);
    this.menu.removeEventListener("keydown", this.onMenuKey);
    this.menu.removeEventListener("click", this.close);
    this.trigger.removeEventListener("keydown", this.onTriggerKey);
  },
};
