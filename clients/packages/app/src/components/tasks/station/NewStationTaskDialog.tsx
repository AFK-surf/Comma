import type {
  CodingRepo,
  ModelsValue,
  ShownProfile,
  StationProfile,
  TaskRequestRun,
  TaskRequestTarget,
} from "@comma/core/contract";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Dialog, DialogPanel, dialogComposeShell } from "@comma/ui/components/dialog";
import { Button } from "@comma/ui/components/Button";
import type { DropdownItem } from "@comma/ui/components/dropdown";
import {
  BranchIcon,
  CloudIcon,
  CodeIcon,
  GithubBrandIcon,
  LoadingCircleIcon,
  MacbookIcon,
  PaperclipIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { toast } from "@comma/ui/components/toast";
import { cx, isImeKeyEvent } from "@comma/ui/components/utils";
import { useNavigate } from "@tanstack/react-router";
import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import type { AiInputAttachment } from "@comma/ui/components/ai-input";
import { AiInputAttachmentRow } from "@comma/ui/components/ai-input/attachments/AiInputAttachmentRow";
import { AiInputImagePreview } from "@comma/ui/components/ai-input/attachments/AiInputImagePreview";
import { useAttachmentPreview } from "@comma/ui/components/ai-input/attachments/useAttachmentPreview";
import { AiInputDropOverlay } from "@comma/ui/components/ai-input/files/AiInputDropOverlay";
import { useFileDrop } from "@comma/ui/components/ai-input/files/useFileDrop";
import { useFilePaste } from "@comma/ui/components/ai-input/files/useFilePaste";
import { taskToolbarIconButtonClassName } from "@comma/ui/components/task-workspace";
import { nativePlatformClipboard } from "../../../nativePlatformActions";
import {
  attachmentMeta,
  useFileIntake,
  useUploadFailureToast,
} from "../../chat/composer/fileIntake";
import { openTaskTarget } from "../openTaskTarget";
import { useTaskAttachments } from "./useTaskAttachments";
import { RequestPersonAvatar } from "../RequestPersonAvatar";

/** A Task request the window shows as a card: its id, a title for the card, who sent it, and the words it opens with. */
export interface TaskRequestCard {
  id: string;
  title: string;
  /** The sender, shown above the words: their avatar and name. */
  sender?: ReactNode;
  content: string;
}

/** A choice of what to run: a profile of the machine's station, and one of its models (null: the profile's own). */
type Run = { profile: StationProfile; model: string | null };

/** Comma's cloud, among the machines: Salix runs the Task, as the Router's Tasks run. */
const SALIX = "salix";

/**
 * A cloud sandbox of the Task's own, among the machines: a coding session, with a GitHub repository checked out
 * (`coding.start`). It runs Codex or Claude Code on one of the workspace's subscriptions, which it is lent alone: the
 * runtime's own default model, or one the catalog says that subscription serves.
 */
const SANDBOX = "sandbox";
/**
 * The same sandbox with nothing checked out: a plain sandbox Task for work that needs a machine, offered where the
 * deployment has Task sandboxes (`task_place.sandboxes` of the models topic), where the Cloud VM is retired.
 */
const PLAIN_SANDBOX = "plain_sandbox";
const SANDBOX_RUNTIMES = ["codex", "claude"] as const;
type SandboxRuntime = (typeof SANDBOX_RUNTIMES)[number];
type SandboxProfile = ShownProfile;
type SandboxRun = {
  runtime: SandboxRuntime;
  profile: SandboxProfile | null;
  model: string | null;
};

const sandboxRunKey = (run: SandboxRun) =>
  `${run.runtime}\t${run.profile?.id ?? ""}\t${run.model ?? ""}`;

/**
 * What a sandbox may run: for each usable Codex or Claude subscription, the runtime's default and the catalog models
 * that subscription serves. A runtime with no such subscription is offered on its default, on whatever account Salix
 * lends.
 */
function sandboxRunsOf(shown: ModelsValue | undefined): SandboxRun[] {
  const usable = (shown?.profiles ?? []).filter((p) => p.subscription && p.usable);
  return SANDBOX_RUNTIMES.flatMap((runtime): SandboxRun[] => {
    const profiles = usable.filter((p) => p.source === runtime);
    if (profiles.length === 0) return [{ runtime, profile: null, model: null }];
    return profiles.flatMap((profile) => [
      { runtime, profile, model: null },
      ...(shown?.models ?? [])
        .filter((m) => m.serving.includes(profile.id))
        .map((m) => ({ runtime, profile, model: m.id })),
    ]);
  });
}

const repoKey = (repo: CodingRepo) => `${repo.owner}/${repo.name}`;

/** Whose models each runtime runs, for their mark. */
const VENDORS: Record<string, string> = { claude: "anthropic", codex: "openai" };

const runKey = (run: Run) => `${run.profile.id}\t${run.model ?? ""}`;

function runsOf(profiles: readonly StationProfile[]): Run[] {
  return profiles.flatMap((profile) =>
    profile.runtimes.length === 0
      ? []
      : profile.models.length > 0
        ? profile.models.map((model) => ({ profile, model }))
        : [{ profile, model: profile.model }]
  );
}

/**
 * The height of the window's chips and its attach button: the Tasks toolbar's New task button's (3xl and xs).
 * Button's xs is 4xl, so max-h holds a chip to it whatever its stroke (0.5px flat, 1px raised as the Inbox toolbar's
 * buttons) draws as.
 */
const chipHeight = "max-h-[calc(var(--spacing-3xl)+var(--spacing-xs))]";

function propertyChipClass(raised: boolean) {
  return raised
    ? `${chipHeight} shrink-0 gap-xs rounded-full border-primary bg-fg-button px-md py-0 text-xs`
    : `${chipHeight} shrink-0 gap-xs rounded-full border-[0.5px] px-md py-0 text-xs shadow-none`;
}

/**
 * One property of the new Task as a chip, as Linear's New issue sets its own: the chip shows the choice and opens the
 * menu's single-selection pop-up, its checked row over the chip. While the choices load, the chip spins in place of its
 * mark.
 */
function PropertyChip({
  disabled = false,
  items,
  label,
  loading = false,
  onChange,
  raised = false,
  value,
}: {
  disabled?: boolean;
  items: DropdownItem[];
  label: string;
  loading?: boolean;
  onChange: (id: string) => void;
  /** Raised as the Inbox toolbar's buttons are: a 1px stroke on the button fill, with shadow-xs. */
  raised?: boolean;
  value: string | undefined;
}) {
  const triggerRef = useRef<HTMLSpanElement>(null);
  const shown = items.find((item) => item.id === value);
  return (
    <span className="inline-flex shrink-0" ref={triggerRef}>
      <MenuTrigger>
        <Button
          aria-label={label}
          className={propertyChipClass(raised)}
          hierarchy="secondary-gray"
          iconLeading={
            loading && !shown ? (
              <LoadingCircleIcon className="animate-spin" />
            ) : (
              shown?.leading
            )
          }
          isDisabled={disabled}
          size="xs"
        >
          {shown?.label ?? label}
        </Button>
        <MenuPopover
          selectionAlign={{
            items,
            selectedIndex: Math.max(
              items.findIndex((item) => item.id === value),
              0
            ),
            triggerRef,
          }}
        >
          <Menu
            aria-label={label}
            disallowEmptySelection
            onSelectionChange={(keys) => {
              if (keys === "all") return;
              const [key] = Array.from(keys);
              if (key !== undefined) onChange(String(key));
            }}
            selectedKeys={value ? [value] : []}
            selectionMode="single"
            variant="embedded"
          >
            {items.map((item) => (
              <MenuItem
                icon={item.leading}
                id={item.id}
                isDisabled={item.disabled ?? false}
                key={item.id}
                // A row keeps one line, so the checked one opens over the chip.
                note={item.subtitle}
                selectionIndicator="check"
                textValue={item.label}
              >
                <span className="text-primary">{item.label}</span>
              </MenuItem>
            ))}
          </Menu>
        </MenuPopover>
      </MenuTrigger>
    </span>
  );
}

/** What the window makes: a Task here, or a request to a workspace whose invite the person accepted. */
type Kind = "task" | "request";

/** Who a request goes to: the workspace's owner, by name. */
const targetLabel = (target: TaskRequestTarget) =>
  target.workspace.owner?.name ||
  target.workspace.owner?.email ||
  target.workspace.name ||
  target.workspace.id;

/** The owner's avatar, read through the person's grant; their initials without one. */
function TargetAvatar({ target }: { target: TaskRequestTarget }) {
  const owner = target.workspace.owner;
  return (
    <RequestPersonAvatar
      email={owner?.email}
      name={targetLabel(target)}
      source={
        owner?.avatar_id
          ? {
              source: "target-avatar",
              grant: target.grant_id,
              revision: owner.avatar_id,
            }
          : undefined
      }
    />
  );
}

/** A target takes no request now: its daily or waiting limit is reached. */
const targetFull = (target: TaskRequestTarget) =>
  target.sent_today >= target.daily_limit || target.pending >= target.pending_limit;

/** A random key for one Task being made: made again with it (a retry), it is the same Task. */
function newKey() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Makes a Task on one of the workspace's machines (its station hosts it) or in Comma's cloud: the machine, what runs it
 * (a profile and its model, or a model of the workspace's catalog), and the first message. Only machines this device
 * reaches now can be chosen; with none once the machines are known, the cloud is chosen. Each opens as soon as it is
 * made. Where the person may send requests, it can make a request to another person's workspace instead (`requestTo`).
 */
export function NewStationTaskDialog({
  onAccepted,
  onClose,
  request,
  requestTo,
  workspace,
}: {
  /** With a request: where its Task goes once made, instead of opening it among the Tasks. */
  onAccepted?: ((task: { id: string; group_id: string }) => void) | undefined;
  onClose: () => void;
  /**
   * Someone's Task request to this workspace: the window shows as a card (not a dialog) with the request's words, and
   * making the Task accepts the request (`taskRequests.accept`) with the place and model chosen here. It can also go to
   * the Router or be declined. Files cannot be added to it.
   */
  request?: TaskRequestCard | undefined;
  /**
   * Opens as a New request to this target (its `grant_id`). Where the person may send requests, the window's title is a
   * menu that switches between a Task and a request: a request goes to the chosen workspace's owner with the words
   * alone (`taskRequests.send`); its owner chooses where it runs and on what when they accept it.
   */
  requestTo?: string | undefined;
  workspace: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const stationsTopic = useTopic({ topic: "stations", workspace });
  const stations = stationsTopic.value?.stations ?? [];
  const shownModels = useTopic({ topic: "models", prefer: workspace }).value;
  const [chosen, setChosen] = useState<string>();
  const [profiles, setProfiles] = useState<StationProfile[] | null>(null);
  const [profilesFailed, setProfilesFailed] = useState<string>();
  const [run, setRun] = useState<string>();
  const [text, setText] = useState(request?.content ?? "");
  // The message is where the person starts.
  const messageRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    messageRef.current?.focus();
  }, []);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [key, setKey] = useState(newKey);
  const locale = useCommaLocale();
  // Where the person may send requests: the workspaces whose invite they accepted. A request's own card sends none.
  const targetsTopic = useTopic(
    request ? null : { topic: "taskRequests", prefer: workspace }
  );
  const targets = targetsTopic.value?.targets ?? null;
  const [kind, setKind] = useState<Kind>(requestTo ? "request" : "task");
  const asking = kind === "request";
  // The recipient the person chose (or the window was opened for) stays chosen, also once it can take no more
  // requests (Send waits until they choose another); without one, the first who can take one is chosen.
  const [chosenId, setTarget] = useState(requestTo);
  const target = chosenId ?? targets?.find((t) => !targetFull(t))?.grant_id;
  const chosenTarget = targets?.find((t) => t.grant_id === target);
  const canSend = !!chosenTarget && !targetFull(chosenTarget);
  // The first default holds: a later read of the list does not move the request to someone else.
  useEffect(() => {
    if (chosenId === undefined && target !== undefined) setTarget(target);
  }, [chosenId, target]);
  // Two people of one name are told apart by their workspace.
  const targetItems: DropdownItem[] = (targets ?? []).map((t, _i, all) => {
    const label = targetLabel(t);
    const twin = all.some((o) => o !== t && targetLabel(o) === label);
    return {
      id: t.grant_id,
      label,
      leading: <TargetAvatar target={t} />,
      subtitle: [
        twin ? t.workspace.name : null,
        messages.task_requests_sent_today({
          count: String(t.sent_today),
          limit: String(t.daily_limit),
        }),
      ]
        .filter(Boolean)
        .join(" · "),
      disabled: targetFull(t),
    };
  });

  const reached = stations.filter((s) => s.link.state === "online");
  // Once the machines are known, the first one reached is chosen, or the cloud with none; it stays chosen until the
  // person chooses another (none known when they cannot be read). Before then nothing is chosen and nothing goes up.
  const known =
    (stationsTopic.value !== undefined && !stationsTopic.value.loading) ||
    !!stationsTopic.error;
  const firstReached = reached[0]?.id ?? SALIX;
  useEffect(() => {
    if (known) setChosen((current) => current ?? firstReached);
  }, [firstReached, known]);
  const inCloud = chosen === SALIX;
  const inSandbox = chosen === SANDBOX;
  const inPlainSandbox = chosen === PLAIN_SANDBOX;
  const inAnySandbox = inSandbox || inPlainSandbox;
  const sandboxes = shownModels?.agents?.task_place.sandboxes === true;
  // A coding session's repository (one page of the account's, recently pushed first), base branch and runtime.
  const [repos, setRepos] = useState<CodingRepo[] | null>(null);
  const [reposFailed, setReposFailed] = useState<string>();
  const [repo, setRepo] = useState<string>();
  const [branches, setBranches] = useState<string[] | null>(null);
  const [base, setBase] = useState<string>();
  const sandboxRuns = useMemo(() => sandboxRunsOf(shownModels), [shownModels]);
  const [sandboxRun, setSandboxRun] = useState<string>();
  const chosenSandboxRun =
    sandboxRuns.find((r) => sandboxRunKey(r) === sandboxRun) ?? sandboxRuns[0];
  const sandboxProfileCount = new Set(
    sandboxRuns.flatMap((r) => (r.profile ? [r.profile.id] : []))
  ).size;
  const chosenRepo = repos?.find((r) => repoKey(r) === repo) ?? repos?.[0];
  useEffect(() => {
    if (!inSandbox || repos !== null) return undefined;
    let live = true;
    call("coding.repos", { workspaceId: workspace }).then(
      (answer) => live && setRepos(answer),
      (failure: unknown) => {
        if (!live) return;
        const code = (failure as { code?: string }).code;
        setReposFailed(
          code === "github_not_connected"
            ? messages.coding_github_not_connected()
            : (failure as Error).message
        );
      }
    );
    return () => {
      live = false;
    };
  }, [call, inSandbox, messages, repos, workspace]);
  useEffect(() => {
    setBranches(null);
    setBase(undefined);
    if (!inSandbox || !chosenRepo) return undefined;
    let live = true;
    call("coding.branches", {
      workspaceId: workspace,
      owner: chosenRepo.owner,
      name: chosenRepo.name,
    }).then(
      (answer) => live && setBranches(answer),
      () => live && setBranches([])
    );
    return () => {
      live = false;
    };
  }, [call, chosenRepo, inSandbox, workspace]);
  const chosenBase = base ?? chosenRepo?.defaultBranch ?? branches?.[0];
  // The cloud's models: those of the catalog a profile serves, the workspace's default Task model first.
  const cloudModels = useMemo(() => {
    const served = (shownModels?.models ?? []).filter((m) => m.serving.length > 0);
    const selection = shownModels?.agents?.task_model.selection;
    const preferred = selection?.kind === "catalog" ? selection.model : undefined;
    return [
      ...served.filter((m) => m.id === preferred),
      ...served.filter((m) => m.id !== preferred),
    ];
  }, [shownModels]);
  const [cloudModel, setCloudModel] = useState<string>();
  const chosenCloudModel =
    cloudModels.find((m) => m.id === cloudModel) ?? cloudModels[0];
  useEffect(() => {
    setProfiles(null);
    setProfilesFailed(undefined);
    setRun(undefined);
    if (chosen === undefined || inCloud || inAnySandbox) return undefined;
    let live = true;
    call("stations.profiles", { station: chosen, workspace }).then(
      (answer) => live && setProfiles(answer),
      (failure: unknown) => live && setProfilesFailed((failure as Error).message)
    );
    return () => {
      live = false;
    };
  }, [call, chosen, inCloud, inAnySandbox, workspace]);

  const runs = useMemo(() => runsOf(profiles ?? []), [profiles]);
  const profileCount = new Set(runs.map((r) => r.profile.id)).size;
  const chosenRun = runs.find((r) => runKey(r) === run) ?? runs[0];
  const machineItems: DropdownItem[] = [
    {
      id: SALIX,
      label: messages.station_task_cloud(),
      leading: <CloudIcon className="size-4" />,
    },
    {
      id: SANDBOX,
      label: messages.coding_sandbox(),
      leading: <CodeIcon className="size-4" />,
    },
    // A request's Task runs where its acceptance can name (`TaskRequestRun`): no plain sandbox.
    ...(sandboxes && !request
      ? [
          {
            id: PLAIN_SANDBOX,
            label: messages.station_task_sandbox(),
            leading: <CodeIcon className="size-4" />,
          },
        ]
      : []),
    ...stations.map((s) => ({
      id: s.id,
      label: s.name || s.id,
      leading: <MacbookIcon className="size-4" />,
      disabled: s.link.state !== "online",
      ...(s.link.state !== "online"
        ? { subtitle: messages.station_task_offline() }
        : {}),
    })),
  ];
  const repoItems: DropdownItem[] = (repos ?? []).map((r) => ({
    id: repoKey(r),
    label: repoKey(r),
    leading: <GithubBrandIcon className="size-4" />,
  }));
  const branchNames = [
    ...new Set(
      [chosenRepo?.defaultBranch, ...(branches ?? [])].filter((b): b is string => !!b)
    ),
  ];
  const branchItems: DropdownItem[] = branchNames.map((b) => ({
    id: b,
    label: messages.coding_from_branch({ branch: b }),
    leading: <BranchIcon className="size-4" />,
  }));
  const runItems: DropdownItem[] = inAnySandbox
    ? sandboxRuns.map((r) => ({
        id: sandboxRunKey(r),
        // Its default model goes by the runtime's name.
        label:
          r.model !== null
            ? (shownModels?.models?.find((m) => m.id === r.model)?.name ?? r.model)
            : r.runtime === "codex"
              ? messages.coding_runtime_codex()
              : messages.coding_runtime_claude(),
        leading: <ModelVendorIcon vendor={VENDORS[r.runtime]!} />,
        // The subscription it runs on, where the workspace has more than one.
        ...(sandboxProfileCount > 1 && r.profile
          ? { subtitle: r.profile.name ?? r.profile.email ?? r.profile.source }
          : {}),
      }))
    : inCloud
      ? cloudModels.map((m) => ({
          id: m.id,
          label: m.name,
          leading: <ModelVendorIcon vendor={m.vendor} />,
        }))
      : runs.map((r) => ({
          id: runKey(r),
          label: r.model ?? messages.station_task_default_model(),
          leading: (
            <ModelVendorIcon
              vendor={VENDORS[r.profile.runtimes[0] ?? ""] ?? "openai"}
            />
          ),
          // The profile names whose account runs it, where the machine has more than one.
          ...(profileCount > 1 ? { subtitle: r.profile.name } : {}),
        }));
  // The files go where the Task runs, each as it is added, as the composer's go up. A sandbox Task's (a coding
  // session's or a plain one's) go up as the cloud's do, to the Router chat: its sandbox's station fetches those its
  // first message names.
  const files = useTaskAttachments({
    cloud: SALIX,
    place: inAnySandbox ? SALIX : chosen,
    workspace,
  });
  // While the Task is being made, its files are those it goes with: none is added or taken away.
  const { attach, remove, retry } = files;
  // A request goes with its words alone: it takes no files.
  const attachFiles = useCallback(
    (added: Parameters<typeof attach>[0]) => {
      if (!pending && !asking) attach(added);
    },
    [asking, attach, pending]
  );
  const removeFile = useCallback(
    (id: string) => {
      if (!pending) remove(id);
    },
    [pending, remove]
  );
  const retryFile = useCallback(
    (id: string) => {
      if (!pending) retry(id);
    },
    [pending, retry]
  );
  const intake = useFileIntake({ onAttachFiles: attachFiles });
  const { handlePaste } = useFilePaste({
    clipboard: nativePlatformClipboard,
    onPasteFiles: intake.transferFiles,
  });
  const { dropActive, shellDropProps } = useFileDrop(
    asking ? undefined : intake.transferFiles
  );
  useUploadFailureToast(
    files.attachments,
    `new-task-upload-error-${useId()}`,
    retryFile,
    removeFile
  );
  const fileTiles = useMemo<AiInputAttachment[]>(
    () =>
      files.attachments.map((attachment) => {
        const meta = attachmentMeta(
          attachment,
          locale,
          messages.chat_uploading(),
          messages.chat_upload_failed()
        );
        return {
          id: attachment.id,
          name: attachment.name,
          onRemove: () => removeFile(attachment.id),
          onRetry: () => retryFile(attachment.id),
          state:
            attachment.status === "failed"
              ? "error"
              : attachment.status === "uploading"
                ? "loading"
                : "ready",
          type: attachment.isImage ? "image" : "file",
          ...(meta ? { meta } : {}),
          ...(attachment.thumbnail ? { thumbnailSrc: attachment.thumbnail } : {}),
        };
      }),
    [files.attachments, locale, messages, removeFile, retryFile]
  );
  const preview = useAttachmentPreview(fileTiles);
  const fileRowRef = useRef<HTMLDivElement>(null);

  const body = text.trim();
  const ready =
    chosen !== undefined &&
    (inSandbox
      ? !!chosenRepo
      : inPlainSandbox
        ? true
        : inCloud
          ? !!chosenCloudModel
          : !!chosenRun);
  // A file still uploading goes with the Task, which waits for it; a failed one holds it back.
  const hasContent = body !== "" || files.attachments.length > 0;
  const send = async () => {
    if (!chosenTarget || !canSend || body === "" || pending) return;
    setPending(true);
    setError(undefined);
    try {
      await call("taskRequests.send", {
        grant: chosenTarget.grant_id,
        content: body,
        key,
        workspace,
      });
      onClose();
      toast.success(
        messages.task_requests_sent_to({ name: targetLabel(chosenTarget) })
      );
    } catch (failure) {
      setError((failure as Error).message || messages.task_requests_failed());
    } finally {
      setPending(false);
    }
  };
  const create = async () => {
    if (asking) return send();
    if (!ready || !hasContent || files.anyFailed || pending) return;
    setPending(true);
    setError(undefined);
    try {
      if (request) {
        const requestRun: TaskRequestRun | undefined = inSandbox
          ? chosenRepo && {
              kind: "sandbox",
              repo: {
                owner: chosenRepo.owner,
                name: chosenRepo.name,
                ...(chosenBase ? { baseRef: chosenBase } : {}),
              },
              provider: chosenSandboxRun?.runtime ?? "codex",
              ...(chosenSandboxRun?.model ? { model: chosenSandboxRun.model } : {}),
              ...(chosenSandboxRun?.profile
                ? { accountId: chosenSandboxRun.profile.id }
                : {}),
            }
          : inCloud
            ? chosenCloudModel && { kind: "cloud", model: chosenCloudModel.id }
            : chosenRun && chosen !== undefined
              ? {
                  kind: "station",
                  station: chosen,
                  provider: chosenRun.profile.runtimes[0]!,
                  ...(chosenRun.model ? { model: chosenRun.model } : {}),
                }
              : undefined;
        if (!requestRun) return;
        const accepted = await call("taskRequests.accept", {
          workspace,
          request: request.id,
          to: "task",
          content: body,
          run: requestRun,
        });
        if (onAccepted && accepted.task?.group_id) {
          onAccepted({ id: accepted.task.id, group_id: accepted.task.group_id });
          return;
        }
        onClose();
        if (accepted.task?.group_id)
          await navigate(
            openTaskTarget({
              conversationId: accepted.task.id,
              groupId: accepted.task.group_id,
              workspaceId: workspace,
            })
          );
        return;
      }
      const uploads = await files.uploads();
      if (inAnySandbox) {
        if (inSandbox && !chosenRepo) return;
        const made = await call("coding.start", {
          workspaceId: workspace,
          key,
          text: body,
          ...(uploads.length > 0
            ? { uploads: uploads.map(({ name, path }) => ({ name, path })) }
            : {}),
          // A plain sandbox Task checks nothing out.
          ...(inSandbox && chosenRepo
            ? {
                repo: {
                  owner: chosenRepo.owner,
                  name: chosenRepo.name,
                  ...(chosenBase ? { baseRef: chosenBase } : {}),
                },
              }
            : {}),
          model: {
            provider: chosenSandboxRun?.runtime ?? "codex",
            ...(chosenSandboxRun?.model ? { model: chosenSandboxRun.model } : {}),
          },
          ...(chosenSandboxRun?.profile
            ? { accountId: chosenSandboxRun.profile.id }
            : {}),
        });
        onClose();
        await navigate(
          openTaskTarget({
            conversationId: made.taskId,
            groupId: made.groupId,
            workspaceId: workspace,
          })
        );
        return;
      }
      if (inCloud) {
        const made = await call("chat.startTask", {
          workspaceId: workspace,
          key,
          model: { id: chosenCloudModel!.id, name: chosenCloudModel!.name },
          text: body,
          ...(uploads.length > 0
            ? { uploads: uploads.map(({ name, path }) => ({ name, path })) }
            : {}),
        });
        onClose();
        await navigate(
          openTaskTarget({
            conversationId: made.conversationId,
            groupId: made.groupId,
            workspaceId: workspace,
          })
        );
        return;
      }
      if (!chosenRun || chosen === undefined) return;
      const made = await call("stations.newTask", {
        key,
        profile: chosenRun.profile.id,
        runtime: chosenRun.profile.runtimes[0]!,
        station: chosen,
        text: body,
        workspace,
        ...(chosenRun.model ? { model: chosenRun.model } : {}),
        ...(uploads.length > 0 ? { attachments: uploads } : {}),
      });
      onClose();
      await navigate(
        openTaskTarget({
          conversationId: made.conversationId,
          groupId: made.groupId,
          workspaceId: workspace,
        })
      );
    } catch (failure) {
      const code = (failure as { code?: string }).code;
      // A Task refused is not made: another try is another Task. Any other failure may have made it, so another try
      // keeps the key and gets that Task.
      if (code === "refused") setKey(newKey());
      setError(
        code === "machine_offline"
          ? messages.station_task_machine_offline()
          : code === "github_not_connected"
            ? messages.coding_github_not_connected()
            : code === "task_unavailable"
              ? messages.station_task_create_failed()
              : (failure as Error).message || messages.station_task_create_failed()
      );
    } finally {
      setPending(false);
    }
  };

  // Where it runs leads the title, as the team leads Linear's New issue; a request's, whom it goes to.
  const titleLeading = asking ? (
    <PropertyChip
      disabled={pending || targetItems.length === 0}
      items={targetItems}
      label={messages.task_requests_recipient()}
      loading={targets === null}
      onChange={setTarget}
      value={chosenTarget?.grant_id}
    />
  ) : (
    <PropertyChip
      disabled={pending}
      items={machineItems}
      label={messages.station_task_machine()}
      loading={!known}
      onChange={setChosen}
      value={chosen}
    />
  );
  // Where the person may send requests, the title is a chip as the place's is: it switches what the window makes.
  const title =
    !request && (asking || (targets?.length ?? 0) > 0) ? (
      <PropertyChip
        disabled={pending}
        items={[
          { id: "task", label: messages.station_task_new() },
          { id: "request", label: messages.station_task_new_request() },
        ]}
        label={messages.station_task_kind()}
        onChange={(next) => {
          if (next !== "task" && next !== "request") return;
          setKind(next);
          setError(undefined);
        }}
        value={kind}
      />
    ) : (
      messages.station_task_new()
    );
  const answer = (to: "router" | "decline") => {
    if (!request || pending) return;
    setPending(true);
    setError(undefined);
    void (
      to === "router"
        ? call("taskRequests.accept", {
            workspace,
            request: request.id,
            to: "router",
            content: body,
          })
        : call("taskRequests.decline", { workspace, request: request.id })
    ).then(
      () => {
        setPending(false);
        onClose();
      },
      (failure: unknown) => {
        setPending(false);
        setError((failure as Error).message || messages.task_requests_failed());
      }
    );
  };
  const form = (
    <>
      {/* Not positioned: the drop overlay covers the whole window, inset as on the composer. */}
      <div
        className="flex flex-col gap-lg"
        data-drop-active={dropActive ? "true" : undefined}
        data-testid="new-station-task"
        {...shellDropProps}
      >
        {intake.fileInput}
        {request?.sender ?? null}
        <textarea
          aria-label={messages.station_task_first_message()}
          ref={messageRef}
          className="min-h-[calc(var(--text-sm--line-height)*3)] w-full resize-none border-0 bg-transparent p-0 text-sm text-primary outline-none placeholder:text-placeholder"
          onChange={(event) => setText(event.target.value)}
          readOnly={pending}
          // ⌘↵ makes it from the message, as Linear's does; ↵ alone is a new line.
          onKeyDown={(event) => {
            if (event.key !== "Enter" || !(event.metaKey || event.ctrlKey)) return;
            if (isImeKeyEvent(event.nativeEvent)) return;
            event.preventDefault();
            void create();
          }}
          onPaste={handlePaste}
          placeholder={messages.station_task_first_message()}
          value={text}
        />
        {request || asking ? null : (
          <AiInputAttachmentRow
            attachments={fileTiles}
            onRemove={(attachment) => removeFile(attachment.id)}
            preview={preview}
            rowRef={fileRowRef}
          />
        )}
        {error || (!asking && (profilesFailed || (inSandbox && reposFailed))) ? (
          <p className="m-0 text-sm text-error-primary" role="alert">
            {error ?? (inSandbox ? reposFailed : profilesFailed)}
          </p>
        ) : null}
        {/* Its files and what runs it, beside the button that makes it. A request has neither: its owner picks what runs it. */}
        <div className="flex items-center gap-md">
          {asking ? (
            <Button
              className="ml-auto"
              hierarchy="primary"
              {...(pending
                ? { iconLeading: <LoadingCircleIcon className="animate-spin" /> }
                : {})}
              isDisabled={pending || !canSend || body === ""}
              onPress={() => void send()}
              size="xs"
            >
              {messages.task_requests_send()}
            </Button>
          ) : (
            <>
              {request ? null : (
                <AriaButton
                  aria-label={messages.chat_add_attachment()}
                  // The Inbox toolbar's button, as tall as the chips beside it.
                  className={cx(
                    taskToolbarIconButtonClassName,
                    "size-[calc(var(--spacing-3xl)+var(--spacing-xs))] [&_svg]:size-4"
                  )}
                  data-testid="new-station-task-attach"
                  isDisabled={pending}
                  onPress={() => void intake.attachPress?.()}
                >
                  <PaperclipIcon />
                </AriaButton>
              )}
              {/* A coding session picks its repository; a plain sandbox Task has none to pick. */}
              {inPlainSandbox ? null : inSandbox ? (
                <>
                  <PropertyChip
                    disabled={pending || repoItems.length === 0}
                    items={repoItems}
                    label={
                      repos?.length === 0
                        ? messages.coding_repo_none()
                        : messages.coding_repo()
                    }
                    loading={repos === null && !reposFailed}
                    onChange={setRepo}
                    raised
                    value={chosenRepo ? repoKey(chosenRepo) : undefined}
                  />
                  <PropertyChip
                    disabled={pending || branchItems.length === 0}
                    items={branchItems}
                    label={messages.coding_base_branch()}
                    loading={!!chosenRepo && branches === null}
                    onChange={setBase}
                    raised
                    value={chosenBase}
                  />
                </>
              ) : null}
              <PropertyChip
                disabled={pending || runItems.length === 0}
                items={runItems}
                label={messages.station_task_model()}
                loading={
                  chosen === undefined
                    ? false
                    : inAnySandbox || inCloud
                      ? !shownModels?.catalog && !shownModels?.error
                      : profiles === null && !profilesFailed
                }
                onChange={
                  inAnySandbox ? setSandboxRun : inCloud ? setCloudModel : setRun
                }
                raised
                value={
                  inAnySandbox
                    ? chosenSandboxRun
                      ? sandboxRunKey(chosenSandboxRun)
                      : undefined
                    : inCloud
                      ? chosenCloudModel?.id
                      : chosenRun
                        ? runKey(chosenRun)
                        : undefined
                }
              />
              {request ? (
                <>
                  {/* Declining is the quiet choice: no stroke or shadow, its hover only. */}
                  <Button
                    className="ml-auto"
                    hierarchy="tertiary-gray"
                    isDisabled={pending}
                    onPress={() => answer("decline")}
                    size="xs"
                  >
                    {messages.task_requests_decline()}
                  </Button>
                  <Button
                    hierarchy="secondary-gray"
                    isDisabled={pending || !hasContent}
                    onPress={() => answer("router")}
                    size="xs"
                  >
                    {messages.task_requests_to_router()}
                  </Button>
                </>
              ) : null}
              <Button
                {...(request ? {} : { className: "ml-auto" })}
                hierarchy="primary"
                // While the Task is made (its files still going up first), the button spins.
                {...(pending
                  ? { iconLeading: <LoadingCircleIcon className="animate-spin" /> }
                  : {})}
                isDisabled={pending || !ready || !hasContent || files.anyFailed}
                onPress={() => void create()}
                size="xs"
              >
                {request
                  ? messages.task_requests_accept()
                  : messages.station_task_create()}
              </Button>
            </>
          )}
        </div>
        <AiInputDropOverlay
          active={dropActive}
          subtitle={messages.ui_ai_drop_types_hint()}
          title={messages.ui_ai_drop_anything_here()}
        />
        <AiInputImagePreview {...preview.dialogProps} />
      </div>
    </>
  );

  if (request)
    return (
      <section
        aria-label={request.title}
        // Where the Task's message box would be: as wide as it.
        className={cx(dialogComposeShell, "w-full")}
        data-testid="task-request-card"
      >
        <DialogPanel
          title={request.title}
          titleLeading={titleLeading}
          variant="compose"
        >
          {form}
        </DialogPanel>
      </section>
    );

  return (
    <Dialog
      isOpen
      showCloseButton
      title={title}
      titleLeading={titleLeading}
      variant="compose"
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
    >
      {form}
    </Dialog>
  );
}
