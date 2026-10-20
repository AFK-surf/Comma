import { initializeCommaI18n } from "@comma/i18n";
import { flush } from "@comma/test-utils/fake-clock";
import { render, screen } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { beforeAll, describe, expect, it, vi } from "vitest";

/** A user whose waits run on the fake clock. */
const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
import { StationCard } from "../StationCard";

beforeAll(() => {
  initializeCommaI18n(["en"]);
});

const optionsCard = {
  options: [
    { detail: "Keeps today's totals", label: "Count by day" },
    { label: "Ship it", recommended: true },
  ],
  type: "options",
};

describe("StationCard", () => {
  it("answers with the option picked, the agent's recommendation marked", async () => {
    let finish: (() => void) | undefined;
    const onAnswer = vi.fn(() => new Promise<void>((resolve) => (finish = resolve)));
    render(
      <StationCard
        assignee="You decide"
        card={optionsCard}
        decision={{ resolved: false }}
        onAnswer={onAnswer}
        onReply={vi.fn()}
      />
    );

    expect(screen.getByText("You decide")).toBeInTheDocument();
    const recommended = screen.getByRole("button", { name: /Ship it/ });
    expect(recommended).toHaveTextContent("Recommended");
    await user().click(screen.getByRole("button", { name: /Count by day/ }));

    expect(onAnswer).toHaveBeenCalledWith("Count by day");
    // One answer at a time.
    expect(recommended).toBeDisabled();
    finish?.();
    await flush();
    expect(recommended).toBeEnabled();
  });

  it("sends what is written in a text card", async () => {
    const onReply = vi.fn(async () => undefined);
    render(
      <StationCard
        card={{ placeholder: "sk_test_…", type: "text" }}
        onAnswer={vi.fn()}
        onReply={onReply}
      />
    );

    await user().type(screen.getByPlaceholderText("sk_test_…"), "  sk_test_42 ");
    await user().click(screen.getByRole("button", { name: "Send" }));

    expect(onReply).toHaveBeenCalledWith("sk_test_42");
    await flush();
    expect(screen.getByRole("textbox", { name: "Your answer" })).toHaveValue("");
  });

  it("shows how an answered card ended and takes no more answers", () => {
    render(
      <StationCard
        card={optionsCard}
        decision={{
          resolved: true,
          text: "Lin chose “Ship it”",
        }}
        onAnswer={vi.fn()}
        onReply={vi.fn()}
      />
    );

    expect(screen.getByTestId("station-card-outcome")).toHaveTextContent(
      "Lin chose “Ship it”"
    );
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("says a withdrawn or closed card no longer waits", () => {
    render(
      <StationCard
        card={optionsCard}
        decision={{ resolved: true }}
        onAnswer={vi.fn()}
        onReply={vi.fn()}
      />
    );

    expect(screen.getByTestId("station-card-outcome")).toHaveTextContent(
      "No longer waiting for an answer"
    );
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("shows the station's refusal and lets the person try again", async () => {
    const onAnswer = vi.fn(async () => {
      throw new Error("Someone answered it already.");
    });
    render(<StationCard card={optionsCard} onAnswer={onAnswer} onReply={vi.fn()} />);

    await user().click(screen.getByRole("button", { name: /Ship it/ }));

    await flush();
    expect(screen.getByRole("alert")).toHaveTextContent("Someone answered it already.");
    expect(screen.getByRole("button", { name: /Ship it/ })).toBeEnabled();
  });
});
