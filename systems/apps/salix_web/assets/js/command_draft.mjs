// Guard both LiveView navigation and the full-page organization switcher.
export const CommandDraft = {
  mounted() {
    this.dirty = false;
    this.epoch = this.el.dataset.epoch;
    this.onInput = (event) => {
      if (!event?.target || event.target.closest('form:not(#slack-app-picker)')) this.dirty = true;
    };
    this.onDialogCancel = (event) => {
      event.preventDefault();
      if (this.el.dataset.busy === 'true') return;
      if (this.dirty && !window.confirm('Discard unsaved command changes? Cancel to keep editing.')) return;
      this.dirty = false;
      this.pushEvent('cancel', {});
    };
    this.onLeave = (event) => {
      if (!this.dirty && this.el.dataset.busy !== 'true') return;
      event.preventDefault();
      event.returnValue = '';
    };
    this.onClick = (event) => {
      const target = event.target.closest('a[href], button[phx-click]');
      if (!target) return;
      if (!target.matches('a[href]') && !this.el.contains(target)) return;
      if (this.el.dataset.busy === 'true') {
        event.preventDefault();
        event.stopImmediatePropagation();
        return;
      }
      if (['open-credentials', 'back-editor', 'separator'].includes(target.getAttribute?.('phx-click'))) return;
      if (target.matches('a[href]') && (target.getAttribute?.('target') === '_blank' || event.metaKey || event.ctrlKey)) return;
      if (!this.dirty) return;
      if (!window.confirm('Discard unsaved command changes? Cancel to keep editing.')) {
        event.preventDefault();
        event.stopImmediatePropagation();
      } else if (target.matches('a[href]')) {
        this.dirty = false;
      }
    };
    this.el.addEventListener('input', this.onInput);
    this.el.addEventListener('change', this.onInput);
    window.addEventListener('beforeunload', this.onLeave);
    window.addEventListener('click', this.onClick, true);
    this.updated();
  },
  updated() {
    const dialog = this.el.querySelector('dialog');
    if (dialog && dialog !== this.dialog) {
      this.dialog?.removeEventListener('cancel', this.onDialogCancel);
      this.dialog = dialog;
      dialog.addEventListener('cancel', this.onDialogCancel);
    }
    if (dialog?.dataset.open === 'true' && !dialog.open) dialog.showModal();
    if (dialog?.dataset.open === 'false' && dialog.open) dialog.close();
    if (this.epoch !== this.el.dataset.epoch) {
      this.epoch = this.el.dataset.epoch;
      this.dirty = false;
      if (this.el.dataset.draft === 'true') {
        const input = this.el.querySelector('input[name="entry[command]"]');
        input?.focus();
        input?.scrollIntoView({ block: 'center' });
      }
    }
    if (this.el.dataset.draft === 'true') this.dirty = true;
  },
  destroyed() {
    this.dialog?.removeEventListener('cancel', this.onDialogCancel);
    this.el.removeEventListener('input', this.onInput);
    this.el.removeEventListener('change', this.onInput);
    window.removeEventListener('beforeunload', this.onLeave);
    window.removeEventListener('click', this.onClick, true);
  },
};
