import type { StationProfile } from "@comma/core/contract";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui/components/dialog";
import { Button } from "@comma/ui/components/Button";
import { Dropdown, type DropdownItem } from "@comma/ui/components/dropdown";
import { MacbookIcon } from "@comma/ui/components/icons";
import { ModelVendorIcon } from "@comma/ui/components/model-icons/ModelVendorIcon";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useMemo, useRef, useState } from "react";

/** A choice of what to run: a profile of the machine's station, and one of its models (null: the profile's own). */
type Run = { profile: StationProfile; model: string | null };

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

/** A random key for one Task being made: made again with it (a retry), it is the same Task. */
function newKey() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Makes a Task on one of the workspace's machines (its station hosts it): the machine, what runs it (a profile and its
 * model), and the first message. Only machines this device reaches now can be chosen.
 */
export function NewStationTaskDialog({
  onClose,
  workspace,
}: {
  onClose: () => void;
  workspace: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const stations = useTopic({ topic: "stations", workspace }).value?.stations ?? [];
  const [station, setStation] = useState<string>();
  const [profiles, setProfiles] = useState<StationProfile[] | null>(null);
  const [profilesFailed, setProfilesFailed] = useState<string>();
  const [run, setRun] = useState<string>();
  const [text, setText] = useState("");
  // The message is where the person starts.
  const messageRef = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    messageRef.current?.focus();
  }, []);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();
  const [key] = useState(newKey);

  const reached = stations.filter((s) => s.link.state === "online");
  // The first machine reached is chosen until the person chooses another.
  const chosen = station ?? reached[0]?.id;
  useEffect(() => {
    setProfiles(null);
    setProfilesFailed(undefined);
    setRun(undefined);
    if (!chosen) return undefined;
    let live = true;
    call("stations.profiles", { station: chosen, workspace }).then(
      (answer) => live && setProfiles(answer),
      (failure: unknown) => live && setProfilesFailed((failure as Error).message)
    );
    return () => {
      live = false;
    };
  }, [call, chosen, workspace]);

  const runs = useMemo(() => runsOf(profiles ?? []), [profiles]);
  const profileCount = new Set(runs.map((r) => r.profile.id)).size;
  const chosenRun = runs.find((r) => runKey(r) === run) ?? runs[0];
  const machineItems: DropdownItem[] = stations.map((s) => ({
    id: s.id,
    label: s.name || s.id,
    leading: <MacbookIcon className="size-4" />,
    disabled: s.link.state !== "online",
    ...(s.link.state !== "online" ? { subtitle: messages.station_task_offline() } : {}),
  }));
  const runItems: DropdownItem[] = runs.map((r) => ({
    id: runKey(r),
    label: r.model ?? messages.station_task_default_model(),
    leading: (
      <ModelVendorIcon vendor={VENDORS[r.profile.runtimes[0] ?? ""] ?? "openai"} />
    ),
    // The profile names whose account runs it, where the machine has more than one.
    ...(profileCount > 1 ? { subtitle: r.profile.name } : {}),
  }));
  const body = text.trim();
  const create = async () => {
    if (!chosen || !chosenRun || !body || pending) return;
    setPending(true);
    setError(undefined);
    try {
      const made = await call("stations.newTask", {
        key,
        profile: chosenRun.profile.id,
        runtime: chosenRun.profile.runtimes[0]!,
        station: chosen,
        text: body,
        workspace,
        ...(chosenRun.model ? { model: chosenRun.model } : {}),
      });
      onClose();
      await navigate({
        params: {
          station: chosen,
          thread: String(made.thread),
          workspaceId: workspace,
        },
        to: "/tasks/$workspaceId/station/$station/$thread",
      });
    } catch (failure) {
      const code = (failure as { code?: string }).code;
      setError(
        code === "machine_offline"
          ? messages.station_task_machine_offline()
          : (failure as Error).message || messages.station_task_create_failed()
      );
    } finally {
      setPending(false);
    }
  };

  return (
    <Dialog
      isOpen
      showCloseButton
      className="w-dialog-wide"
      title={messages.station_task_new()}
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
    >
      <div className="flex flex-col gap-md" data-testid="new-station-task">
        {stations.length === 0 ? (
          <p className="m-0 text-sm text-tertiary">
            {messages.station_task_no_machines()}
          </p>
        ) : (
          <>
            <textarea
              aria-label={messages.station_task_first_message()}
              ref={messageRef}
              className="min-h-[calc(var(--spacing-4xl)*3)] w-full resize-none border-0 bg-transparent p-0 text-sm text-primary outline-none placeholder:text-placeholder"
              onChange={(event) => setText(event.target.value)}
              placeholder={messages.station_task_first_message()}
              value={text}
            />
            {/* Where it runs and what runs it, beside the button that makes it. */}
            <div className="flex flex-wrap items-center gap-xs">
              <Dropdown
                ariaLabel={messages.station_task_machine()}
                items={machineItems}
                onChange={setStation}
                placeholder={messages.station_task_machine()}
                size="xs"
                width="content"
                {...(chosen ? { value: chosen } : {})}
              />
              <Dropdown
                ariaLabel={messages.station_task_model()}
                disabled={runs.length === 0}
                items={runItems}
                loading={chosen !== undefined && profiles === null && !profilesFailed}
                onChange={setRun}
                placeholder={messages.station_task_model()}
                size="xs"
                width="content"
                {...(chosenRun ? { value: runKey(chosenRun) } : {})}
              />
              <Button
                className="ml-auto"
                hierarchy="primary"
                isDisabled={pending || !chosen || !chosenRun || !body}
                onPress={() => void create()}
                size="sm"
              >
                {messages.station_task_create()}
              </Button>
            </div>
            {profilesFailed || error ? (
              <p className="m-0 text-sm text-error-primary" role="alert">
                {error ?? profilesFailed}
              </p>
            ) : null}
          </>
        )}
      </div>
    </Dialog>
  );
}
