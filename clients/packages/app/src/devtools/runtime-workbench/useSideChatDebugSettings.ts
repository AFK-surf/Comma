import { useCallback, useEffect, useRef, useState } from "react";
import { getNativeBridge, type SideChatDebugSettings } from "@comma/native-bridge";

export type BackdropSettingsPatch = Partial<Omit<SideChatDebugSettings, "revision">>;
type Mutation = { patch: BackdropSettingsPatch } | { reset: true };

export function useSideChatDebugSettings() {
  const [settings, setSettings] = useState<SideChatDebugSettings>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const actions = useRef<{
    update: (patch: BackdropSettingsPatch) => void;
    reset: () => void;
  } | null>(null);

  useEffect(() => {
    const bridge = getNativeBridge().sideChat;
    let active = true;
    let accepted: SideChatDebugSettings | undefined;
    let inFlight: Mutation | undefined;
    let pending: BackdropSettingsPatch = {};

    const publish = () => {
      if (!active || !accepted) return;
      setSettings({
        ...accepted,
        ...(inFlight && "patch" in inFlight ? inFlight.patch : {}),
        ...pending,
      });
      setBusy(Boolean(inFlight));
    };
    const accept = (snapshot: SideChatDebugSettings) => {
      if (!active || (accepted && snapshot.revision < accepted.revision)) return;
      accepted = snapshot;
      publish();
    };

    // One panel owns one subscription and at most one mutation in flight. Slider
    // input replaces keys in one bounded pending patch; no timer or polling.
    const run = async (mutation: Mutation) => {
      inFlight = mutation;
      setError(undefined);
      publish();
      try {
        accept(
          "reset" in mutation
            ? await bridge.resetDebugSettings()
            : await bridge.updateDebugSettings(mutation.patch)
        );
      } catch (cause) {
        if (active) setError(cause instanceof Error ? cause.message : String(cause));
      } finally {
        inFlight = undefined;
        if (active) {
          if (Object.keys(pending).length > 0) {
            const patch = pending;
            pending = {};
            void run({ patch });
          } else {
            publish();
          }
        }
      }
    };

    actions.current = {
      update(patch) {
        if (!accepted || !active) return;
        if (inFlight) {
          pending = { ...pending, ...patch };
          publish();
        } else {
          void run({ patch });
        }
      },
      reset() {
        if (accepted && active && !inFlight) void run({ reset: true });
      },
    };

    const unsubscribe = bridge.debugSettings.subscribe(accept);
    // The explicit read exposes startup errors; replay subscriptions report
    // theirs only to the console. Revisions prevent either read rolling back a
    // newer live event or a completed edit.
    void bridge.debugSettings.get().then(accept, (cause: unknown) => {
      if (active && !accepted) {
        setError(cause instanceof Error ? cause.message : String(cause));
      }
    });

    return () => {
      active = false;
      pending = {};
      actions.current = null;
      unsubscribe();
    };
  }, []);

  const update = useCallback((patch: BackdropSettingsPatch) => {
    actions.current?.update(patch);
  }, []);
  const reset = useCallback(() => actions.current?.reset(), []);

  return { settings, busy, error, update, reset };
}
