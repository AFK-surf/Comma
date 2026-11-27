import { useCall, useTopic, type TaskRequestPerson } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { toast } from "@comma/ui/components/toast";
import { useEffect, useState } from "react";
import { useWorkspacePreference } from "../activeWorkspace";

type Preview = {
  workspace: { name: string | null; owner: TaskRequestPerson | null };
  own: boolean;
  back: { workspace: { id: string; name: string | null }; mode: string } | null;
};

/**
 * People › Add › Accept an invite link: the person pastes a link someone gave them. The dialog says whose it is and
 * what accepting it gives either side before it can be accepted (`taskRequests.invitePreview`), as Settings › Task
 * requests does; accepting adds the inviter to People.
 */
export function AcceptInviteDialog({
  onClose,
  workspace,
}: {
  onClose: () => void;
  workspace: string | undefined;
}) {
  const m = useCommaMessages();
  const call = useCall();
  // The person's own Workspace, where the inviter may send back: People's, else the one the app works in, else the one
  // being made for a new account (following it makes it, as Join does). Without one, accepting connects one way only.
  const active = useWorkspacePreference();
  const made = useTopic(
    !workspace && active === "" ? { topic: "onboardingWorkspace" } : null
  ).value;
  const own =
    workspace || active || (made?.status === "ready" ? made.workspaceId : undefined);
  const [link, setLink] = useState("");
  const [preview, setPreview] = useState<Preview | "gone" | "unread">();
  const [busy, setBusy] = useState(false);
  const trimmed = link.trim();

  useEffect(() => {
    setPreview(undefined);
    if (!trimmed) return undefined;
    let live = true;
    call("taskRequests.invitePreview", {
      invite: trimmed,
      ...(own ? { workspace: own } : {}),
    }).then(
      (read) => live && setPreview(read),
      (error) =>
        live &&
        setPreview(
          (error as { status?: number } | null)?.status === 404 ? "gone" : "unread"
        )
    );
    return () => {
      live = false;
    };
  }, [call, trimmed, own]);

  const from = typeof preview === "object" ? preview : undefined;
  const inviter = from?.workspace.owner?.name || from?.workspace.owner?.email || "";
  const said =
    preview === "gone"
      ? m.task_requests_invite_gone()
      : preview === "unread"
        ? m.task_requests_invite_unread()
        : !from
          ? undefined
          : from.own
            ? m.task_requests_invite_own()
            : m.people_accept_from({ name: inviter });

  const accept = () => {
    if (!from || from.own || busy) return;
    setBusy(true);
    call("taskRequests.acceptInvite", {
      invite: trimmed,
      ...(from.back ? { workspace: from.back.workspace.id } : {}),
    }).then(
      () => {
        toast.success(m.people_accepted({ name: inviter }));
        onClose();
      },
      () => {
        setBusy(false);
        toast.error(m.task_requests_failed());
      }
    );
  };

  return (
    <Dialog
      actions={[
        { label: m.people_cancel(), hierarchy: "secondary-gray", onPress: onClose },
        {
          label: m.people_accept(),
          hierarchy: "primary",
          onPress: accept,
          disabled: !from || from.own || busy,
        },
      ]}
      input={{
        "aria-label": m.task_requests_invite_link(),
        autoFocus: true,
        onChange: (event) => setLink(event.target.value),
        placeholder: m.people_add_enter_placeholder(),
        value: link,
        ...(said ? { hint: said } : {}),
        ...(preview === "gone" || preview === "unread" ? { destructive: true } : {}),
      }}
      isOpen
      onClose={onClose}
      title={m.people_add_enter_title()}
      variant="input"
    />
  );
}
