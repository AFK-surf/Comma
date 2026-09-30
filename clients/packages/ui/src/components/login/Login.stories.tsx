import { useEffect, useState } from "react";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { motionDuration } from "../../tokens/motion";
import { Login } from "./Login";

const meta = {
  title: "App components/Login",
  component: Login,
  parameters: {
    layout: "centered",
  },
  decorators: [
    (Story) => (
      <div className="px-xl">
        <Story />
      </div>
    ),
  ],
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const noop = () => undefined;

export const Default: Story = {
  args: { mode: "email" },
  render: () => (
    <Login mode="email" onContinueWithGoogle={noop} onContinueWithApple={noop} />
  ),
};

export const EmailEntered: Story = {
  args: { mode: "email", defaultEmail: "zanwei.guo@outlook.com" },
  render: () => (
    <Login
      mode="email"
      defaultEmail="zanwei.guo@outlook.com"
      onContinueWithGoogle={noop}
      onContinueWithApple={noop}
    />
  ),
};

export const EmailOnly: Story = {
  args: { mode: "email" },
  render: () => <Login mode="email" />,
};

const StepTransitionDemo = () => {
  const [mode, setMode] = useState<"email" | "verification">("email");

  return mode === "verification" ? (
    <Login
      mode="verification"
      email="zanwei.guo@outlook.com"
      resendSeconds={0}
      onUseDifferentEmail={() => setMode("email")}
    />
  ) : (
    <Login
      mode="email"
      defaultEmail="zanwei.guo@outlook.com"
      onContinueWithGoogle={noop}
      onContinueWithApple={noop}
      onContinueWithEmail={() => setMode("verification")}
    />
  );
};

/** Drive the email → verification cross-fade with the real stage motion. */
export const StepTransition: Story = {
  args: { mode: "email" },
  render: () => <StepTransitionDemo />,
};

export const AwaitingCode: Story = {
  args: { mode: "verification", email: "zanwei.guo@outlook.com" },
  render: () => <Login mode="verification" email="zanwei.guo@outlook.com" />,
};

export const CodeEntered: Story = {
  args: {
    mode: "verification",
    email: "zanwei.guo@outlook.com",
    defaultCode: "1ED3F1",
  },
  render: () => (
    <Login mode="verification" email="zanwei.guo@outlook.com" defaultCode="1ED3F1" />
  ),
};

export const Error: Story = {
  args: {
    mode: "verification",
    email: "zanwei.guo@outlook.com",
    defaultCode: "1ED3F1",
    errorMessage: "Please enter a valid verification code",
  },
  render: () => (
    <Login
      mode="verification"
      email="zanwei.guo@outlook.com"
      defaultCode="1ED3F1"
      errorMessage="Please enter a valid verification code"
    />
  ),
};

const INVALID_CODE_ERROR = "Please enter a valid verification code";

const ErrorAnimationDemo = () => {
  const [errorMessage, setErrorMessage] = useState<string | undefined>();

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setErrorMessage(INVALID_CODE_ERROR);
    }, motionDuration.loginStageEnter);
    return () => window.clearTimeout(timer);
  }, []);

  return (
    <Login
      mode="verification"
      email="zanwei.guo@outlook.com"
      defaultCode="1ED3F1"
      {...(errorMessage ? { errorMessage } : {})}
    />
  );
};

/** Play the invalid-code shake after the stage enter settles. */
export const ErrorAnimation: Story = {
  args: {
    mode: "verification",
    email: "zanwei.guo@outlook.com",
    defaultCode: "1ED3F1",
  },
  render: () => <ErrorAnimationDemo />,
};
