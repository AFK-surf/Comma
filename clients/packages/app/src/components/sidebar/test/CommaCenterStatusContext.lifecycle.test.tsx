import { render, screen } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import {
  CommaCenterStatusProvider,
  type CommaCenterStatus,
  useCommaCenterStatus,
  usePublishCommaCenterStatus,
} from "../CommaCenterStatusContext";

const completedStatus: CommaCenterStatus = {
  kind: "complete",
  messageId: "assistant-a",
  text: "Reply A",
  timestamp: 1,
};
const typingStatus: CommaCenterStatus = { kind: "typing", timestamp: 2 };

function StatusPublisher({
  owner,
  status,
}: {
  owner: symbol;
  status: CommaCenterStatus;
}) {
  usePublishCommaCenterStatus(owner, status);
  return null;
}

function StatusProbe() {
  const status = useCommaCenterStatus();
  return <output data-testid="status">{status.kind}</output>;
}

function StatusHarness({ children }: { children?: ReactNode }) {
  return (
    <CommaCenterStatusProvider>
      {children}
      <StatusProbe />
    </CommaCenterStatusProvider>
  );
}

describe("CommaCenterStatusProvider owner lifecycle", () => {
  it("returns to idle when a completed status owner unmounts", () => {
    const owner = Symbol("owner-a");
    const rendered = render(
      <StatusHarness>
        <StatusPublisher owner={owner} status={completedStatus} />
      </StatusHarness>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("complete");

    rendered.rerender(<StatusHarness />);

    expect(screen.getByTestId("status")).toHaveTextContent("idle");
  });

  it("does not let owner A cleanup clear owner B's typing status", () => {
    const ownerA = Symbol("owner-a");
    const ownerB = Symbol("owner-b");
    const rendered = render(
      <StatusHarness>
        <StatusPublisher key="a" owner={ownerA} status={completedStatus} />
        <StatusPublisher key="b" owner={ownerB} status={typingStatus} />
      </StatusHarness>
    );
    expect(screen.getByTestId("status")).toHaveTextContent("typing");

    rendered.rerender(
      <StatusHarness>
        <StatusPublisher key="b" owner={ownerB} status={typingStatus} />
      </StatusHarness>
    );

    expect(screen.getByTestId("status")).toHaveTextContent("typing");
  });
});
