import { Fragment, useContext, useEffect, useRef, useState } from "react";
import { getNativeBridge, type ComputeRecoveryCandidates } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { CommaAuthContext } from "./auth-context";
import { computeOperationMessage } from "./useComputeNode";
import { Dialog } from "@comma/ui/components/dialog";

/** Manual bounded recovery discovery. A candidate key is valid only in Main's current Session. */
export function useComputeRecoverySection(
  workspaceId: string | undefined,
  confirmationId: string | undefined,
  onRecovered: () => void,
  workspaceName?: string
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
  const overlay =
    selection && page ? (
      <Dialog
        isOpen
        isDismissable
        title={m.compute_recovery_title()}
        description={m.compute_recovery_explanation()}
        onOpenChange={(open) => {
          if (!open) setSelection(undefined);
        }}
        actions={[
          {
            label: m.settings_profile_cancel(),
            hierarchy: "secondary-gray",
            onPress: () => setSelection(undefined),
          },
          {
            label: m.compute_recovery_title(),
            hierarchy: "primary",
            disabled: pending,
            onPress: () => {
              const current = epoch.current,
                key = selection,
                token = page.confirmationId;
              setSelection(undefined);
              setPending(true);
              setError(undefined);
              void bridge.computeNode
                .recover({ key, confirmationId: token })
                .then(() => {
                  if (epoch.current === current) {
                    setPage(undefined);
                    onRecovered();
                  }
                })
                .catch((reason: unknown) => {
                  if (epoch.current === current)
                    setError(computeOperationMessage(reason, m));
                })
                .finally(() => {
                  if (epoch.current === current) setPending(false);
                });
            },
          },
        ]}
      >
        <dl className="compute-recovery-facts">
          <div>
            <dt>{m.compute_ui_account()}</dt>
            <dd>{auth?.userEmail ?? m.compute_ui_account_unknown()}</dd>
          </div>
          {page.candidates
            .filter((row) => row.key === selection)
            .map((row) => (
              <Fragment key={row.key}>
                <div>
                  <dt>{m.compute_ui_device()}</dt>
                  <dd>{row.machine ?? row.label}</dd>
                </div>
                <div>
                  <dt>{m.compute_ui_workspace()}</dt>
                  <dd>
                    {row.workspaceId === workspaceId
                      ? (workspaceName ?? row.workspaceId)
                      : row.workspaceId}
                  </dd>
                </div>
                <div>
                  <dt>{m.compute_ui_service()}</dt>
                  <dd>{row.endpoint ?? m.compute_activity_unknown()}</dd>
                </div>
              </Fragment>
            ))}
        </dl>
      </Dialog>
    ) : undefined;
  return { page, pending, error, select: setSelection, overlay, discover };
}
