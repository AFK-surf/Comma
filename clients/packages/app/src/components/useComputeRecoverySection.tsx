import { useEffect, useRef, useState } from "react";
import { getNativeBridge, type ComputeRecoveryCandidates } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog, type SettingsPanelSection } from "@comma/ui";

/** Manual bounded recovery discovery. A candidate key is valid only in Main's current Session. */
export function useComputeRecoverySection(
  workspaceId: string | undefined,
  confirmationId: string | undefined,
  onRecovered: () => void
) {
  const m = useCommaMessages(),
    bridge = getNativeBridge();
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
      if (epoch.current === current) setPage(next);
    } catch (reason) {
      if (epoch.current === current)
        setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      if (epoch.current === current) setPending(false);
    }
  };
  const section: SettingsPanelSection = {
    id: "compute-node.recovery",
    title: m.compute_recovery_title(),
    items: [
      {
        id: "compute-node.recovery.find",
        title: m.compute_recovery_find(),
        description:
          page?.candidates.length === 0
            ? m.compute_recovery_none()
            : m.compute_recovery_explanation(),
        ...(error ? { errorMessage: error } : {}),
        control: {
          type: "button",
          label: m.compute_recovery_find(),
          disabled: pending || !workspaceId,
          onPress: () => void discover(),
        },
      },
      ...(page?.candidates.map((row) => ({
        id: row.key,
        title: m.compute_recovery_candidate({ id: row.label }),
        control: {
          type: "button" as const,
          label: m.compute_recovery_title(),
          disabled: pending,
          onPress: () => setSelection(row.key),
        },
      })) ?? []),
      ...(page?.nextCursor
        ? [
            {
              id: "compute-node.recovery.next",
              title: m.compute_recovery_next(),
              control: {
                type: "button" as const,
                label: m.compute_recovery_next(),
                disabled: pending,
                onPress: () => void discover(page.nextCursor),
              },
            },
          ]
        : []),
    ],
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
                    setError(reason instanceof Error ? reason.message : String(reason));
                })
                .finally(() => {
                  if (epoch.current === current) setPending(false);
                });
            },
          },
        ]}
      />
    ) : undefined;
  return { section, overlay };
}
