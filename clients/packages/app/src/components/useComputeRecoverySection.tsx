import { useContext, useEffect, useRef, useState } from "react";
import { getNativeBridge, type ComputeRecoveryCandidates } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { CommaAuthContext } from "./auth-context";
import { computeOperationMessage } from "./useComputeNode";

/** Manual bounded recovery discovery. A candidate key is valid only in Main's current Session. */
export function useComputeRecoverySection(
  workspaceId: string | undefined,
  confirmationId: string | undefined,
  onRecovered: () => void
) {
  const m = useCommaMessages(),
    bridge = getNativeBridge();
  const auth = useContext(CommaAuthContext);
  const [page, setPage] = useState<ComputeRecoveryCandidates>();
  const [selection, setSelection] = useState<string>();
  const [pending, setPending] = useState(false),
    [error, setError] = useState<string>();
  const epoch = useRef(0);
  useEffect(() => {
    epoch.current++;
    setPage(undefined);
    setSelection(undefined);
    setError(undefined);
    setPending(false);
  }, [workspaceId, confirmationId]);
  const discover = async (cursor?: string) => {
    if (!workspaceId || pending) return;
    const current = epoch.current;
    setPending(true);
    setError(undefined);
    try {
      const next = await bridge.computeNode.recoveryCandidates({
        workspaceId,
        ...(cursor ? { cursor } : {}),
      });
      if (epoch.current !== current) return;
      setPage(next);
      if (!cursor && next.candidates.length === 1 && !next.nextCursor)
        setSelection(next.candidates[0]!.key);
    } catch (reason) {
      if (epoch.current === current) setError(computeOperationMessage(reason, m));
    } finally {
      if (epoch.current === current) setPending(false);
    }
  };
  const selected = selection
    ? page?.candidates.find((row) => row.key === selection)
    : undefined;
  /** Recovers the selected candidate. The page shows its facts first, so the press is the confirmation. */
  const confirm = () => {
    if (!selected || !page || pending) return;
    const current = epoch.current,
      token = page.confirmationId;
    setSelection(undefined);
    setPending(true);
    setError(undefined);
    void bridge.computeNode
      .recover({ key: selected.key, confirmationId: token })
      .then(() => {
        if (epoch.current === current) {
          setPage(undefined);
          onRecovered();
        }
      })
      .catch((reason: unknown) => {
        if (epoch.current === current) setError(computeOperationMessage(reason, m));
      })
      .finally(() => {
        if (epoch.current === current) setPending(false);
      });
  };
  return {
    page,
    pending,
    error,
    account: auth?.userEmail,
    selected,
    select: setSelection,
    cancel: () => setSelection(undefined),
    confirm,
    discover,
  };
}
