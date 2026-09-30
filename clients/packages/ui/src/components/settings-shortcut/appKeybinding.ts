export type AppKeyCode =
  | "KeyA"
  | "KeyB"
  | "KeyC"
  | "KeyD"
  | "KeyE"
  | "KeyF"
  | "KeyG"
  | "KeyH"
  | "KeyI"
  | "KeyJ"
  | "KeyK"
  | "KeyL"
  | "KeyM"
  | "KeyN"
  | "KeyO"
  | "KeyP"
  | "KeyQ"
  | "KeyR"
  | "KeyS"
  | "KeyT"
  | "KeyU"
  | "KeyV"
  | "KeyW"
  | "KeyX"
  | "KeyY"
  | "KeyZ"
  | "Digit0"
  | "Digit1"
  | "Digit2"
  | "Digit3"
  | "Digit4"
  | "Digit5"
  | "Digit6"
  | "Digit7"
  | "Digit8"
  | "Digit9"
  | "Comma"
  | "BracketLeft"
  | "BracketRight";

export type AppKeyModifiers = {
  alt: boolean;
  control: boolean;
  meta: boolean;
  shift: boolean;
};

export type AppKeyStroke = {
  code: AppKeyCode;
  modifiers: AppKeyModifiers;
};

export type AppKeybinding =
  | { kind: "chord"; stroke: AppKeyStroke }
  | { kind: "sequence"; codes: readonly AppKeyCode[] };

export type AppKeybindingPlatform = "linux" | "macos" | "windows";

export const APP_KEYBINDING_MAX_KEYCAPS = 3;
export const APP_KEYBINDING_SEQUENCE_TIMEOUT_MS = 1000;

const letterCodes = Array.from(
  { length: 26 },
  (_, index) => `Key${String.fromCharCode(65 + index)}` as AppKeyCode
);
const digitCodes = Array.from(
  { length: 10 },
  (_, index) => `Digit${index}` as AppKeyCode
);
const specialCodes = [
  "Comma",
  "BracketLeft",
  "BracketRight",
] as const satisfies readonly AppKeyCode[];

const appKeyCodes = new Set<string>([...letterCodes, ...digitCodes, ...specialCodes]);

export const emptyAppKeyModifiers = (): AppKeyModifiers => ({
  alt: false,
  control: false,
  meta: false,
  shift: false,
});

export const isAppKeyCode = (value: string): value is AppKeyCode =>
  appKeyCodes.has(value);

export const parseAppKeyCode = (code: string): AppKeyCode | undefined =>
  isAppKeyCode(code) ? code : undefined;

export const modifiersFromKeyboardEvent = (event: {
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
}): AppKeyModifiers => ({
  alt: event.altKey,
  control: event.ctrlKey,
  meta: event.metaKey,
  shift: event.shiftKey,
});

export const hasPrimaryModifier = (modifiers: AppKeyModifiers) =>
  modifiers.alt || modifiers.control || modifiers.meta;

export const modifierKeycapCount = (modifiers: AppKeyModifiers) =>
  Number(modifiers.alt) +
  Number(modifiers.control) +
  Number(modifiers.meta) +
  Number(modifiers.shift);

export const appKeybindingKeycapCount = (binding: AppKeybinding) =>
  binding.kind === "sequence"
    ? binding.codes.length
    : modifierKeycapCount(binding.stroke.modifiers) + 1;

export const isValidAppKeybinding = (binding: AppKeybinding): boolean => {
  if (appKeybindingKeycapCount(binding) > APP_KEYBINDING_MAX_KEYCAPS) return false;
  if (binding.kind === "sequence") {
    return (
      binding.codes.length >= 2 &&
      binding.codes.length <= APP_KEYBINDING_MAX_KEYCAPS &&
      binding.codes.every(isAppKeyCode)
    );
  }
  return (
    hasPrimaryModifier(binding.stroke.modifiers) && isAppKeyCode(binding.stroke.code)
  );
};

export const sameAppKeyModifiers = (left: AppKeyModifiers, right: AppKeyModifiers) =>
  left.alt === right.alt &&
  left.control === right.control &&
  left.meta === right.meta &&
  left.shift === right.shift;

export const sameAppKeybinding = (
  left: AppKeybinding | null,
  right: AppKeybinding | null
) => {
  if (left === null || right === null) return left === right;
  if (left.kind !== right.kind) return false;
  if (left.kind === "sequence" && right.kind === "sequence") {
    return (
      left.codes.length === right.codes.length &&
      left.codes.every((code, index) => code === right.codes[index])
    );
  }
  if (left.kind === "chord" && right.kind === "chord") {
    return (
      left.stroke.code === right.stroke.code &&
      sameAppKeyModifiers(left.stroke.modifiers, right.stroke.modifiers)
    );
  }
  return false;
};

export const appKeybindingsConflict = (
  left: AppKeybinding | null,
  right: AppKeybinding | null
) => {
  if (left === null || right === null || left.kind !== right.kind) return false;
  if (left.kind === "chord" && right.kind === "chord") {
    return sameAppKeybinding(left, right);
  }
  if (left.kind === "sequence" && right.kind === "sequence") {
    const commonLength = Math.min(left.codes.length, right.codes.length);
    for (let index = 0; index < commonLength; index += 1) {
      if (left.codes[index] !== right.codes[index]) return false;
    }
    return commonLength > 0;
  }
  return false;
};

