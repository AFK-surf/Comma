import { deepEqual, notDeepEqual } from "node:assert/strict";
import { getQueriesForElement } from "@testing-library/react";
import { test } from "vitest";
import { observeAssertions, observedQueries } from "../assertion-record";

function capture(label: string) {
  const events: string[] = [];
  const stop = observeAssertions((_, event) => events.push(event));
  const button = document.createElement("button");
  button.textContent = label;
  document.body.append(button);
  try {
    const queries = observedQueries(
      getQueriesForElement(document.body),
      (element) => element.textContent ?? ""
    );
    queries.getByRole("button");
  } finally {
    stop();
    button.remove();
  }
  return events;
}

test("records what a testing-library query found", () => {
  const first = capture("Send");
  notDeepEqual(first, capture("Delete"));
  deepEqual(first, capture("Send"));
});
