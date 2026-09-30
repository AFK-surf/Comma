import {
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type ChangeEvent,
  type FormEvent,
  type KeyboardEvent,
  type PointerEvent,
  type SyntheticEvent,
} from "react";
import { Button } from "../Button";
import { InputBase } from "../input/InputBase";
import { InputField } from "../input";
import { Text } from "../Text";
import { motionDuration } from "../../tokens/motion";
import { cx, isImeKeyEvent } from "../utils";
import { LoadingCircleIcon } from "../icons";
import { AppleBrandMark, CommaMark, GoogleBrandMark } from "./BrandMarks";
import { useErrorShake } from "./useErrorShake";

export type LoginCopy = {
  regionLabel: string;
  email: {
    title: string;
    subtitle: string;
    googleAction: string;
    appleAction: string;
    label: string;
    placeholder: string;
    continueAction: string;
    invalidError: string;
  };
  verification: {
    title: string;
    instruction: (email: string) => string;
    codeLabel: string;
    codeNotReceived: string;
    resendAction: string;
    resendCountdown: (seconds: number) => string;
    retryAction: string;
    differentEmailAction: string;
  };
};

const DEFAULT_LOGIN_COPY: LoginCopy = {
  regionLabel: "Comma login",
  email: {
    title: "Welcome to Comma",
    subtitle: "Work anywhere with your agents",
    googleAction: "Sign in with Google",
    appleAction: "Sign in with Apple",
    label: "Email",
    placeholder: "Your email address",
    continueAction: "Continue with email",
    invalidError: "Please enter a valid email address.",
  },
  verification: {
    title: "Check your email",
    instruction: (email) => `Enter the code sent to ${email}`,
    codeLabel: "Verification code",
    codeNotReceived: "Didn’t receive the code?",
    resendAction: "Resend",
    resendCountdown: (seconds) => `Resend in ${seconds}s`,
    retryAction: "Try again",
    differentEmailAction: "Use a different email",
  },
};

type LoginCommonProps = {
  className?: string;
  copy?: LoginCopy;
  disabled?: boolean;
};

export type LoginEmailProps = LoginCommonProps & {
  mode: "email";
  email?: string;
  defaultEmail?: string;
  onEmailChange?: (email: string) => void;
  onContinueWithEmail?: (email: string) => void;
  googlePending?: boolean;
  googleErrorMessage?: string;
  onContinueWithGoogle?: () => void;
  onContinueWithApple?: () => void;
};

export type LoginVerificationProps = LoginCommonProps & {
  mode: "verification";
  email: string;
  code?: string;
  defaultCode?: string;
  errorMessage?: string;
  resendSeconds?: number;
  onCodeChange?: (code: string) => void;
  onCodeComplete?: (code: string) => void;
  onResend?: () => void;
  onRetry?: () => void;
  onUseDifferentEmail?: () => void;
};

export type LoginProps = LoginEmailProps | LoginVerificationProps;

/* Buffer past the exit animation so the leaving stage is still cleaned up
   when animation events never fire (reduced motion, detached documents). */
const STAGE_EXIT_FALLBACK_MS = motionDuration.loginStageExit + 250;

export const Login = (props: LoginProps) => {
  const lastPropsRef = useRef(props);
  const [exitingStage, setExitingStage] = useState<LoginProps | null>(null);

  // Snapshot the outgoing step during render so both steps share the first
  // transition frame, mirroring the commaboard Motion login cross-fade.
  const previousProps = lastPropsRef.current;
  if (previousProps.mode !== props.mode) {
    setExitingStage(previousProps);
  }
  lastPropsRef.current = props;

  const exitStageRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!exitingStage) {
      return;
    }
    const element = exitStageRef.current;
    const release = (event: Event) => {
      if (event.target === element) {
        setExitingStage(null);
      }
    };
    element?.addEventListener("animationend", release);
    const timer = setTimeout(() => setExitingStage(null), STAGE_EXIT_FALLBACK_MS);
    return () => {
      element?.removeEventListener("animationend", release);
      clearTimeout(timer);
    };
  }, [exitingStage]);

  return (
    <section
      aria-label={(props.copy ?? DEFAULT_LOGIN_COPY).regionLabel}
      className={cx(
        "flex w-[360px] max-w-full flex-col items-center gap-xl",
        props.className
      )}
    >
      <CommaMark className="size-6xl shrink-0 text-primary" />
      <div className="login-stage-viewport">
        {exitingStage && (
          <div
            key={`exit-${exitingStage.mode}`}
            ref={exitStageRef}
            aria-hidden="true"
            className="login-stage login-stage-motion"
            data-stage-state="exit"
            inert
          >
            <LoginStage {...exitingStage} />
          </div>
        )}
        <div
          key={props.mode}
          className="login-stage login-stage-motion"
          data-stage-state="enter"
        >
          <LoginStage {...props} />
        </div>
      </div>
    </section>
  );
};

