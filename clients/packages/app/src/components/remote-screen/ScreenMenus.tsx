import { useCall, useTopic, type ListedScreen } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { Dialog } from "@comma/ui/components/dialog";
import {
  CheckLargeIcon,
  ChevronDownSmallIcon,
  ChevronRightSmallIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  SubmenuTrigger,
} from "@comma/ui/components/menu";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { motionDuration } from "@comma/ui/tokens";
import { getNativeBridge } from "@comma/native-bridge";
import { Fragment, useEffect, useState, type ReactNode } from "react";
import { Header, MenuSection, Pressable } from "react-aria-components";
import {
  screenName,
  screenNote,
  useScreenDevicesEnabled,
  useScreenListing,
} from "./useScreenListing";
import { ScreenPhonesDialog } from "./ScreenPhones";
import {
  platformOf,
  recentScreenModels,
  rememberScreenModel,
  screenModels,
  type ScreenModel,
  type ScreenPlatform,
  type StartableScreen,
} from "./screenModels";

/** The person's own computers that run a station now: the server lists no one else's. */
export function useOwnComputers(workspace: string | undefined, enabled = true) {
  const { value } = useTopic(
    enabled && workspace
      ? { topic: "devices", prefer: workspace, local: "", visit: "screens" }
      : null
  );
  return (value?.devices ?? []).filter((device) => device.station_id);
}

/** This computer's own Device in `workspace`, as its station's Connector proved it (the desktop app alone has one). */
export function useLocalDeviceId(workspace: string | undefined) {
  const [deviceId, setDeviceId] = useState<string>();
  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron" || !workspace) return undefined;
    return bridge.connectorRuntime.state.subscribe((state) =>
      setDeviceId(
        state.scopes.find((scope) => scope.workspaceId === workspace)?.deviceId
      )
    );
  }, [workspace]);
  return deviceId;
}

/** A computer's heading in the menu: its own name, as Settings › Devices lists it, not its station's. */
function ComputerHeading({ name, local }: { name: string; local: boolean }) {
  const messages = useCommaMessages();
  return (
    <>
      {name}
      {local ? (
        <span className="font-normal"> · {messages.remote_screen_this_computer()}</span>
      ) : null}
    </>
  );
}

/** What a choice in the menu shows: a computer's own screen, or one of its devices. */
export type ChosenScreen = {
  device: string;
  screen?: ListedScreen | undefined;
  target?: "display" | undefined;
};

const SECTION_HEADER = "mx-sm px-md pb-xs pt-sm text-xs font-medium text-quaternary";
const NO_MARK = <span aria-hidden className="size-5" />;

// A device takes its time to boot: it is asked for at this pace, one read of one computer, until this long has gone.
const STARTED_EVERY_MS = 2_000;
const STARTED_WITHIN_MS = 180_000;

/** Starts an AVD or boots a simulator, and says when it is up: what started shows in this tab once it has booted. */
export function useStartScreenDevice() {
  const messages = useCommaMessages();
  const call = useCall();
  return (
    workspace: string,
    device: string,
    startable: StartableScreen,
    onUp: (screen: ListedScreen) => void
  ) => {
    const named =
      "avd" in startable ? startable.avd : screenName({ title: startable.title });
    const failed = () =>
      toast(messages.remote_screen_start_failed({ device: named }), {
        intent: "error",
      });
    toast(messages.remote_screen_starting_device({ device: named }));
    const asked =
      "avd" in startable ? { avd: startable.avd } : { simulator: startable.simulator };
    void call("devices.startScreenDevice", { workspace, device, ...asked })
      .then(async ({ id }) => {
        const until = uiClock.monotonic() + STARTED_WITHIN_MS;
        while (uiClock.monotonic() < until) {
          const { screens } = await call("devices.listScreens", { workspace, device });
          // The device there started as this AVD: an id is a place, and another may be in it. A simulator's id is the
          // device itself.
          const screen = screens.find(
            (one) =>
              one.id === id && ("avd" in startable ? one.name === startable.avd : true)
          );
          if (screen) return onUp(screen);
          await new Promise((resolve) =>
            uiClock.after(STARTED_EVERY_MS, () => resolve(0))
          );
        }
        return failed();
      })
      .catch(failed);
  };
}

