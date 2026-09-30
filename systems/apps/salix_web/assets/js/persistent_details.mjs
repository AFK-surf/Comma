// Form patches update children without discarding the user's disclosure state.
export const PersistentDetails = {
  beforeUpdate() {
    this.wasOpen = this.el.open;
  },
  updated() {
    this.el.open = this.wasOpen || this.el.dataset.forceOpen === "true";
  },
};