const LoginStage = (props: LoginProps) =>
  props.mode === "verification" ? (
    <VerificationLogin {...props} />
  ) : (
    <EmailLogin {...props} />
  );

/* Pragmatic shape check: something@something.tld. Deliverability is the
   backend's judgment; this only stops obvious typos before a code is sent. */
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const EmailLogin = ({
  copy = DEFAULT_LOGIN_COPY,
  email: controlledEmail,
  defaultEmail = "",
  disabled = false,
  onEmailChange,
  onContinueWithEmail,
  googlePending = false,
  googleErrorMessage,
  onContinueWithGoogle,
  onContinueWithApple,
}: LoginEmailProps) => {
  const [uncontrolledEmail, setUncontrolledEmail] = useState(defaultEmail);
  const [hasValidationError, setHasValidationError] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  const email = controlledEmail ?? uncontrolledEmail;

  const handleEmailChange = (event: ChangeEvent<HTMLInputElement>) => {
    const nextEmail = event.target.value;
    if (controlledEmail === undefined) {
      setUncontrolledEmail(nextEmail);
    }
    if (hasValidationError) {
      setHasValidationError(false);
    }
    onEmailChange?.(nextEmail);
  };

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const trimmedEmail = email.trim();
    if (disabled || !trimmedEmail) {
      return;
    }
    if (!EMAIL_PATTERN.test(trimmedEmail)) {
      setHasValidationError(true);
      formRef.current?.querySelector<HTMLInputElement>('input[type="email"]')?.focus();
      return;
    }
    onContinueWithEmail?.(trimmedEmail);
  };

  return (
    <div className="flex w-full flex-col gap-3xl">
      <div className="flex w-full flex-col gap-3xl">
        <header className="flex w-full flex-col items-center">
          <Text
            as="h1"
            size="displayXs"
            weight="medium"
            className="text-center text-primary"
          >
            {copy.email.title}
          </Text>
          <Text size="textXl" weight="regular" className="text-center text-quaternary">
            {copy.email.subtitle}
          </Text>
        </header>

        {(onContinueWithGoogle || onContinueWithApple) && (
          <div className="flex w-full flex-col gap-lg">
            {onContinueWithGoogle && (
              <div className="flex w-full flex-col gap-sm">
                <Button
                  size="lg"
                  hierarchy="secondary-gray"
                  iconLeading={
                    googlePending ? (
                      <LoadingCircleIcon className="motion-safe:animate-spin" />
                    ) : (
                      <GoogleBrandMark />
                    )
                  }
                  isPending={googlePending}
                  className="w-full gap-lg text-sm text-secondary [&>span:first-child]:size-6"
                  disabled={disabled}
                  onPress={onContinueWithGoogle}
                >
                  {copy.email.googleAction}
                </Button>
                {googleErrorMessage && (
                  <p role="alert" className="text-sm text-error-primary">
                    {googleErrorMessage}
                  </p>
                )}
              </div>
            )}
            {onContinueWithApple && (
              <Button
                size="lg"
                hierarchy="secondary-gray"
                iconLeading={<AppleBrandMark className="text-primary" />}
                className="w-full gap-lg text-sm text-secondary [&>span:first-child]:size-6"
                disabled={disabled}
                onPress={onContinueWithApple}
              >
                {copy.email.appleAction}
              </Button>
            )}
          </div>
        )}
      </div>

      <form
        ref={formRef}
        className="flex w-full flex-col gap-xl"
        noValidate
        onSubmit={handleSubmit}
      >
        <InputField
          className="w-full"
          label={copy.email.label}
          type="email"
          autoComplete="email"
          placeholder={copy.email.placeholder}
          suppressFocusRing
          value={email}
          disabled={disabled}
          {...(hasValidationError ? { errorMessage: copy.email.invalidError } : {})}
          onChange={handleEmailChange}
        />
        <Button type="submit" className="w-full" disabled={disabled || !email.trim()}>
          {copy.email.continueAction}
        </Button>
      </form>
    </div>
  );
};

