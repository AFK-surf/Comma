import test from 'node:test';
import assert from 'node:assert/strict';
import { CommandDraft } from '../../assets/js/command_draft.mjs';

function harness() {
  const listeners = new Map();
  const inputs = new Map();
  let confirms = 0;
  globalThis.window = {
    addEventListener: (key, fn) => listeners.set(key, fn),
    removeEventListener: (key) => listeners.delete(key),
    confirm: () => { confirms++; return false; },
  };
  const el = {
    dataset: { epoch: '0', busy: 'false', draft: 'false' },
    addEventListener: (key, fn) => inputs.set(key, fn),
    removeEventListener: (key) => inputs.delete(key),
    contains: () => true,
    querySelector: () => null,
  };
  const hook = { ...CommandDraft, el };
  hook.mounted();
  return { hook, listeners, inputs, confirms: () => confirms };
}
function click(listeners, link = true) {
  const event = {
    target: { closest: () => ({ matches: () => link }) },
    prevented: false,
    stopped: false,
    preventDefault() { this.prevented = true; },
    stopImmediatePropagation() { this.stopped = true; },
  };
  listeners.get('click')(event);
  return event;
}

test('dirty drafts guard organization links, App navigation and replacement actions', () => {
  const h = harness();
  assert.equal(click(h.listeners).prevented, false);
  h.inputs.get('input')();
  assert.equal(click(h.listeners).prevented, true);
  assert.equal(click(h.listeners, false).prevented, true);
  assert.equal(h.confirms(), 2);
  const unload = { preventDefault() { this.prevented = true; } };
  h.listeners.get('beforeunload')(unload);
  assert.equal(unload.prevented, true);
  window.confirm = () => true;
  assert.equal(click(h.listeners).prevented, false);
  assert.equal(h.hook.dirty, false);
  h.hook.destroyed();
  assert.equal(h.listeners.size, 0);
  assert.equal(h.inputs.size, 0);
});

test('server copied drafts are dirty, failed saves retain protection, successful saves reset it', () => {
  const h = harness();
  h.hook.el.dataset.draft = 'true';
  h.hook.updated();
  assert.equal(click(h.listeners).prevented, true);
  h.hook.el.dataset.busy = 'true';
  assert.equal(click(h.listeners).stopped, true);
  h.hook.el.dataset.busy = 'false';
  h.hook.updated();
  assert.equal(h.hook.dirty, true);
  h.hook.el.dataset.epoch = '1';
  h.hook.el.dataset.draft = 'false';
  h.hook.updated();
  assert.equal(h.hook.dirty, false);
  h.hook.destroyed();
});
