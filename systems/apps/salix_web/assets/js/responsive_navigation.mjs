// Mobile navigation is a modal drawer; desktop keeps the existing fixed-width rail.
export const ResponsiveNavigation = {
  mounted() {
    this.sidebar = this.el.querySelector('#dash-sidebar');
    this.backdrop = this.el.querySelector('#dash-navigation-backdrop');
    this.toggle = document.getElementById('dash-navigation-toggle');
    this.content = document.getElementById('dash-content');
    this.media = window.matchMedia('(min-width: 1024px)');
    this.open = false;
    this.onToggle = () => this.setOpen(!this.open, true);
    this.onClick = (event) => {
      if (event.target.closest('#dash-navigation-close, #dash-navigation-backdrop, a')) {
        this.setOpen(false, true);
      }
    };
    this.onKey = (event) => {
      if (!this.open || this.media.matches) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        this.setOpen(false, true);
      } else if (event.key === 'Tab') {
        const items = [...this.sidebar.querySelectorAll('a[href], button, input, select, textarea, [tabindex]')]
          .filter(el => el.tabIndex >= 0 && !el.disabled && el.getClientRects().length);
        const first = items[0], last = items.at(-1);
        if (!first) { event.preventDefault(); this.sidebar.focus(); }
        else if (event.shiftKey && (document.activeElement === first || document.activeElement === this.sidebar)) {
          event.preventDefault(); last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault(); first.focus();
        }
      }
    };
    this.onResize = () => {
      const wasInSidebar = this.sidebar.contains(document.activeElement);
      this.setOpen(false);
      if (!this.media.matches && wasInSidebar) this.toggle.focus();
      else if (this.media.matches && document.activeElement === this.toggle) this.sidebar.focus();
    };
    this.toggle.addEventListener('click', this.onToggle);
    this.el.addEventListener('click', this.onClick);
    document.addEventListener('keydown', this.onKey);
    this.media.addEventListener('change', this.onResize);
    this.setOpen(false);
  },
  updated() { this.setOpen(this.open); },
  setOpen(open, moveFocus = false) {
    this.open = open && !this.media.matches;
    this.sidebar.classList.toggle('hidden', !this.open);
    this.sidebar.classList.toggle('flex', this.open);
    this.backdrop.classList.toggle('hidden', !this.open);
    this.content.inert = this.open;
    this.toggle.setAttribute('aria-expanded', String(this.open));
    if (this.open) {
      this.sidebar.setAttribute('role', 'dialog');
      this.sidebar.setAttribute('aria-modal', 'true');
      if (moveFocus) this.sidebar.querySelector('#dash-navigation-close').focus();
    } else {
      this.sidebar.removeAttribute('role');
      this.sidebar.removeAttribute('aria-modal');
      if (moveFocus && !this.media.matches) this.toggle.focus();
    }
  },
  destroyed() {
    this.content.inert = false;
    this.toggle.removeEventListener('click', this.onToggle);
    this.el.removeEventListener('click', this.onClick);
    document.removeEventListener('keydown', this.onKey);
    this.media.removeEventListener('change', this.onResize);
  },
};