const VerificationLogin = ({
  copy = DEFAULT_LOGIN_COPY,
  email,
  code: controlledCode,
  defaultCode = "",
  errorMessage,
  resendSeconds = 60,
  disabled = false,
  onCodeChange,
  onCodeComplete,
  onResend,
  onRetry,
  onUseDifferentEmail,
}: LoginVerificationProps) => {
  const [uncontrolledCode, setUncontrolledCode] = useState(() =>
    normalizeCode(defaultCode)
  );
  const code = normalizeCode(controlledCode ?? uncontrolledCode);
  const errorId = useId();

  const handleCodeChange = (nextCode: string) => {
    if (controlledCode === undefined) {
      setUncontrolledCode(nextCode);
    }
    onCodeChange?.(nextCode);
    if (nextCode.length === 6 && nextCode !== code) {
      onCodeComplete?.(nextCode);
    }
  };

  return (
    <div className="flex w-full flex-col items-center gap-xl">
      <div className="flex w-full flex-col gap-3xl">
        <header className="flex w-full flex-col items-center gap-md">
          <Text
            as="h1"
            size="textXl"
            weight="medium"
            className="text-center text-primary"
          >
            {copy.verification.title}
          </Text>
          <Text
            size="textSm"
            weight="regular"
            className="w-full text-center text-quaternary"
          >
            {copy.verification.instruction(email)}
          </Text>
        </header>

        <VerificationCodeInput
          value={code}
          disabled={disabled}
          invalid={Boolean(errorMessage)}
          shakeKey={errorMessage}
          describedBy={errorMessage ? errorId : undefined}
          label={copy.verification.codeLabel}
          onChange={handleCodeChange}
        />
      </div>

      {errorMessage && (
        <div className="flex w-full flex-col items-start gap-md">
          <Text
            key={errorMessage}
            id={errorId}
            role="alert"
            size="textSm"
            weight="regular"
            className="w-full text-error-primary"
          >
            {errorMessage}
          </Text>
          {onRetry && (
            <Button
              hierarchy="link-gray"
              size="sm"
              className="font-regular text-primary"
              disabled={disabled}
              onPress={onRetry}
            >
              {copy.verification.retryAction}
            </Button>
          )}
        </div>
      )}

      {onResend && !errorMessage && (
        <Text size="textSm" weight="regular" className="text-center text-primary">
          <span className="text-quaternary">{copy.verification.codeNotReceived} </span>
          {resendSeconds > 0 ? (
            <span>{copy.verification.resendCountdown(resendSeconds)}</span>
          ) : (
            <Button
              hierarchy="link-gray"
              size="sm"
              className="font-regular text-primary"
              disabled={disabled}
              onPress={onResend}
            >
              {copy.verification.resendAction}
            </Button>
          )}
        </Text>
      )}

      <Button
        hierarchy="link-gray"
        size="sm"
        className="font-regular text-primary"
        disabled={disabled}
        {...(onUseDifferentEmail ? { onPress: onUseDifferentEmail } : {})}
      >
        {copy.verification.differentEmailAction}
      </Button>
    </div>
  );
};

type VerificationCodeInputProps = {
  value: string;
  invalid: boolean;
  shakeKey: string | undefined;
  disabled: boolean;
  describedBy: string | undefined;
  label: string;
  onChange: (value: string) => void;
};

const VERIFICATION_CODE_LENGTH = 6;