/**
 * What a choice of a model does: shows its running device (unless it is the one shown, `currentScreen`), or boots one
 * and shows it once it is up. The model is kept as the one chosen last.
 */
function useChooseModel(
  workspace: string,
  device: string,
  currentScreen: string | undefined,
  onChoose: (chosen: ChosenScreen) => void
) {
  const start = useStartScreenDevice();
  return (model: ScreenModel, of: ScreenPlatform) => {
    rememberScreenModel(workspace, device, of, model.name);
    if (model.running) {
      if (model.running.instance !== currentScreen)
        onChoose({ device, screen: model.running });
    } else if (model.start)
      start(workspace, device, model.start, (screen) => onChoose({ device, screen }));
  };
}

/** The rows of some models: each shows its running device here, or starts one and shows it once it is up. */
function modelItems({
  key,
  models,
  current,
  choose,
}: {
  key: string;
  models: readonly ScreenModel[];
  /** The running device this tab shows: its model is marked. */
  current: string | undefined;
  choose(model: ScreenModel): void;
}) {
  return models.map((model) => (
    <ModelItem
      current={current}
      id={`${key}\n${model.name}`}
      key={model.name}
      model={model}
      onAction={() => choose(model)}
    />
  ));
}

function ModelItem({
  id,
  model,
  current,
  onAction,
}: {
  id: string;
  model: ScreenModel;
  current: string | undefined;
  onAction(): void;
}) {
  const messages = useCommaMessages();
  const shown = model.running !== undefined && model.running.instance === current;
  const note = [
    model.runtime,
    model.running?.agent
      ? messages.remote_screen_agent_using()
      : // (the one shown has its check)
        model.running && !shown
        ? messages.remote_screen_device_running()
        : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <MenuItem
      icon={shown ? <CheckLargeIcon aria-hidden /> : NO_MARK}
      id={id}
      note={note || undefined}
      onAction={onAction}
      textValue={model.name}
    >
      {model.name}
    </MenuItem>
  );
}

/**
 * A model's row in a device tab's menu: its name over what it runs, and a check after the one the tab shows. Which
 * of them run is said by the section they are in.
 */
function DeviceModelItem({
  id,
  model,
  current,
  onAction,
}: {
  id: string;
  model: ScreenModel;
  current: string | undefined;
  onAction(): void;
}) {
  const messages = useCommaMessages();
  const shown = model.running !== undefined && model.running.instance === current;
  const under = [
    model.runtime,
    model.running?.agent ? messages.remote_screen_agent_using() : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <MenuItem
      aria-label={model.name}
      id={id}
      onAction={onAction}
      shortcut={shown ? <CheckLargeIcon aria-hidden className="size-5" /> : undefined}
      textValue={model.name}
    >
      <span className="flex min-w-0 flex-col">
        <span className="truncate">{model.name}</span>
        {under ? (
          <span
            className="truncate text-xs font-normal text-tertiary"
            data-slot="menu-item-under"
          >
            {under}
          </span>
        ) : null}
      </span>
    </MenuItem>
  );
}

/** Models a person rarely wants, out of the way: a row that opens them beside the menu. */
function MoreModels({
  id,
  label,
  children,
}: {
  id: string;
  label: string;
  children: ReactNode;
}) {
  return (
    <SubmenuTrigger delay={motionDuration.submenuOpenDelay}>
      <MenuItem
        icon={NO_MARK}
        id={id}
        shortcut={<ChevronRightSmallIcon className="size-4" />}
        textValue={label}
      >
        {label}
      </MenuItem>
      <MenuPopover offset={0} placement="right top">
        <Menu aria-label={label}>{children}</Menu>
      </MenuPopover>
    </SubmenuTrigger>
  );
}

