import { useCallback, useEffect, useState } from "react";
import {
  useCall,
  useTopic,
  type TaskRequestIncoming,
  type TaskRequestPerson,
  type TaskRequestStatus,
} from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { MoreHorizontalIcon, PlusIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import {
  FeishuProviderLogo,
  LarkProviderLogo,
  SlackProviderLogo,
} from "@comma/ui/components/provider-brand-logos";
import { toast } from "@comma/ui/components/toast";
import {
  type SettingsCategoryDefinition,
  type SettingsCategoryDetail,
} from "@comma/ui/components/settings";
import { type SettingsPanelItem } from "@comma/ui/components/settings-panel";
import { useWorkspacePreference } from "../activeWorkspace";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { useNewTaskDialog } from "./station/NewTaskDialogContext";
import { useNearbyPeople } from "../nearby/useNearbyPeople";

type Detail =
  | { kind: "review"; request: TaskRequestIncoming; title: string }
  /** An invite link: whose it is, once read (`gone` when it no longer works, `unread` when the read failed). */
  | { kind: "invite"; link: string; from?: InviteFrom | "gone" | "unread" | undefined }
  /** A chat account link a Router posted: who it names, once read. */
  | { kind: "link"; link: string; account?: { provider: string; name: string | null } };

type InviteFrom = {
  workspace: { name: string | null; owner: TaskRequestPerson | null };
  own: boolean;
  back: {
    workspace: { id: string; name: string | null };
    mode: "review" | "auto_accept";
  } | null;
};

const personName = (person: TaskRequestPerson | null | undefined) =>
  person?.name || person?.email || "";

/** A chat app by its provider id, as people know it. */
const providerName = (provider: string) =>
  ({ slack: "Slack", feishu: "Feishu", lark: "Lark", telegram: "Telegram" })[
    provider
  ] ?? provider;

const providerLogo = (provider: string) =>
  ({
    slack: <SlackProviderLogo />,
    feishu: <FeishuProviderLogo />,
    lark: <LarkProviderLogo />,
  })[provider];

/**
 * Settings › Task requests. As the workspace's owner: the requests waiting for
 * a decision (each runs only once accepted, as an ordinary Task), and who may
 * send them (invite links and the people who accepted one, each set to approve
 * every request or accept them automatically). As a sender: the workspaces
 * whose invite the person accepted, and what they sent. The core reads both
 * sides while the page shows (`taskRequests`); each change is one of its calls.
 */
export function useTaskRequestsCategory(
  enabled: boolean,
  /** An invite link's token from the URL: the page opens with it filled in. */
  invite?: string | null,
  /** A chat account link's token from the URL: the page opens to confirm it. */
  link?: string | null
): SettingsCategoryDefinition {
  const m = useCommaMessages();
  const locale = useCommaLocale();
  const call = useCall();
  const prefer = useWorkspacePreference();
  const newTask = useNewTaskDialog();
  const { value } = useTopic(
    enabled && prefer !== undefined ? { topic: "taskRequests", prefer } : null
  );
  const workspace = value?.workspace ?? undefined;
  const [busy, setBusy] = useState(false);
  const nearby = useNearbyPeople(workspace);
  const [detail, setDetail] = useState<Detail>();

  useEffect(() => {
    if (!enabled) setDetail(undefined);
  }, [enabled]);
  useEffect(() => {
    if (enabled && invite) setDetail({ kind: "invite", link: invite });
  }, [enabled, invite]);
  // Whose invite the link is and what accepting it here gives the inviter, read for each link the page shows or the
  // person pastes and each workspace the page settles on.
  const inviteLink = detail?.kind === "invite" ? detail.link.trim() : "";
  const pageRead = value != null;
  useEffect(() => {
    if (!inviteLink || !pageRead) return undefined;
    let live = true;
    const shown = (from: InviteFrom | "gone" | "unread" | undefined) =>
      live &&
      setDetail((was) =>
        was?.kind === "invite" && was.link.trim() === inviteLink
          ? { ...was, from }
          : was
      );
    shown(undefined);
    call("taskRequests.invitePreview", {
      invite: inviteLink,
      ...(workspace ? { workspace } : {}),
    }).then(shown, (error) => {
      // A link the server no longer knows is gone; any other failure leaves the link unread.
      shown((error as { status?: number } | null)?.status === 404 ? "gone" : "unread");
    });
    return () => {
      live = false;
    };
  }, [call, inviteLink, pageRead, workspace]);
  useEffect(() => {
    if (!enabled || !link) return undefined;
    let live = true;
    setDetail({ kind: "link", link });
    call("taskRequests.linkPreview", { link }).then(
      (account) => live && setDetail({ kind: "link", link, account }),
      () => live && toast.error(m.task_requests_link_gone())
    );
    return () => {
      live = false;
    };
  }, [call, enabled, link, m]);

  const run = useCallback(
    async (write: () => Promise<unknown>) => {
      setBusy(true);
      try {
        await write();
        return true;
      } catch {
        toast.error(m.task_requests_failed());
        return false;
      } finally {
        setBusy(false);
      }
    },
    [m]
  );

  const statusLabel = (status: TaskRequestStatus) => {
    switch (status) {
      case "pending":
        return m.task_requests_status_pending();
      case "accepted":
        return m.task_requests_status_accepted();
      case "declined":
        return m.task_requests_status_declined();
      case "withdrawn":
        return m.task_requests_status_withdrawn();
      default:
        return m.task_requests_status_expired();
    }
  };
  const date = (seconds: number | null | undefined) =>
    seconds ? new Date(seconds * 1000).toLocaleString(locale) : "";

  const createInvite = () => {
    if (!workspace) return;
    void run(async () => {
      const { inviteUrl } = await call("taskRequests.createInvite", {
        workspace,
        mode: "review",
      });
      await nativePlatformClipboard.writeText(inviteUrl);
      toast.success(m.task_requests_invite_copied());
    });
  };

  const incomingRows: SettingsPanelItem[] = (value?.incoming ?? []).map((request) => ({
    id: `task-requests.incoming.${request.id}`,
    title: request.title,
    description: [
      m.task_requests_from({ name: personName(request.sender) }),
      date(request.created_at),
    ]
      .filter(Boolean)
      .join(" · "),
    control: {
      type: "button",
      label: m.task_requests_review(),
      disabled: busy,
      onPress: () => setDetail({ kind: "review", request, title: request.title }),
    },
  }));
  if (value?.incoming && incomingRows.length === 0)
    incomingRows.push({
      id: "task-requests.incoming.empty",
      title: m.task_requests_incoming_empty(),
    });

  const grantRows: SettingsPanelItem[] = (value?.grants ?? []).map((grant) => {
    const mode =
      grant.mode === "auto_accept"
        ? m.task_requests_mode_auto()
        : m.task_requests_mode_review();
    const revoke = {
      id: "revoke",
      label: m.task_requests_revoke(),
      tone: "destructive" as const,
      onPress: () =>
        workspace &&
        void run(() =>
          call("taskRequests.revokeGrant", { workspace, grant: grant.id })
        ),
    };
    if (grant.status === "invited")
      return {
        id: `task-requests.grant.${grant.id}`,
        title: m.task_requests_open_invite(),
        description: m.task_requests_invite_expires({
          date: date(grant.invite_expires_at),
        }),
        control: {
          type: "menu",
          label: m.task_requests_manage(),
          icon: <MoreHorizontalIcon />,
          disabled: busy,
          items: [
            {
              id: "copy",
              label: m.task_requests_copy_link(),
              onPress: () =>
                grant.invite_url &&
                void nativePlatformClipboard
                  .writeText(grant.invite_url)
                  .then(() => toast.success(m.task_requests_invite_copied())),
            },
            revoke,
          ],
        },
      };
    const other = grant.mode === "auto_accept" ? "review" : "auto_accept";
    return {
      id: `task-requests.grant.${grant.id}`,
      title: personName(grant.grantee),
      description: m.task_requests_limits({ mode, daily: String(grant.daily_limit) }),
      control: {
        type: "menu",
        label: m.task_requests_manage(),
        icon: <MoreHorizontalIcon />,
        disabled: busy,
        items: [
          {
            id: "mode",
            label:
              other === "auto_accept"
                ? m.task_requests_switch_auto()
                : m.task_requests_switch_review(),
            onPress: () =>
              workspace &&
              void run(() =>
                call("taskRequests.setMode", {
                  workspace,
                  grant: grant.id,
                  mode: other,
                })
              ),
          },
          revoke,
        ],
      },
    };
  });
  if (value?.grants && grantRows.length === 0)
    grantRows.push({
      id: "task-requests.grants.empty",
      title: m.task_requests_senders_empty(),
    });

  const targetRows: SettingsPanelItem[] = (value?.targets ?? []).map((target) => ({
    id: `task-requests.target.${target.grant_id}`,
    title: [personName(target.workspace.owner), target.workspace.name]
      .filter(Boolean)
      .join(" · "),
    description: m.task_requests_sent_today({
      count: String(target.sent_today),
      limit: String(target.daily_limit),
    }),
    // A request is written in the New task window, as a New request to this target.
    control: {
      type: "button",
      label: m.task_requests_send(),
      disabled: busy || !newTask.available,
      onPress: () => newTask.open(undefined, { requestTo: target.grant_id }),
    },
  }));
  if (value?.targets && targetRows.length === 0)
    targetRows.push({
      id: "task-requests.targets.empty",
      title: m.task_requests_targets_empty(),
    });

  const sentRows: SettingsPanelItem[] = (value?.sent ?? []).map((sent) => ({
    id: `task-requests.sent.${sent.id}`,
    title: sent.title,
    description: [
      personName(sent.workspace?.owner),
      statusLabel(sent.status),
      sent.decline_reason ?? "",
      sent.reply ?? "",
    ]
      .filter(Boolean)
      .join(" · "),
    ...(sent.status === "pending"
      ? {
          control: {
            type: "button" as const,
            label: m.task_requests_withdraw(),
            disabled: busy,
            onPress: () =>
              void run(() => call("taskRequests.withdraw", { request: sent.id })),
          },
        }
      : {}),
  }));
  if (value?.sent && sentRows.length === 0)
    sentRows.push({
      id: "task-requests.sent.empty",
      title: m.task_requests_sent_empty(),
    });

  if (value?.error)
    incomingRows.push({
      id: "task-requests.error",
      title: m.task_requests_failed(),
      control: {
        type: "button",
        label: m.tasks_archive_retry(),
        onPress: () => void call("taskRequests.refresh", {}).catch(() => undefined),
      },
    });

  const linkRows: SettingsPanelItem[] = (value?.links ?? []).map((linked) => ({
    id: `task-requests.link.${linked.id}`,
    title: linked.name ?? providerName(linked.provider),
    ...(providerLogo(linked.provider) ? { icon: providerLogo(linked.provider) } : {}),
    // Which account it is: the chat app, its email, its organization and the
    // bot, which tell apart two links of one person on one chat app.
    description: [
      m.task_requests_link_account({ provider: providerName(linked.provider) }),
      linked.email,
      linked.workspace,
      linked.bot,
    ]
      .filter(Boolean)
      .join(" · "),
    control: {
      type: "button",
      label: m.task_requests_unlink(),
      disabled: busy,
      onPress: () => void run(() => call("taskRequests.removeLink", { id: linked.id })),
    },
  }));
  if (value?.links && linkRows.length === 0)
    linkRows.push({
      id: "task-requests.links.empty",
      title: m.task_requests_links_empty(),
    });
  // How the workspace takes the person's own requests, sent from a linked chat account.
  if (workspace && value?.own)
    linkRows.push({
      id: "task-requests.own",
      title: m.task_requests_own_auto(),
      description: m.task_requests_own_auto_description(),
      control: {
        type: "toggle",
        checked: value.own === "auto_accept",
        disabled: busy,
        onChange: (event) =>
          void run(() =>
            call("taskRequests.setOwnMode", {
              workspace,
              mode: event.target.checked ? "auto_accept" : "review",
            })
          ),
      },
    });

  const category: SettingsCategoryDefinition = {
    id: "task-requests",
    icon: "task-requests",
    keywords: ["task request", "invite", "delegate", "请求", "邀请"],
    label: m.task_requests(),
    sections: [
      {
        id: "task-requests.incoming",
        title: m.task_requests_incoming(),
        items: incomingRows,
      },
      {
        id: "task-requests.senders",
        title: m.task_requests_senders(),
        // Where Comma can look nearby, one Add offers both ways of giving an invite.
        titleAction: nearby.available ? (
          <>
            <MenuTrigger>
              <Button
                hierarchy="secondary-gray"
                iconLeading={<PlusIcon />}
                isDisabled={busy}
                size="sm"
              >
                {m.task_requests_add()}
              </Button>
              <MenuPopover placement="bottom end">
                <Menu>
                  <MenuItem id="nearby" onAction={nearby.open}>
                    {m.nearby_dialog_title()}
                  </MenuItem>
                  <MenuItem id="link" onAction={createInvite}>
                    {m.task_requests_create_invite()}
                  </MenuItem>
                </Menu>
              </MenuPopover>
            </MenuTrigger>
            {nearby.dialog}
          </>
        ) : (
          <Button
            hierarchy="secondary-gray"
            iconLeading={<PlusIcon />}
            isDisabled={!workspace || busy}
            onPress={createInvite}
            size="sm"
          >
            {m.task_requests_create_invite()}
          </Button>
        ),
        items: grantRows,
      },
      {
        id: "task-requests.targets",
        title: m.task_requests_targets(),
        titleAction: (
          <Button
            hierarchy="secondary-gray"
            iconLeading={<PlusIcon />}
            isDisabled={busy}
            onPress={() => setDetail({ kind: "invite", link: "" })}
            size="sm"
          >
            {m.task_requests_enter_invite()}
          </Button>
        ),
        items: targetRows,
      },
      { id: "task-requests.sent", title: m.task_requests_sent(), items: sentRows },
      {
        id: "task-requests.links",
        title: m.task_requests_links(),
        items: linkRows,
      },
    ],
  };

  const back = { backLabel: m.task_requests(), onBack: () => setDetail(undefined) };
  let view: SettingsCategoryDetail | undefined;
  if (detail?.kind === "review") {
    const accept = (to: "task" | "router" = "task") =>
      workspace &&
      void run(() =>
        call("taskRequests.accept", {
          workspace,
          request: detail.request.id,
          to,
          ...(detail.title.trim() ? { title: detail.title.trim() } : {}),
        })
      ).then((done) => done && setDetail(undefined));
    view = {
      id: "task-requests.review",
      title: m.task_requests_from({ name: personName(detail.request.sender) }),
      description: (
        <span className="whitespace-pre-wrap">{detail.request.content}</span>
      ),
      ...back,
      onSubmit: () => accept(),
      actions: (
        <>
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() =>
              workspace &&
              void run(() =>
                call("taskRequests.decline", { workspace, request: detail.request.id })
              ).then((done) => done && setDetail(undefined))
            }
            size="sm"
          >
            {m.task_requests_decline()}
          </Button>
          <Button
            hierarchy="secondary-gray"
            isDisabled={busy}
            onPress={() => accept("router")}
            size="sm"
          >
            {m.task_requests_to_router()}
          </Button>
          <Button
            hierarchy="primary"
            isDisabled={busy}
            onPress={() => accept()}
            size="sm"
          >
            {m.task_requests_accept()}
          </Button>
        </>
      ),
      content: (
        <InputField
          label={m.task_requests_title_label()}
          onChange={(event) => setDetail({ ...detail, title: event.target.value })}
          value={detail.title}
        />
      ),
    };
  } else if (detail?.kind === "invite") {
    const from = typeof detail.from === "object" ? detail.from : undefined;
    const inviter = personName(from?.workspace.owner) || from?.workspace.name || "";
    // Accepted only once the page has said what it gives the inviter, in the workspace it named.
    const accept = () => {
      if (!from || from.own) return;
      void run(async () => {
        const { reciprocal } = await call("taskRequests.acceptInvite", {
          invite: detail.link.trim(),
          ...(from.back ? { workspace: from.back.workspace.id } : {}),
        });
        toast.success(
          reciprocal
            ? m.task_requests_invite_accepted({ name: inviter })
            : m.task_requests_invite_accepted_one_way({ name: inviter })
        );
      }).then((done) => done && setDetail(undefined));
    };
    const theirs = from?.workspace.name || inviter;
    const ours = from?.back?.workspace.name || m.task_requests_invite_your_workspace();
    view = {
      id: "task-requests.invite",
      title: m.task_requests_enter_invite(),
      description:
        detail.from === "gone"
          ? m.task_requests_invite_gone()
          : detail.from === "unread"
            ? m.task_requests_invite_unread()
            : from?.own
              ? m.task_requests_invite_own()
              : !from
                ? undefined
                : !from.back
                  ? m.task_requests_invite_from_one_way({
                      name: inviter,
                      workspace: theirs,
                    })
                  : from.back.mode === "auto_accept"
                    ? m.task_requests_invite_from_auto({
                        name: inviter,
                        workspace: theirs,
                        own: ours,
                      })
                    : m.task_requests_invite_from_review({
                        name: inviter,
                        workspace: theirs,
                        own: ours,
                      }),
      ...back,
      onSubmit: accept,
      actions: (
        <Button
          hierarchy="primary"
          isDisabled={busy || !from || from.own}
          onPress={accept}
          size="sm"
        >
          {m.task_requests_enter_invite()}
        </Button>
      ),
      content: (
        <InputField
          label={m.task_requests_invite_link()}
          onChange={(event) => setDetail({ kind: "invite", link: event.target.value })}
          value={detail.link}
        />
      ),
    };
  } else if (detail?.kind === "link") {
    const linkUp = () =>
      void run(() => call("taskRequests.acceptLink", { link: detail.link })).then(
        (done) => done && setDetail(undefined)
      );
    view = {
      id: "task-requests.link",
      title: m.task_requests_link_title(),
      description: detail.account
        ? m.task_requests_link_confirm({
            provider: providerName(detail.account.provider),
            name: detail.account.name ?? "",
          })
        : undefined,
      ...back,
      onSubmit: linkUp,
      actions: (
        <Button
          hierarchy="primary"
          isDisabled={busy || !detail.account}
          onPress={linkUp}
          size="sm"
        >
          {m.task_requests_link_accept()}
        </Button>
      ),
    };
  }

  return view ? { ...category, detail: view } : category;
}
