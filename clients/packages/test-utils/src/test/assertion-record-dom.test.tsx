import { deepEqual, notDeepEqual } from "node:assert/strict";
import { expect, test } from "vitest";
import { observeAssertions } from "../assertion-record";

function capture(value: string) {
  const events: string[] = [];
  const stop = observeAssertions((_, event) => events.push(event));
  const textarea = document.createElement("textarea");
  const select = document.createElement("select");
  select.multiple = true;
  select.innerHTML =
    '<option value="1">One</option><option value="999">Another</option>';
  textarea.value = value;
  select.value = value;
  document.body.append(textarea, select);
  try {
    expect(textarea).toBeInTheDocument();
    expect(select).toBeInTheDocument();
  } finally {
    stop();
    textarea.remove();
    select.remove();
  }
  return events;
}

test("records live form values that do not change the element's markup", () => {
  const first = capture("1");
  notDeepEqual(first, capture("999"));
  deepEqual(first, capture("1"));
});