/**
 * One computer in the menu: its own screen (not this computer's: it would show itself), the devices running on it, and
 * its phones. While the tab shows one of its simulators or emulators, the models of that platform stand in its place,
 * those that run and then those that would boot: a choice shows that model's running device here, or boots one and
 * then shows it. Models of a platform it does not show are behind a row of their own, not listed among what runs.
 */
function ComputerSection({
  workspace,
  computer,
  local,
  open,
  current,
  currentScreen,
  onChoose,
  onPhones,
}: {
  workspace: string;
  computer: { device_id: string; name: string; screen_view?: boolean | undefined };
  /** It is the computer this app runs on. */
  local: boolean;
  open: boolean;
  current: string;
  currentScreen: string | undefined;
  onChoose(chosen: ChosenScreen): void;
  /** Its owner chooses its phones (a dialog, out of the menu). */
  onPhones(computer: { device: string; name: string }): void;
}) {
  const messages = useCommaMessages();
  const device = computer.device_id;
  const listing = useScreenListing(workspace, device, open);
  const { screens, phones } = listing;
  const here = device === current;
  const viewing = here
    ? screens.find((screen) => screen.instance === currentScreen)
    : undefined;
  const platform = viewing ? platformOf(viewing) : undefined;
  const choose = useChooseModel(
    workspace,
    device,
    here ? currentScreen : undefined,
    onChoose
  );
  const swap = platform
    ? screenModels(
        listing,
        platform,
        viewing,
        recentScreenModels(workspace, device, platform)
      )
    : undefined;
  // Each platform the tab does not show: its models that could start, behind one row.
  const startable = (["ios", "android"] as const)
    .filter((one) => one !== platform)
    .map((one) => {
      const { shown, more } = screenModels(
        { ...listing, screens: [] },
        one,
        undefined,
        recentScreenModels(workspace, device, one)
      );
      return { platform: one, shown, more };
    })
    .filter(({ shown, more }) => shown.length + more.length > 0);
  if (swap && platform) {
    const models = [...swap.shown, ...swap.more];
    const groups = [
      {
        key: "booted",
        label: messages.remote_screen_devices_booted(),
        models: models.filter((model) => model.running),
      },
      {
        key: "available",
        label: messages.remote_screen_devices_available(),
        models: models.filter((model) => !model.running),
      },
    ].filter((group) => group.models.length > 0);
    return groups.map((group, index) => (
      <Fragment key={group.key}>
        {index > 0 ? <MenuSeparator /> : null}
        <MenuSection>
          <Header className={SECTION_HEADER}>
            {group.label}
            {group.key === "booted" ? (
              <span aria-hidden className="comma-remote-screen-booted" />
            ) : null}
          </Header>
          {group.models.map((model) => (
            <DeviceModelItem
              current={currentScreen}
              id={`${device}\n${group.key}\n${model.name}`}
              key={model.name}
              model={model}
              onAction={() => choose(model, platform)}
            />
          ))}
        </MenuSection>
      </Fragment>
    ));
  }
  return (
    <MenuSection>
      <Header className={SECTION_HEADER}>
        <ComputerHeading local={local} name={computer.name} />
      </Header>
      {/* Its display only where its station says it serves it (a Mac's or Windows', not Linux's). */}
      {computer.screen_view === true && !local ? (
        <MenuItem
          icon={here && !currentScreen ? <CheckLargeIcon aria-hidden /> : NO_MARK}
          id={`${device}\nown`}
          onAction={() => {
            if (!here || currentScreen) onChoose({ device, target: "display" });
          }}
          textValue={messages.remote_screen_display()}
        >
          {messages.remote_screen_display()}
        </MenuItem>
      ) : null}
      {screens.map((screen) => (
        <MenuItem
          icon={
            here && screen.instance === currentScreen ? (
              <CheckLargeIcon aria-hidden />
            ) : (
              NO_MARK
            )
          }
          id={`${device}\nscreen\n${screen.id}`}
          key={screen.id}
          note={
            screen.agent
              ? messages.remote_screen_agent_using()
              : [
                  screenNote(screen),
                  platformOf(screen)
                    ? messages.remote_screen_device_running()
                    : undefined,
                ]
                  .filter(Boolean)
                  .join(" · ") || undefined
          }
          onAction={() => {
            if (!here || screen.instance !== currentScreen)
              onChoose({ device, screen });
          }}
          textValue={screen.title}
        >
          {screenName(screen)}
        </MenuItem>
      ))}
      {startable.map(({ platform: of, shown, more }) => (
        <MoreModels
          id={`${device}\n${of}`}
          key={of}
          label={
            of === "ios"
              ? messages.remote_screen_simulators()
              : messages.remote_screen_emulators()
          }
        >
          {modelItems({
            key: `${device}\n${of}`,
            models: shown,
            current: undefined,
            choose: (model) => choose(model, of),
          })}
          {more.length > 0 ? (
            <MoreModels
              id={`${device}\n${of}\nmore`}
              label={messages.remote_screen_more_models()}
            >
              {modelItems({
                key: `${device}\n${of}\nmore`,
                models: more,
                current: undefined,
                choose: (model) => choose(model, of),
              })}
            </MoreModels>
          ) : null}
        </MoreModels>
      ))}
      {phones ? (
        <MenuItem
          icon={NO_MARK}
          id={`${device}\nphones`}
          onAction={() => onPhones({ device, name: computer.name })}
          textValue={messages.remote_screen_phones()}
        >
          {messages.remote_screen_phones()}
        </MenuItem>
      ) : null}
    </MenuSection>
  );
}