export const detectAppKeybindingPlatform = (): AppKeybindingPlatform => {
  const navigatorLike = globalThis.navigator as
    | (Navigator & { userAgentData?: { platform?: string } })
    | undefined;
  const platform = `${navigatorLike?.userAgentData?.platform ?? ""} ${
    navigatorLike?.platform ?? ""
  } ${navigatorLike?.userAgent ?? ""}`.toLocaleLowerCase();

  if (
    platform.includes("mac") ||
    platform.includes("iphone") ||
    platform.includes("ipad")
  ) {
    return "macos";
  }
  if (platform.includes("win")) return "windows";
  return "linux";
};

export const appKeyCodeLabel = (code: AppKeyCode): string => {
  if (code === "Comma") return ",";
  if (code === "BracketLeft") return "[";
  if (code === "BracketRight") return "]";
  if (code.startsWith("Digit")) return code.slice(5);
  return code.slice(3);
};

export const appKeyModifierKeycaps = (
  modifiers: AppKeyModifiers,
  platform = detectAppKeybindingPlatform()
) => {
  if (platform === "macos") {
    return [
      ...(modifiers.control ? ["⌃"] : []),
      ...(modifiers.alt ? ["⌥"] : []),
      ...(modifiers.shift ? ["⇧"] : []),
      ...(modifiers.meta ? ["⌘"] : []),
    ];
  }
  return [
    ...(modifiers.control ? ["Ctrl"] : []),
    ...(modifiers.alt ? ["Alt"] : []),
    ...(modifiers.shift ? ["Shift"] : []),
    ...(modifiers.meta ? [platform === "windows" ? "Win" : "Super"] : []),
  ];
};

export const appKeybindingKeycaps = (
  binding: AppKeybinding | null,
  platform = detectAppKeybindingPlatform()
): string[] => {
  if (binding === null) return [];
  if (binding.kind === "sequence") {
    return binding.codes.map(appKeyCodeLabel);
  }
  const { modifiers, code } = binding.stroke;
  return [...appKeyModifierKeycaps(modifiers, platform), appKeyCodeLabel(code)];
};

export const formatAppKeybinding = (
  binding: AppKeybinding | null,
  platform = detectAppKeybindingPlatform()
): string => {
  if (binding === null) return "";
  if (binding.kind === "sequence") {
    return binding.codes.map(appKeyCodeLabel).join(" ");
  }
  return appKeybindingKeycaps(binding, platform).join(platform === "macos" ? "" : "+");
};

export const formatAppKeybindingAria = (
  binding: AppKeybinding | null,
  platform = detectAppKeybindingPlatform()
): string => {
  if (binding === null) return "";
  if (binding.kind === "sequence") {
    return binding.codes.map(appKeyCodeLabel).join(" then ");
  }
  const { modifiers, code } = binding.stroke;
  return [
    ...(modifiers.control ? ["Control"] : []),
    ...(modifiers.alt ? [platform === "macos" ? "Option" : "Alt"] : []),
    ...(modifiers.shift ? ["Shift"] : []),
    ...(modifiers.meta
      ? [
          platform === "macos"
            ? "Command"
            : platform === "windows"
              ? "Windows"
              : "Super",
        ]
      : []),
    appKeyCodeLabel(code),
  ].join(" + ");
};

export const chordKeybinding = (
  code: AppKeyCode,
  modifiers: Partial<AppKeyModifiers> &
    ({ meta: true } | { alt: true } | { control: true })
): AppKeybinding => ({
  kind: "chord",
  stroke: {
    code,
    modifiers: {
      ...emptyAppKeyModifiers(),
      ...modifiers,
    },
  },
});

export const sequenceKeybinding = (
  ...codes: readonly [AppKeyCode, AppKeyCode, ...AppKeyCode[]]
): AppKeybinding => ({
  kind: "sequence",
  codes,
});

export const matchesAppKeyStroke = (
  stroke: AppKeyStroke,
  event: {
    code: string;
    altKey: boolean;
    ctrlKey: boolean;
    metaKey: boolean;
    shiftKey: boolean;
  }
) =>
  event.code === stroke.code &&
  sameAppKeyModifiers(stroke.modifiers, modifiersFromKeyboardEvent(event));

export const isEditableTarget = (target: EventTarget | null) => {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
};

export const parseStoredAppKeybinding = (value: unknown): AppKeybinding | undefined => {
  if (!value || typeof value !== "object") return undefined;
  const record = value as {
    kind?: unknown;
    stroke?: { code?: unknown; modifiers?: Partial<AppKeyModifiers> };
    codes?: unknown;
  };
  if (record.kind === "sequence" && Array.isArray(record.codes)) {
    const codes = record.codes.filter(
      (code): code is AppKeyCode => typeof code === "string" && isAppKeyCode(code)
    );
    const binding: AppKeybinding = { kind: "sequence", codes };
    return isValidAppKeybinding(binding) ? binding : undefined;
  }
  if (
    record.kind === "chord" &&
    record.stroke &&
    typeof record.stroke.code === "string" &&
    isAppKeyCode(record.stroke.code)
  ) {
    const modifiers = record.stroke.modifiers
      ? { ...emptyAppKeyModifiers(), ...record.stroke.modifiers }
      : emptyAppKeyModifiers();
    const binding: AppKeybinding = {
      kind: "chord",
      stroke: { code: record.stroke.code, modifiers },
    };
    return isValidAppKeybinding(binding) ? binding : undefined;
  }
  return undefined;
};
