import {
  defaultSideChatShortcut,
  sideChatShortcutBindingSchema,
  type SideChatShortcutBinding,
} from "@comma/native-bridge";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import {
  isElectronSideChatRuntime,
  updateNativeSideChatShortcut,
} from "../runtime-side-chat/nativeSideChat";
import { useCommaClientSettings } from "./commaClientSettings";

const cloneShortcut = (shortcut: SideChatShortcutBinding): SideChatShortcutBinding =>
  shortcut === null
    ? null
    : {
        key: shortcut.key,
        modifiers: { ...shortcut.modifiers },
      };

const sameShortcut = (left: SideChatShortcutBinding, right: SideChatShortcutBinding) =>
  left === right ||
  (left !== null &&
    right !== null &&
    left.key === right.key &&
    left.modifiers.alt === right.modifiers.alt &&
    left.modifiers.control === right.modifiers.control &&
    left.modifiers.meta === right.modifiers.meta &&
    left.modifiers.shift === right.modifiers.shift);

interface CommaSideChatShortcutContextValue {
  registrationFailed: boolean;
  registrationPending: boolean;
  shortcut: SideChatShortcutBinding;
  setShortcut: (shortcut: SideChatShortcutBinding) => Promise<void>;
}

const CommaSideChatShortcutContext =
  createContext<CommaSideChatShortcutContextValue | null>(null);

export function CommaSideChatShortcutProvider({ children }: { children: ReactNode }) {
  const electronRuntime = isElectronSideChatRuntime();
  const clientSettings = useCommaClientSettings();
  const shortcut = clientSettings.settings.sideChatShortcut;
  const updateClientSettings = clientSettings.update;
  const [registrationFailed, setRegistrationFailed] = useState(false);
  const [registrationPending, setRegistrationPending] = useState(electronRuntime);
  const acknowledgedOperationRef = useRef(0);
  const acknowledgedShortcutRef = useRef<SideChatShortcutBinding | undefined>(
    undefined
  );
  const operationRef = useRef(0);

  useEffect(() => {
    if (!electronRuntime) return;
    if (
      acknowledgedShortcutRef.current !== undefined &&
      sameShortcut(acknowledgedShortcutRef.current, shortcut)
    ) {
      if (operationRef.current === acknowledgedOperationRef.current) {
        setRegistrationPending(false);
      }
      return;
    }

    const operation = ++operationRef.current;
    setRegistrationPending(true);
    void (async () => {
      try {
        const registered = await updateNativeSideChatShortcut(shortcut);
        if (operationRef.current !== operation) return;
        acknowledgedOperationRef.current = operation;
        acknowledgedShortcutRef.current = cloneShortcut(registered);
        if (!sameShortcut(registered, shortcut)) {
          await updateClientSettings({ sideChatShortcut: registered });
        }
        setRegistrationFailed(false);
      } catch {
        if (operationRef.current !== operation) return;
        const acknowledged =
          acknowledgedShortcutRef.current === undefined
            ? cloneShortcut(defaultSideChatShortcut)
            : acknowledgedShortcutRef.current;
        acknowledgedOperationRef.current = operation;
        acknowledgedShortcutRef.current = cloneShortcut(acknowledged);
        if (!sameShortcut(acknowledged, shortcut)) {
          await updateClientSettings({ sideChatShortcut: acknowledged });
        }
        setRegistrationFailed(true);
      } finally {
        if (operationRef.current === operation) setRegistrationPending(false);
      }
    })();
  }, [electronRuntime, shortcut, updateClientSettings]);

  const setShortcut = useCallback(
    async (next: SideChatShortcutBinding) => {
      if (!electronRuntime) return;

      const parsed = sideChatShortcutBindingSchema.parse(next);
      const operation = ++operationRef.current;
      setRegistrationFailed(false);
      setRegistrationPending(true);
      try {
        const registered = await updateNativeSideChatShortcut(parsed);
        if (operation > acknowledgedOperationRef.current) {
          acknowledgedOperationRef.current = operation;
          acknowledgedShortcutRef.current = cloneShortcut(registered);
          await updateClientSettings({ sideChatShortcut: registered });
        }
      } catch {
        if (operationRef.current === operation) {
          const acknowledged =
            acknowledgedShortcutRef.current === undefined
              ? cloneShortcut(defaultSideChatShortcut)
              : acknowledgedShortcutRef.current;
          acknowledgedOperationRef.current = operation;
          acknowledgedShortcutRef.current = cloneShortcut(acknowledged);
          if (!sameShortcut(acknowledged, shortcut)) {
            await updateClientSettings({ sideChatShortcut: acknowledged });
          }
          setRegistrationFailed(true);
        }
      } finally {
        if (operationRef.current === operation) setRegistrationPending(false);
      }
    },
    [electronRuntime, shortcut, updateClientSettings]
  );

  const value = useMemo(
    () => ({
      registrationFailed,
      registrationPending,
      setShortcut,
      shortcut,
    }),
    [registrationFailed, registrationPending, setShortcut, shortcut]
  );

  return (
    <CommaSideChatShortcutContext.Provider value={value}>
      {children}
    </CommaSideChatShortcutContext.Provider>
  );
}

export function useCommaSideChatShortcut() {
  const value = useContext(CommaSideChatShortcutContext);
  if (!value) {
    throw new Error(
      "useCommaSideChatShortcut must be used within CommaSideChatShortcutProvider."
    );
  }
  return value;
}

export function useOptionalCommaSideChatShortcut() {
  return useContext(CommaSideChatShortcutContext);
}