/**
 * A device tab switches among its computer's models on the same platform. Other tabs offer the person's computers
 * and their screens. A choice replaces what this tab shows. A screen in a window of its own shows that one screen
 * (no `onChoose`): its menu has only what is done with the device itself.
 */
export function ScreenComputerMenu({
  workspace,
  current,
  currentScreen,
  title,
  line,
  detail,
  closable,
  onChoose,
}: {
  workspace: string;
  /** The computer this tab shows. */
  current: string;
  /** The running device of its that this tab shows (`ListedScreen.instance`). */
  currentScreen?: string | undefined;
  title: string;
  /** What stands under the name; none while there is nothing to say. */
  line: string;
  /** The line in full, as its tip: with how the screen is reached. */
  detail?: string | undefined;
  /** The device this tab shows, where it can be shut down from here: the menu's last row, at the person's word. */
  closable?: { screen: ListedScreen; onClosed(): void } | undefined;
  /** Shows what was chosen in this one's place; absent where there is nothing else to choose (its own window). */
  onChoose?: ((chosen: ChosenScreen) => void) | undefined;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const [open, setOpen] = useState(false);
  const [closing, setClosing] = useState(false);
  const computers = useOwnComputers(workspace, open && onChoose !== undefined).filter(
    (computer) =>
      computer.status === "connected" &&
      (!currentScreen || computer.device_id === current)
  );
  const devices = useScreenDevicesEnabled();
  const localDevice = useLocalDeviceId(workspace);
  const [phones, setPhones] = useState<{ device: string; name: string } | null>(null);
  return (
    <>
      {phones ? (
        <ScreenPhonesDialog
          computer={phones.name}
          device={phones.device}
          onClose={() => setPhones(null)}
          workspace={workspace}
        />
      ) : null}
      <MenuTrigger onOpenChange={setOpen}>
        <Tooltip content={messages.remote_screen_devices()} placement="bottom">
          <Pressable>
            <button
              aria-label={`${title}, ${messages.remote_screen_devices()}`}
              className="comma-remote-screen-switcher"
              data-testid="remote-screen-computers"
              type="button"
            >
              <span className="comma-remote-screen-title">
                <span className="comma-remote-screen-switcher-name">
                  <strong title={title}>{title}</strong>
                  <ChevronDownSmallIcon aria-hidden />
                </span>
                {line ? (
                  <span className="comma-remote-screen-line" title={detail ?? line}>
                    <span>{line}</span>
                  </span>
                ) : null}
              </span>
            </button>
          </Pressable>
        </Tooltip>
        <MenuPopover placement="bottom start">
          <Menu aria-label={messages.remote_screen_devices()}>
            {computers.map((computer) =>
              !onChoose ? null : devices ? (
                <ComputerSection
                  computer={computer}
                  current={current}
                  currentScreen={currentScreen}
                  key={computer.device_id}
                  local={computer.device_id === localDevice}
                  onChoose={onChoose}
                  onPhones={setPhones}
                  open={open}
                  workspace={workspace}
                />
              ) : null
            )}
            {closable ? (
              <>
                {onChoose ? <MenuSeparator /> : null}
                <MenuItem
                  id="close"
                  onAction={() => setClosing(true)}
                  textValue={messages.remote_screen_shut_down_device({
                    device: screenName(closable.screen),
                  })}
                >
                  {messages.remote_screen_shut_down_device({
                    device: screenName(closable.screen),
                  })}
                </MenuItem>
              </>
            ) : null}
          </Menu>
        </MenuPopover>
      </MenuTrigger>
      {closing && closable ? (
        <Dialog
          actions={[
            {
              label: messages.remote_screen_close_device_cancel(),
              hierarchy: "secondary-gray",
            },
            {
              label: messages.remote_screen_close_device(),
              hierarchy: "destructive",
              onPress: () => {
                setClosing(false);
                void call("devices.closeScreenDevice", {
                  workspace,
                  device: current,
                  screen: closable.screen.id,
                  instance: closable.screen.instance,
                })
                  .then(closable.onClosed)
                  .catch(() =>
                    toast(messages.remote_screen_close_device_failed(), {
                      intent: "error",
                    })
                  );
              },
            },
          ]}
          description={messages.remote_screen_close_device_body()}
          isOpen
          onOpenChange={setClosing}
          title={messages.remote_screen_close_device_title({
            device: screenName(closable.screen),
          })}
        />
      ) : null}
    </>
  );
}

/**
 * A computer's simulators and emulators to choose from, where none runs to show: its models of each platform, as the
 * screen menu lists them. A choice boots one (or shows one that started meanwhile) in this tab's place.
 */
export function ScreenModelChooser({
  workspace,
  device,
  active,
  onChoose,
}: {
  workspace: string;
  device: string;
  active: boolean;
  onChoose(chosen: ChosenScreen): void;
}) {
  const messages = useCommaMessages();
  const listing = useScreenListing(workspace, device, active);
  const choose = useChooseModel(workspace, device, undefined, onChoose);
  const platforms = (["ios", "android"] as const)
    .map((platform) => ({
      platform,
      ...screenModels(
        listing,
        platform,
        undefined,
        recentScreenModels(workspace, device, platform)
      ),
    }))
    .filter(({ shown, more }) => shown.length + more.length > 0);
  return (
    <div className="comma-remote-screen-models" data-testid="remote-screen-models">
      <p className="comma-remote-screen-models-title">
        {messages.remote_screen_models_title()}
      </p>
      {platforms.length ? (
        <Menu aria-label={messages.remote_screen_models_title()}>
          {platforms.map(({ platform, shown, more }) => (
            <MenuSection key={platform}>
              <Header className={SECTION_HEADER}>
                {platform === "ios"
                  ? messages.remote_screen_simulators()
                  : messages.remote_screen_emulators()}
              </Header>
              {modelItems({
                key: platform,
                models: shown,
                current: undefined,
                choose: (model) => choose(model, platform),
              })}
              {more.length > 0 ? (
                <MoreModels
                  id={`${platform}\nmore`}
                  label={messages.remote_screen_more_models()}
                >
                  {modelItems({
                    key: `${platform}\nmore`,
                    models: more,
                    current: undefined,
                    choose: (model) => choose(model, platform),
                  })}
                </MoreModels>
              ) : null}
            </MenuSection>
          ))}
        </Menu>
      ) : (
        <p className="comma-remote-screen-models-note">
          {listing.read
            ? messages.remote_screen_models_none()
            : messages.remote_screen_connecting()}
        </p>
      )}
    </div>
  );
}
