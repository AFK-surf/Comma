import userEvent from "@testing-library/user-event";
import { act, fireEvent, render, screen } from "@comma/test-utils/render";
import { describe, expect, it, vi } from "vitest";
import { motionDuration } from "../../../tokens/motion";
import { Login, type LoginCopy } from "../Login";

const localizedCopy: LoginCopy = {
  regionLabel: "登录",
  email: {
    title: "欢迎使用 Comma",
    subtitle: "随时随地与智能体协作",
    googleAction: "使用 Google 登录",
    appleAction: "使用 Apple 登录",
    label: "邮箱",
    placeholder: "你的邮箱地址",
    continueAction: "使用邮箱继续",
    invalidError: "请输入有效的邮箱地址。",
  },
  verification: {
    title: "查看你的邮箱",
    instruction: (email) => `请输入发送至 ${email} 的验证码`,
    codeLabel: "验证码",
    codeNotReceived: "没有收到验证码？",
    resendAction: "重新发送",
    resendCountdown: (seconds) => `${seconds} 秒后可重新发送`,
    retryAction: "重试",
    differentEmailAction: "使用其他邮箱",
  },
};

describe("Login", () => {
  it("renders the default email state with a disabled email action", () => {
    render(
      <Login
        mode="email"
        onContinueWithGoogle={() => undefined}
        onContinueWithApple={() => undefined}
      />
    );

    expect(
      screen.getByRole("heading", { name: "Welcome to Comma" })
    ).toBeInTheDocument();
    expect(screen.getByRole("textbox", { name: "Email" })).toHaveAttribute(
      "placeholder",
      "Your email address"
    );
    expect(screen.getByRole("button", { name: "Sign in with Google" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Sign in with Apple" })).toBeEnabled();
    expect(screen.getByRole("button", { name: "Continue with email" })).toBeDisabled();
  });

  it("hides identity-provider buttons that are not wired to a handler", () => {
    const { unmount } = render(
      <Login mode="email" onContinueWithGoogle={() => undefined} />
    );

    expect(screen.getByRole("button", { name: "Sign in with Google" })).toBeEnabled();
    expect(
      screen.queryByRole("button", { name: "Sign in with Apple" })
    ).not.toBeInTheDocument();

    unmount();
    render(<Login mode="email" />);

    expect(
      screen.queryByRole("button", { name: "Sign in with Google" })
    ).not.toBeInTheDocument();
    expect(
      screen.queryByRole("button", { name: "Sign in with Apple" })
    ).not.toBeInTheDocument();
  });

  it("enables email continuation and submits the trimmed value", async () => {
    const user = userEvent.setup();
    const onEmailChange = vi.fn();
    const onContinueWithEmail = vi.fn();

    render(
      <Login
        mode="email"
        onEmailChange={onEmailChange}
        onContinueWithEmail={onContinueWithEmail}
      />
    );

    await user.type(screen.getByRole("textbox", { name: "Email" }), "person@comma.ai");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    expect(onEmailChange).toHaveBeenLastCalledWith("person@comma.ai");
    expect(onContinueWithEmail).toHaveBeenCalledWith("person@comma.ai");
  });

  it("rejects malformed emails with an inline validation message", async () => {
    const user = userEvent.setup();
    const onContinueWithEmail = vi.fn();
    render(<Login mode="email" onContinueWithEmail={onContinueWithEmail} />);

    const input = screen.getByRole("textbox", { name: "Email" });
    await user.type(input, "not-an-email");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    expect(onContinueWithEmail).not.toHaveBeenCalled();
    expect(screen.getByText("Please enter a valid email address.")).toBeVisible();
    expect(input).toHaveAttribute("aria-invalid", "true");
    expect(input).toHaveFocus();

    await user.type(input, "x");

    expect(
      screen.queryByText("Please enter a valid email address.")
    ).not.toBeInTheDocument();

    await user.clear(input);
    await user.type(input, "person@comma.ai");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));

    expect(onContinueWithEmail).toHaveBeenCalledWith("person@comma.ai");
  });

  it("updates a visible validation message when localized copy changes", async () => {
    const user = userEvent.setup();
    const { rerender } = render(
      <Login mode="email" onContinueWithEmail={() => undefined} />
    );

    const input = screen.getByRole("textbox", { name: "Email" });
    await user.type(input, "not-an-email");
    await user.click(screen.getByRole("button", { name: "Continue with email" }));
    expect(screen.getByText("Please enter a valid email address.")).toBeVisible();

    rerender(
      <Login
        copy={localizedCopy}
        mode="email"
        email="not-an-email"
        onContinueWithEmail={() => undefined}
      />
    );

    expect(screen.getByText("请输入有效的邮箱地址。")).toBeVisible();
    expect(
      screen.queryByText("Please enter a valid email address.")
    ).not.toBeInTheDocument();
  });

  it("renders the awaiting-code state as one accessible input and six cells", () => {
    const { container } = render(
      <Login
        mode="verification"
        email="person@comma.ai"
        resendSeconds={60}
        onResend={() => undefined}
      />
    );

    expect(
      screen.getByRole("heading", { name: "Check your email" })
    ).toBeInTheDocument();
    expect(screen.getByText("Enter the code sent to person@comma.ai")).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Verification code" })).toHaveValue("");
    expect(container.querySelectorAll("[data-login-code-cell]")).toHaveLength(6);
    expect(screen.getByText("Resend in 60s")).toBeInTheDocument();
  });

  it("only renders resend recovery when a resend handler exists", () => {
    const { rerender } = render(
      <Login mode="verification" email="person@comma.ai" resendSeconds={0} />
    );

    expect(screen.queryByText("Didn’t receive the code?")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Resend" })).not.toBeInTheDocument();

    rerender(
      <Login
        mode="verification"
        email="person@comma.ai"
        resendSeconds={0}
        onResend={() => undefined}
      />
    );

    expect(screen.getByText("Didn’t receive the code?")).toBeVisible();
    expect(screen.getByRole("button", { name: "Resend" })).toBeEnabled();
  });

  it("renders supplied localized copy for visible and accessible login text", async () => {
    const user = userEvent.setup();
    const { unmount } = render(
      <Login
        copy={localizedCopy}
        mode="email"
        onContinueWithGoogle={() => undefined}
        onContinueWithEmail={() => undefined}
      />
    );

    expect(screen.getByRole("region", { name: "登录" })).toBeVisible();
    expect(screen.getByRole("heading", { name: "欢迎使用 Comma" })).toBeVisible();
    expect(screen.getByRole("button", { name: "使用 Google 登录" })).toBeEnabled();
    const emailInput = screen.getByRole("textbox", { name: "邮箱" });
    expect(emailInput).toHaveAttribute("placeholder", "你的邮箱地址");
    await user.type(emailInput, "not-an-email");
    await user.click(screen.getByRole("button", { name: "使用邮箱继续" }));
    expect(screen.getByText("请输入有效的邮箱地址。")).toBeVisible();

    unmount();
    render(
      <Login
        copy={localizedCopy}
        mode="verification"
        email="person@comma.ai"
        resendSeconds={60}
        onResend={() => undefined}
      />
    );

    expect(screen.getByRole("heading", { name: "查看你的邮箱" })).toBeVisible();
    expect(screen.getByText("请输入发送至 person@comma.ai 的验证码")).toBeVisible();
    expect(screen.getByRole("textbox", { name: "验证码" })).toBeEnabled();
    expect(screen.getByText("60 秒后可重新发送")).toBeVisible();
    expect(screen.getByRole("button", { name: "使用其他邮箱" })).toBeEnabled();
  });

  it("normalizes entered codes and reports completion once six characters exist", async () => {
    const user = userEvent.setup();
    const onCodeChange = vi.fn();
    const onCodeComplete = vi.fn();
    const { container } = render(
      <Login
        mode="verification"
        email="person@comma.ai"
        onCodeChange={onCodeChange}
        onCodeComplete={onCodeComplete}
      />
    );

    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    await user.type(input, "1e-d3f1");

    expect(input).toHaveValue("1ED3F1");
    expect(onCodeChange).toHaveBeenLastCalledWith("1ED3F1");
    expect(onCodeComplete).toHaveBeenCalledOnce();
    expect(onCodeComplete).toHaveBeenCalledWith("1ED3F1");
    expect(
      Array.from(
        container.querySelectorAll<HTMLElement>("[data-login-code-cell]"),
        (cell) => cell.textContent
      )
    ).toEqual(["1", "E", "D", "3", "F", "1"]);
  });

  it("shows a caret in the active cell only while the code input is focused", () => {
    const { container } = render(<Login mode="verification" email="person@comma.ai" />);
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const cells = container.querySelectorAll("[data-login-code-cell]");

    expect(container.querySelector("[data-login-code-caret]")).toBeNull();

    fireEvent.focus(input);

    expect(cells[0]!.querySelector("[data-login-code-caret]")).toBeInTheDocument();
    expect(container.querySelectorAll("[data-login-code-caret]")).toHaveLength(1);

    fireEvent.change(input, { target: { value: "1E" } });

    expect(cells[2]!.querySelector("[data-login-code-caret]")).toBeInTheDocument();
    expect(container.querySelectorAll("[data-login-code-caret]")).toHaveLength(1);

    fireEvent.change(input, { target: { value: "1ED3F1" } });

    expect(container.querySelector("[data-login-code-caret]")).toBeNull();

    fireEvent.change(input, { target: { value: "1ED3F" } });
    fireEvent.blur(input);

    expect(container.querySelector("[data-login-code-caret]")).toBeNull();
  });

  it("styles empty, filled, and active verification cells", () => {
    const { container } = render(
      <Login mode="verification" email="person@comma.ai" defaultCode="1E" />
    );
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const cells = Array.from(
      container.querySelectorAll<HTMLElement>("[data-login-code-cell]")
    );

    expect(cells[0]).toHaveAttribute("data-filled", "true");
    expect(cells[0]).toHaveAttribute("data-active", "false");
    expect(cells[0]).toHaveClass("bg-disabled", "text-quaternary", "shadow-none");
    expect(cells[0]).not.toHaveClass("bg-primary");
    expect(cells[0]).not.toHaveClass("shadow-xs");

    expect(cells[1]).toHaveAttribute("data-filled", "true");
    expect(cells[1]).toHaveClass("bg-disabled", "text-quaternary", "shadow-none");

    expect(cells[2]).toHaveAttribute("data-filled", "false");
    expect(cells[2]).toHaveAttribute("data-active", "false");
    expect(cells[2]).toHaveClass("bg-primary", "text-primary", "shadow-xs");
    expect(cells[2]).not.toHaveClass("bg-disabled");

    fireEvent.focus(input);
    act(() => {
      input.setSelectionRange(2, 2);
      fireEvent.select(input);
    });

    expect(cells[2]).toHaveAttribute("data-active", "true");
    expect(cells[2]).toHaveClass("bg-primary", "text-primary", "shadow-xs");

    act(() => {
      input.setSelectionRange(0, 0);
      fireEvent.select(input);
    });

    // A caret placed before a filled character selects that whole cell.
    expect(input.selectionStart).toBe(0);
    expect(input.selectionEnd).toBe(1);
    expect(cells[0]).toHaveAttribute("data-active", "true");
    expect(cells[0]).toHaveAttribute("data-filled", "true");
    expect(cells[0]).toHaveClass("bg-primary", "text-primary", "shadow-xs");
    expect(cells[0]).not.toHaveClass("bg-disabled");
    expect(cells[0]).not.toHaveClass("shadow-none");
    expect(cells[0]!.querySelector("[data-login-code-caret]")).toBeNull();
    expect(cells[1]).toHaveAttribute("data-active", "false");
    expect(cells[1]).toHaveClass("bg-disabled", "text-quaternary", "shadow-none");
  });

  it("moves the whole-cell selection with the arrow keys and replaces the selected character", () => {
    const { container } = render(
      <Login mode="verification" email="person@comma.ai" defaultCode="12345" />
    );
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const cells = container.querySelectorAll<HTMLElement>("[data-login-code-cell]");

    act(() => {
      input.focus();
      input.setSelectionRange(1, 1);
      fireEvent.select(input);
    });
    expect([input.selectionStart, input.selectionEnd]).toEqual([1, 2]);
    expect(cells[1]).toHaveAttribute("data-active", "true");

    fireEvent.keyDown(input, { key: "ArrowRight" });
    expect([input.selectionStart, input.selectionEnd]).toEqual([2, 3]);
    expect(cells[1]).toHaveAttribute("data-active", "false");
    expect(cells[2]).toHaveAttribute("data-active", "true");

    fireEvent.keyDown(input, { key: "ArrowLeft" });
    expect([input.selectionStart, input.selectionEnd]).toEqual([1, 2]);
    expect(cells[1]).toHaveAttribute("data-active", "true");

    fireEvent.keyDown(input, { key: "End" });
    expect([input.selectionStart, input.selectionEnd]).toEqual([5, 5]);
    expect(cells[5]).toHaveAttribute("data-active", "true");
    expect(cells[5]!.querySelector("[data-login-code-caret]")).toBeInTheDocument();

    fireEvent.keyDown(input, { key: "Home" });
    expect([input.selectionStart, input.selectionEnd]).toEqual([0, 1]);

    // Typing over the selected cell replaces it and selects the next cell.
    // The browser leaves the caret after the typed character; the value is
    // written through the native setter so React sees the input event.
    const setValue = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )!.set!;
    act(() => {
      setValue.call(input, "92345");
      input.setSelectionRange(1, 1);
      fireEvent.input(input);
    });
    expect(input).toHaveValue("92345");
    expect([input.selectionStart, input.selectionEnd]).toEqual([1, 2]);
    expect(cells[0]).toHaveTextContent("9");
    expect(cells[1]).toHaveAttribute("data-active", "true");
  });

  it("ignores invalid printable input while a filled cell is selected", async () => {
    const user = userEvent.setup();
    render(<Login mode="verification" email="person@comma.ai" defaultCode="12345" />);
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });

    act(() => {
      input.focus();
      input.setSelectionRange(2, 2);
      fireEvent.select(input);
    });
    expect([input.selectionStart, input.selectionEnd]).toEqual([2, 3]);

    await user.keyboard("-");

    expect(input).toHaveValue("12345");
    expect([input.selectionStart, input.selectionEnd]).toEqual([2, 3]);

    await user.keyboard("9");

    expect(input).toHaveValue("12945");
    expect([input.selectionStart, input.selectionEnd]).toEqual([3, 4]);
  });

  it("hides the caret while the code input is disabled", () => {
    const { container, rerender } = render(
      <Login mode="verification" email="person@comma.ai" />
    );
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });

    fireEvent.focus(input);
    expect(container.querySelector("[data-login-code-caret]")).toBeInTheDocument();

    rerender(<Login mode="verification" email="person@comma.ai" disabled />);

    expect(container.querySelector("[data-login-code-caret]")).toBeNull();
  });

  it("presses and releases only the cell receiving a typed character", () => {
    const { container } = render(<Login mode="verification" email="person@comma.ai" />);
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const cells = Array.from(
      container.querySelectorAll<HTMLElement>("[data-login-code-cell]")
    );

    fireEvent.focus(input);
    input.setSelectionRange(0, 0);
    fireEvent.keyDown(input, { code: "Digit1", key: "1" });

    expect(cells[0]).toHaveAttribute("data-pressed", "true");
    for (const cell of cells.slice(1)) {
      expect(cell).toHaveAttribute("data-pressed", "false");
    }

    fireEvent.change(input, { target: { value: "1" } });
    fireEvent.keyUp(input, { code: "Digit1", key: "1" });

    expect(cells[0]).toHaveTextContent("1");
    expect(cells[0]).toHaveAttribute("data-pressed", "false");

    input.setSelectionRange(1, 1);
    fireEvent.keyDown(input, { code: "Digit2", key: "2" });

    expect(cells[0]).toHaveAttribute("data-pressed", "false");
    expect(cells[1]).toHaveAttribute("data-pressed", "true");

    fireEvent.change(input, { target: { value: "12" } });
    input.setSelectionRange(2, 2);
    fireEvent.keyDown(input, { code: "Digit3", key: "3" });
    fireEvent.keyUp(input, { code: "Digit2", key: "2" });

    expect(cells[1]).toHaveAttribute("data-pressed", "false");
    expect(cells[2]).toHaveAttribute("data-pressed", "true");

    fireEvent.keyUp(input, { code: "Digit3", key: "3" });

    expect(cells[2]).toHaveAttribute("data-pressed", "false");

    fireEvent.keyDown(input, { code: "Digit3", key: "3" });
    fireEvent.blur(input);

    expect(cells[2]).toHaveAttribute("data-pressed", "false");
  });

  it("ignores non-entry keys and only blocks new characters at the full input end", () => {
    const { container } = render(
      <Login mode="verification" email="person@comma.ai" defaultCode="123456" />
    );
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const cells = container.querySelectorAll<HTMLElement>("[data-login-code-cell]");

    fireEvent.focus(input);
    input.setSelectionRange(6, 6);
    fireEvent.keyDown(input, { key: "Backspace" });
    fireEvent.keyDown(input, { key: "v", ctrlKey: true });
    fireEvent.keyDown(input, { key: "7" });

    for (const cell of cells) {
      expect(cell).toHaveAttribute("data-pressed", "false");
    }

    input.setSelectionRange(3, 3);
    fireEvent.keyDown(input, { key: "9" });

    expect(cells[3]).toHaveAttribute("data-pressed", "true");
  });

  it("releases a pressed code cell when verification becomes disabled", () => {
    const { container, rerender } = render(
      <Login mode="verification" email="person@comma.ai" />
    );
    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    const firstCell = container.querySelector("[data-login-code-cell]");

    fireEvent.focus(input);
    input.setSelectionRange(0, 0);
    fireEvent.keyDown(input, { key: "1" });
    expect(firstCell).toHaveAttribute("data-pressed", "true");

    rerender(<Login mode="verification" email="person@comma.ai" disabled />);

    expect(firstCell).toHaveAttribute("data-pressed", "false");
  });

  it("normalizes a formatted pasted code before applying the six-character cap", async () => {
    const user = userEvent.setup();
    const onCodeChange = vi.fn();
    const onCodeComplete = vi.fn();

    const { container } = render(
      <Login
        mode="verification"
        email="person@comma.ai"
        onCodeChange={onCodeChange}
        onCodeComplete={onCodeComplete}
      />
    );

    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    await user.click(input);
    await user.paste("123-456-789");

    expect(input).not.toHaveAttribute("maxlength");
    expect(input).toHaveValue("123456");
    expect(onCodeChange).toHaveBeenLastCalledWith("123456");
    expect(onCodeComplete).toHaveBeenCalledOnce();
    expect(onCodeComplete).toHaveBeenCalledWith("123456");
    for (const cell of container.querySelectorAll("[data-login-code-cell]")) {
      expect(cell).toHaveAttribute("data-pressed", "false");
    }
  });

  it("pops newly filled cells when a code is pasted", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(
        <Login mode="verification" email="person@comma.ai" />
      );
      const input = screen.getByRole<HTMLInputElement>("textbox", {
        name: "Verification code",
      });

      fireEvent.focus(input);
      fireEvent.change(input, { target: { value: "1ED3F1" } });

      const cells = container.querySelectorAll("[data-login-code-cell]");
      for (const cell of cells) {
        expect(cell).toHaveAttribute("data-pop", "true");
        expect(cell).toHaveAttribute("data-filled", "true");
      }

      act(() => {
        vi.advanceTimersByTime(motionDuration.feedbackIn);
      });

      for (const cell of cells) {
        expect(cell).toHaveAttribute("data-pop", "false");
      }
    } finally {
      vi.useRealTimers();
    }
  });

  it("clears pasted-cell pops after a deletion interrupts the feedback window", () => {
    vi.useFakeTimers();
    try {
      const { container } = render(
        <Login mode="verification" email="person@comma.ai" />
      );
      const input = screen.getByRole<HTMLInputElement>("textbox", {
        name: "Verification code",
      });

      fireEvent.focus(input);
      fireEvent.change(input, { target: { value: "1ED3F1" } });

      const cells = container.querySelectorAll("[data-login-code-cell]");
      for (const cell of cells) {
        expect(cell).toHaveAttribute("data-pop", "true");
      }

      act(() => {
        vi.advanceTimersByTime(motionDuration.feedbackIn / 2);
      });
      fireEvent.change(input, { target: { value: "1ED3F" } });
      act(() => {
        vi.advanceTimersByTime(motionDuration.feedbackIn);
      });

      for (const cell of cells) {
        expect(cell).toHaveAttribute("data-pop", "false");
      }
    } finally {
      vi.useRealTimers();
    }
  });

  it("renders the invalid-code state and exposes recovery actions", async () => {
    const user = userEvent.setup();
    const onRetry = vi.fn();
    const onUseDifferentEmail = vi.fn();
    const { container, rerender } = render(
      <Login
        mode="verification"
        email="person@comma.ai"
        defaultCode="1ED3F1"
        onRetry={onRetry}
        onUseDifferentEmail={onUseDifferentEmail}
      />
    );
    const codeGroup = container.querySelector("[data-login-code-group]");

    expect(codeGroup).toHaveAttribute("data-invalid", "false");

    rerender(
      <Login
        mode="verification"
        email="person@comma.ai"
        defaultCode="1ED3F1"
        errorMessage="Please enter a valid verification code"
        onRetry={onRetry}
        onUseDifferentEmail={onUseDifferentEmail}
      />
    );

    expect(screen.getByRole("alert")).toHaveTextContent(
      "Please enter a valid verification code"
    );
    expect(screen.getByRole("textbox", { name: "Verification code" })).toHaveAttribute(
      "aria-invalid",
      "true"
    );
    expect(codeGroup).toHaveAttribute("data-invalid", "true");
    expect(container.querySelectorAll("[data-login-code-shake]")).toHaveLength(6);
    for (const cell of container.querySelectorAll("[data-login-code-cell]")) {
      expect(cell).toHaveClass("border-error");
    }

    await user.click(screen.getByRole("button", { name: "Try again" }));
    expect(onRetry).toHaveBeenCalledOnce();

    await user.click(screen.getByRole("button", { name: "Use a different email" }));

    expect(onUseDifferentEmail).toHaveBeenCalledOnce();
  });

  it("prevents verification input and callbacks while disabled", async () => {
    const user = userEvent.setup();
    const onCodeChange = vi.fn();
    const onCodeComplete = vi.fn();

    render(
      <Login
        mode="verification"
        email="person@comma.ai"
        disabled
        onCodeChange={onCodeChange}
        onCodeComplete={onCodeComplete}
      />
    );

    const input = screen.getByRole<HTMLInputElement>("textbox", {
      name: "Verification code",
    });
    expect(input).toBeDisabled();

    await user.type(input, "1ED3F1");

    expect(input).toHaveValue("");
    expect(onCodeChange).not.toHaveBeenCalled();
    expect(onCodeComplete).not.toHaveBeenCalled();
  });

  it("keeps login inputs visually unchanged while focused", async () => {
    const user = userEvent.setup();
    const { container, rerender } = render(<Login mode="email" />);
    const emailInput = screen.getByRole("textbox", { name: "Email" });

    await user.click(emailInput);

    expect(emailInput.parentElement).not.toHaveClass(
      "ring-2",
      "shadow-focus-brand-shadow-xs"
    );

    rerender(<Login mode="verification" email="person@comma.ai" />);
    await user.click(screen.getByRole("textbox", { name: "Verification code" }));

    for (const cell of container.querySelectorAll("[data-login-code-cell]")) {
      expect(cell).toHaveClass("border-primary");
      expect(cell).not.toHaveClass("border-brand", "shadow-focus-brand-shadow-xs");
    }
  });

  it("cross-fades between steps, keeping the leaving step as an inert ghost", () => {
    const { container, rerender } = render(
      <Login mode="email" onContinueWithGoogle={() => undefined} />
    );

    expect(container.querySelectorAll("[data-stage-state]")).toHaveLength(1);
    expect(container.querySelector('[data-stage-state="enter"]')).toBeInTheDocument();

    rerender(<Login mode="verification" email="person@comma.ai" />);

    const ghost = container.querySelector('[data-stage-state="exit"]');
    expect(container.querySelectorAll("[data-stage-state]")).toHaveLength(2);
    expect(ghost).toHaveAttribute("aria-hidden", "true");
    expect(ghost).toHaveAttribute("inert");
    // The ghost keeps the old step visible for the exit animation but out of
    // the accessibility tree, so queries resolve only the entering step.
    expect(
      screen.queryByRole("button", { name: "Sign in with Google" })
    ).not.toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Check your email" })).toBeVisible();

    fireEvent.animationEnd(ghost!);

    expect(container.querySelectorAll("[data-stage-state]")).toHaveLength(1);
    expect(container.querySelector('[data-stage-state="exit"]')).toBeNull();
  });

  it("replaces the ghost when steps flip again mid-transition", () => {
    const { container, rerender } = render(
      <Login mode="email" onContinueWithGoogle={() => undefined} />
    );

    rerender(<Login mode="verification" email="person@comma.ai" />);
    rerender(<Login mode="email" onContinueWithGoogle={() => undefined} />);

    const stages = container.querySelectorAll("[data-stage-state]");
    expect(stages).toHaveLength(2);
    expect(container.querySelector('[data-stage-state="exit"]')).toHaveTextContent(
      "Check your email"
    );
    expect(screen.getByRole("heading", { name: "Welcome to Comma" })).toBeVisible();
  });
});