const VerificationCodeInput = ({
  value,
  invalid,
  shakeKey,
  disabled,
  describedBy,
  label,
  onChange,
}: VerificationCodeInputProps) => {
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const visualGroupRef = useRef<HTMLDivElement>(null);
  const shakeCellsRef = useRef<Array<HTMLElement | null>>([]);
  useErrorShake({
    active: invalid,
    cellsRef: shakeCellsRef,
    count: VERIFICATION_CODE_LENGTH,
    replayKey: shakeKey,
  });
  const [pressedKey, setPressedKey] = useState<{
    identity: string;
    index: number;
  } | null>(null);
  const [activeIndex, setActiveIndex] = useState<number | null>(null);
  const [poppingIndexes, setPoppingIndexes] = useState<ReadonlySet<number>>(
    () => new Set()
  );
  const previousValueRef = useRef(value);
  const pressedKeyRef = useRef(pressedKey);
  pressedKeyRef.current = pressedKey;
  // Cell index the hidden input should select once React has committed the
  // value it was typed into; a controlled value reset moves the native caret
  // to the end, so the selection is re-applied after commit.
  const pendingSelectionRef = useRef<number | null>(null);

  useEffect(() => {
    if (disabled) {
      setPressedKey(null);
      setActiveIndex(null);
      setPoppingIndexes(new Set());
    }
  }, [disabled]);

  useEffect(() => {
    const previous = previousValueRef.current;
    previousValueRef.current = value;
    if (previous === value) {
      return;
    }

    // A value transition owns the current pop state. Clearing it before any
    // early return prevents an interrupted paste/autofill timer from leaving
    // stale cells permanently scaled.
    setPoppingIndexes((current) => (current.size === 0 ? current : new Set()));
    if (disabled || pressedKeyRef.current) {
      return;
    }

    const entering = new Set<number>();
    for (let index = 0; index < VERIFICATION_CODE_LENGTH; index += 1) {
      if (!previous[index] && value[index]) {
        entering.add(index);
      }
    }
    if (entering.size === 0) {
      return;
    }

    setPoppingIndexes(entering);
    const timer = window.setTimeout(() => {
      setPoppingIndexes(new Set());
    }, motionDuration.feedbackIn);
    return () => window.clearTimeout(timer);
  }, [disabled, value]);

  // Moves the hidden input to a cell. A filled cell is selected as a whole
  // (its character is the selection, so typing replaces it); an empty cell
  // holds a collapsed caret. Past the last cell nothing is active.
  const selectCell = (element: HTMLInputElement, index: number) => {
    const selection = cellSelection(value, index);
    element.setSelectionRange(selection.start, selection.end);
    setActiveIndex(selection.active);
  };

  useLayoutEffect(() => {
    const index = pendingSelectionRef.current;
    if (index === null) {
      return;
    }
    pendingSelectionRef.current = null;
    const element = inputRef.current;
    if (element && document.activeElement === element) {
      selectCell(element, index);
    }
  });

  // Mirrors the hidden input's selection into the cell row. A collapsed caret
  // sitting before a character is widened onto that character so the cell
  // reads as selected rather than showing a caret beside the digit.
  const syncActiveFromSelection = (event: SyntheticEvent<HTMLInputElement>) => {
    const element = event.currentTarget;
    const start = element.selectionStart;
    const end = element.selectionEnd;
    if (start === null || end === null || start >= VERIFICATION_CODE_LENGTH) {
      setActiveIndex(null);
      return;
    }
    if (start === end) {
      if (value[start]) {
        element.setSelectionRange(start, start + 1);
      }
      setActiveIndex(start);
      return;
    }
    setActiveIndex(end - start === 1 && value[start] ? start : null);
  };

  const handleChange = (event: ChangeEvent<HTMLInputElement>) => {
    const element = event.target;
    const rawCaret = element.selectionStart ?? element.value.length;
    const nextValue = normalizeCode(element.value);
    const nextIndex = normalizeCode(element.value.slice(0, rawCaret)).length;
    pendingSelectionRef.current = nextIndex;
    setActiveIndex(cellSelection(nextValue, nextIndex).active);
    onChange(nextValue);
  };

  const handleKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (disabled || isImeKeyEvent(event.nativeEvent)) {
      return;
    }

    const element = event.currentTarget;
    const selectionStart = element.selectionStart ?? value.length;
    const selectionEnd = element.selectionEnd ?? selectionStart;

    if (!event.shiftKey && !event.altKey && !event.ctrlKey) {
      const toStart =
        event.key === "Home" || (event.key === "ArrowLeft" && event.metaKey);
      const toEnd =
        event.key === "End" || (event.key === "ArrowRight" && event.metaKey);
      const target = toStart
        ? 0
        : toEnd
          ? value.length
          : event.key === "ArrowLeft"
            ? selectionStart - 1
            : event.key === "ArrowRight"
              ? selectionStart + 1
              : null;
      if (target !== null) {
        event.preventDefault();
        selectCell(element, Math.max(0, target));
        return;
      }
    }

    const normalizedKey = normalizeCode(event.key);
    if (
      event.key.length === 1 &&
      normalizedKey.length === 0 &&
      !event.metaKey &&
      !event.ctrlKey
    ) {
      // A filled cell is a native selection. Letting the browser insert a
      // filtered character would replace that selection before onChange can
      // normalize it, deleting the existing code character as a side effect.
      event.preventDefault();
      return;
    }

    if (
      event.repeat ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      event.key.length !== 1 ||
      normalizedKey.length !== 1
    ) {
      return;
    }

    const replacesSelection = selectionEnd > selectionStart;
    if (selectionStart >= VERIFICATION_CODE_LENGTH && !replacesSelection) {
      return;
    }

    setPressedKey({
      identity: event.code && event.code !== "Unidentified" ? event.code : event.key,
      index: Math.min(selectionStart, VERIFICATION_CODE_LENGTH - 1),
    });
  };

  const handleKeyUp = (event: KeyboardEvent<HTMLInputElement>) => {
    const identity =
      event.code && event.code !== "Unidentified" ? event.code : event.key;
    setPressedKey((current) => (current?.identity === identity ? null : current));
  };

  const handlePointerDown = (event: PointerEvent<HTMLInputElement>) => {
    if (disabled) {
      return;
    }

    const cells = Array.from(
      visualGroupRef.current?.querySelectorAll<HTMLElement>("[data-login-code-cell]") ??
        []
    );
    if (cells.length === 0) {
      return;
    }

    const measuredCells = cells
      .map((cell, index) => ({ index, rect: cell.getBoundingClientRect() }))
      .filter(({ rect }) => rect.width > 0);
    if (measuredCells.length === 0) {
      return;
    }

    const exactIndex = measuredCells.find(({ rect }) => {
      return event.clientX >= rect.left && event.clientX <= rect.right;
    })?.index;
    const closestIndex = measuredCells.reduce(
      (closest, { index, rect }) => {
        const distance = Math.abs(event.clientX - (rect.left + rect.right) / 2);
        return distance < closest.distance ? { distance, index } : closest;
      },
      { distance: Number.POSITIVE_INFINITY, index: 0 }
    ).index;

    event.preventDefault();
    event.currentTarget.focus();
    selectCell(event.currentTarget, exactIndex ?? closestIndex);
  };

  return (
    <div className="relative w-full overflow-visible">
      <label className="sr-only" htmlFor={inputId}>
        {label}
      </label>
      <div
        ref={visualGroupRef}
        aria-hidden="true"
        data-invalid={invalid}
        data-login-code-group=""
        className="flex w-full gap-md overflow-visible"
      >
        {Array.from({ length: VERIFICATION_CODE_LENGTH }, (_, index) => {
          const filled = Boolean(value[index]);
          const active = !disabled && activeIndex === index;
          const pressed = !disabled && pressedKey?.index === index;
          const popping = !disabled && poppingIndexes.has(index);

          return (
            <span
              key={index}
              ref={(node) => {
                shakeCellsRef.current[index] = node;
              }}
              data-login-code-shake=""
              className={cx(
                "relative flex aspect-square min-w-0 flex-1 overflow-visible",
                active && "z-10"
              )}
            >
              <span
                data-login-code-cell=""
                data-active={active}
                data-filled={filled}
                data-pop={popping}
                data-pressed={pressed}
                className={cx(
                  "login-code-cell-motion relative flex h-full w-full items-center justify-center overflow-hidden rounded-sm border text-xl font-medium",
                  invalid ? "border-error" : "border-primary",
                  filled && !active
                    ? "bg-disabled text-quaternary shadow-none"
                    : "bg-primary text-primary shadow-xs"
                )}
              >
                {value[index] ?? ""}
                {/* A filled active cell is selected as a whole; only an empty
                    active cell shows a caret. */}
                {active && !filled && (
                  <span
                    data-login-code-caret=""
                    className="login-code-caret-motion pointer-events-none absolute top-1/2 left-1/2 h-[1.25em] w-px -translate-x-1/2 -translate-y-1/2 bg-current"
                  />
                )}
              </span>
            </span>
          );
        })}
      </div>
      <InputBase
        ref={inputRef}
        id={inputId}
        aria-describedby={describedBy}
        aria-invalid={invalid}
        aria-label={label}
        autoCapitalize="characters"
        autoComplete="one-time-code"
        disabled={disabled}
        isDisabled={disabled}
        isInvalid={invalid}
        suppressFocusRing
        value={value}
        wrapperClassName="absolute inset-0 z-10 min-h-0 rounded-xs bg-transparent opacity-0 shadow-none ring-0"
        inputClassName="h-full cursor-text p-0"
        onChange={handleChange}
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
        onPointerDown={handlePointerDown}
        onFocus={syncActiveFromSelection}
        onSelect={syncActiveFromSelection}
        onBlur={() => {
          setPressedKey(null);
          setActiveIndex(null);
        }}
      />
    </div>
  );
};

/** Native selection that lands on `index` of `code`: a filled cell selects
 *  its character, an empty cell collapses, and past the last cell no cell is
 *  active. */
const cellSelection = (code: string, index: number) => {
  const start = Math.min(index, code.length);
  const active = start >= VERIFICATION_CODE_LENGTH ? null : start;
  return { start, end: code[start] ? start + 1 : start, active };
};

const normalizeCode = (value: string) =>
  value
    .replace(/[^a-z0-9]/gi, "")
    .slice(0, VERIFICATION_CODE_LENGTH)
    .toUpperCase();
