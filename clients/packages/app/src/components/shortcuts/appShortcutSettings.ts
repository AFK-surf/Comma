import {
  commaClientAppKeybindingSchema,
  type CommaClientAppShortcutOverrides,
} from "@comma/native-bridge";
import {
  appKeybindingsConflict,
  parseStoredAppKeybinding,
  sameAppKeybinding,
  type AppKeybinding,
} from "@comma/ui";
import {
  appShortcutIds,
  createDefaultAppShortcutBindings,
  type AppShortcutBindings,
  type AppShortcutId,
  type AppShortcutPlatform,
} from "./appShortcutRegistry";

const legacyAppShortcutsStorageVersion = 2;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const parseBinding = (
  value: unknown
): { binding: AppKeybinding | null; valid: true } | { valid: false } => {
  if (value === null) return { binding: null, valid: true };
  const binding = parseStoredAppKeybinding(value);
  return binding ? { binding, valid: true } : { valid: false };
};

const findConflict = (
  bindings: AppShortcutBindings,
  id: AppShortcutId,
  binding: AppKeybinding | null
) =>
  appShortcutIds.find(
    (otherId) => otherId !== id && appKeybindingsConflict(bindings[otherId], binding)
  );

export function resolveAppShortcutBindings(
  defaults: AppShortcutBindings,
  source: CommaClientAppShortcutOverrides
): AppShortcutBindings {
  const next = Object.fromEntries(
    appShortcutIds.map((id) => [id, null] as const)
  ) as AppShortcutBindings;
  const acceptedOverrides = new Set<AppShortcutId>();

  for (const id of appShortcutIds) {
    if (!Object.prototype.hasOwnProperty.call(source, id)) continue;
    const binding = source[id] ?? null;
    if (findConflict(next, id, binding)) continue;
    next[id] = binding;
    acceptedOverrides.add(id);
  }

  for (const id of appShortcutIds) {
    if (acceptedOverrides.has(id)) continue;
    const binding = defaults[id];
    next[id] = findConflict(next, id, binding) ? null : binding;
  }
  return next;
}

export function appShortcutBindingsToOverrides(
  bindings: AppShortcutBindings,
  defaults: AppShortcutBindings
): CommaClientAppShortcutOverrides {
  const overrides: CommaClientAppShortcutOverrides = {};
  for (const id of appShortcutIds) {
    if (!sameAppKeybinding(bindings[id], defaults[id])) {
      overrides[id] =
        bindings[id] === null
          ? null
          : commaClientAppKeybindingSchema.parse(bindings[id]);
    }
  }
  return overrides;
}

export function parseLegacyAppShortcutOverrides(
  value: unknown,
  platform: AppShortcutPlatform
): CommaClientAppShortcutOverrides {
  const defaults = createDefaultAppShortcutBindings(platform);
  if (!isRecord(value)) return {};

  const versionedSource =
    value.version === legacyAppShortcutsStorageVersion && isRecord(value.overrides)
      ? value.overrides
      : undefined;
  const versioned = versionedSource !== undefined;
  const source = versionedSource ?? value;
  const legacyMacDefaults = createDefaultAppShortcutBindings("macos");
  const overrides: CommaClientAppShortcutOverrides = {};

  for (const id of appShortcutIds) {
    if (!Object.prototype.hasOwnProperty.call(source, id)) continue;
    const result = parseBinding(source[id]);
    if (!result.valid) continue;
    if (
      !versioned &&
      result.binding !== null &&
      sameAppKeybinding(result.binding, legacyMacDefaults[id])
    ) {
      continue;
    }
    overrides[id] =
      result.binding === null
        ? null
        : commaClientAppKeybindingSchema.parse(result.binding);
  }

  return appShortcutBindingsToOverrides(
    resolveAppShortcutBindings(defaults, overrides),
    defaults
  );
}
