// Position against the visible scrollport, not a percentage of the lane:
// a 220px tooltip can cross its edge even on a segment near the lane's middle.
export const ActivityTooltip = {
  mounted() {
    this.hovered = null;
    this.positionTooltip = () => {
      const focused = document.activeElement?.closest('.act-seg');
      const segments = new Set([this.hovered, this.el.contains(focused) ? focused : null]);
      const box = this.el.getBoundingClientRect();
      const left = box.left + this.el.clientLeft;
      const width = Math.min(220, this.el.clientWidth);
      for (const segment of segments) {
        const tip = segment?.querySelector('.act-tip');
        if (!tip) continue;
        const anchor = segment.getBoundingClientRect().left + segment.clientLeft;
        tip.style.width = `${width}px`;
        tip.style.left = `${Math.max(left, Math.min(anchor, left + this.el.clientWidth - width)) - anchor}px`;
      }
    };
    this.over = (event) => {
      this.hovered = event.target.closest('.act-seg');
      this.positionTooltip();
    };
    this.out = (event) => {
      if (this.hovered?.contains(event.relatedTarget)) return;
      this.hovered = null;
      this.positionTooltip();
    };
    this.el.addEventListener('pointerover', this.over);
    this.el.addEventListener('pointerout', this.out);
    this.el.addEventListener('focusin', this.positionTooltip);
    this.el.addEventListener('scroll', this.positionTooltip);
    this.resizeObserver = new ResizeObserver(this.positionTooltip);
    this.resizeObserver.observe(this.el);
  },
  updated() {
    if (!this.el.contains(this.hovered)) this.hovered = null;
    this.positionTooltip();
  },
  destroyed() {
    this.el.removeEventListener('pointerover', this.over);
    this.el.removeEventListener('pointerout', this.out);
    this.el.removeEventListener('focusin', this.positionTooltip);
    this.el.removeEventListener('scroll', this.positionTooltip);
    this.resizeObserver.disconnect();
  },
};
