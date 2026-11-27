import {
  useCall,
  useTopic,
  type PluginStation,
  type PluginStationsValue,
  type StillfailNotificationLevel,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Avatar } from "@comma/ui/components/avatar";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { Dropdown } from "@comma/ui/components/dropdown";
import { MoreHorizontalIcon, PlusIcon } from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { PluginDetailSection } from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { cx } from "@comma/ui/components/utils";
import { useState } from "react";

const NOTIFICATION_LEVELS: readonly StillfailNotificationLevel[] = [
  "off",
  "action_needed",
  "issues",
  "all",
];

function isNotificationLevel(value: string): value is StillfailNotificationLevel {
  return NOTIFICATION_LEVELS.includes(value as StillfailNotificationLevel);
}

/**
 * The Monoid workspaces a plugin connected, each through one of its stations
 * (the core's `pluginStations`), plus the owner's proactive notification level
 * choices for connected Monoid chats.
 */
export function PluginStations({
  plugin,
  workspace,
  onConnectAnother,
  connectPending,
}: {
  plugin: string;
  workspace: string;
  onConnectAnother(): void;
  connectPending: boolean;
}) {
  const call = useCall();
  const messages = useCommaMessages();
  const { value } = useTopic({ topic: "pluginStations", workspace, plugin });
  return (
    <PluginStationsList
      value={value}
      connectPending={connectPending}
      onConnectAnother={onConnectAnother}
      onDisconnect={(station, name) =>
        void call("plugin.station.disconnect", {
          workspace,
          plugin,
          station: station.id,
        }).catch(() =>
          toast.error(messages.plugins_station_disconnect_failed({ name }))
        )
      }
      onNotificationLevelChange={(level) =>
        void call("plugin.station.notificationLevel.set", {
          workspace,
          plugin,
          level,
        }).catch(() =>
          toast.error(messages.plugins_stillfail_notifications_save_failed())
        )
      }
    />
  );
}

/**
 * The workspaces as the core says them: each with its emoji or initial, the
 * station Comma reaches it through and whether that one is connected, and a
 * disconnect of its own in its menu, asked first; another connected by the
 * plugin's line made again (`onConnectAnother`). One disconnect at a time.
 * Below it sits the notification level radio list for Monoid chats.
 */
export function PluginStationsList({
  value,
  connectPending,
  onConnectAnother,
  onDisconnect,
  onNotificationLevelChange,
}: {
  value: PluginStationsValue | undefined;
  connectPending: boolean;
  onConnectAnother(): void;
  onDisconnect(station: PluginStation, name: string): void;
  onNotificationLevelChange?(level: StillfailNotificationLevel): void;
}) {
  const messages = useCommaMessages();
  const [asked, setAsked] = useState<PluginStation | null>(null);
  const stations = value?.stations;
  const busy = Boolean(value?.pending);
  const notificationLevel: StillfailNotificationLevel =
    value?.notificationLevel ?? "action_needed";
  const notificationSaving = Boolean(value?.notificationPending);
  const nameOf = (station: PluginStation) =>
    station.workspace ?? messages.plugins_station_unnamed();

  const offlineStations = (stations ?? []).filter(
    (station) => Boolean(station.connectedAt) && !station.connected
  );

  const levelLabel = (level: StillfailNotificationLevel) => {
    switch (level) {
      case "off":
        return messages.plugins_stillfail_notifications_off();
      case "action_needed":
        return messages.plugins_stillfail_notifications_action_needed();
      case "issues":
        return messages.plugins_stillfail_notifications_issues();
      case "all":
        return messages.plugins_stillfail_notifications_all();
    }
  };

  const levelDescription = (level: StillfailNotificationLevel) => {
    switch (level) {
      case "off":
        return messages.plugins_stillfail_notifications_off_description();
      case "action_needed":
        return messages.plugins_stillfail_notifications_action_needed_description();
      case "issues":
        return messages.plugins_stillfail_notifications_issues_description();
      case "all":
        return messages.plugins_stillfail_notifications_all_description();
    }
  };

  const selectLevel = (next: StillfailNotificationLevel) => {
    if (notificationSaving || next === notificationLevel) return;
    onNotificationLevelChange?.(next);
  };

  const detailOf = (station: PluginStation) => {
    if (!station.connectedAt) return messages.plugins_station_waiting();
    const via = station.station
      ? messages.plugins_station_via({ station: station.station })
      : null;
    const after = station.connected
      ? station.stationCount !== null && station.stationCount > 1
        ? messages.plugins_station_count({ count: String(station.stationCount) })
        : null
      : messages.plugins_station_offline();
    return (
      <span className="flex min-w-0 items-center gap-sm">
        <span
          aria-hidden
          className={cx(
            "size-1.5 shrink-0 rounded-full",
            station.connected ? "bg-fg-success-primary" : "bg-fg-quaternary"
          )}
        />
        {via ? <span className="truncate text-tertiary">{via}</span> : null}
        {via && after ? <span aria-hidden>·</span> : null}
        {after ? <span className="shrink-0">{after}</span> : null}
      </span>
    );
  };

  return (
    <>
      <PluginDetailSection
        title={messages.plugins_stations()}
        action={
          <Button
            className="h-7 w-7"
            hierarchy="tertiary-gray"
            size="xs"
            iconOnly
            iconLeading={<PlusIcon />}
            isDisabled={connectPending}
            onPress={onConnectAnother}
            aria-label={messages.plugins_station_connect_another()}
          />
        }
      >
        {value?.error === "load_failed" && !stations ? (
          <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
            {messages.plugins_stations_load_failed()}
          </output>
        ) : stations && stations.length === 0 ? (
          <p className="m-0 px-md text-sm text-tertiary">
            {messages.plugins_stations_none()}
          </p>
        ) : (
          <ul className="m-0 flex list-none flex-col gap-xs p-0">
            {(stations ?? []).map((station) => (
              <li
                key={station.id}
                className="flex items-center gap-lg rounded-xl px-md py-sm"
              >
                <Avatar size="sm" name={nameOf(station)} emoji={station.emoji} />
                <span className="flex min-w-0 flex-1 flex-col gap-xxs text-sm">
                  <span className="truncate font-medium text-primary">
                    {nameOf(station)}
                  </span>
                  <span className="text-quaternary">{detailOf(station)}</span>
                </span>
                <MenuTrigger>
                  <Button
                    className="h-7 w-7"
                    hierarchy="tertiary-gray"
                    size="xs"
                    iconOnly
                    iconLeading={<MoreHorizontalIcon />}
                    isDisabled={busy}
                    aria-label={messages.plugins_station_more({
                      name: nameOf(station),
                    })}
                  />
                  <MenuPopover placement="bottom end">
                    <Menu>
                      <MenuItem
                        id="disconnect"
                        tone="destructive"
                        onAction={() => setAsked(station)}
                      >
                        {messages.plugins_station_disconnect()}
                      </MenuItem>
                    </Menu>
                  </MenuPopover>
                </MenuTrigger>
              </li>
            ))}
          </ul>
        )}
        {offlineStations.length > 0 ? (
          <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
            {messages.plugins_station_offline_banner({
              workspaces: offlineStations.map(nameOf).join(", "),
            })}
          </output>
        ) : null}
        {asked ? (
          <Dialog
            isOpen
            onOpenChange={(open) => {
              if (!open) setAsked(null);
            }}
            title={messages.plugins_station_disconnect_title({ name: nameOf(asked) })}
            description={messages.plugins_station_disconnect_description()}
            actions={[
              {
                label: messages.plugins_station_cancel(),
                hierarchy: "secondary-gray",
                onPress: () => setAsked(null),
              },
              {
                label: messages.plugins_station_disconnect(),
                hierarchy: "destructive",
                onPress: () => {
                  onDisconnect(asked, nameOf(asked));
                  setAsked(null);
                },
              },
            ]}
          />
        ) : null}
      </PluginDetailSection>

      <PluginDetailSection title={messages.plugins_stillfail_notifications()}>
        <div className="flex items-center justify-between gap-lg px-md py-xs">
          <p className="m-0 min-w-0 flex-1 text-sm text-secondary">
            {levelDescription(notificationLevel)}
          </p>
          <div className="shrink-0">
            <Dropdown
              ariaLabel={messages.plugins_stillfail_notifications()}
              disabled={notificationSaving}
              items={NOTIFICATION_LEVELS.map((level) => ({
                id: level,
                label: levelLabel(level),
                subtitle: levelDescription(level),
              }))}
              onChange={(next) => {
                if (isNotificationLevel(next)) selectLevel(next);
              }}
              size="sm"
              value={notificationLevel}
              width="content"
            />
          </div>
        </div>
      </PluginDetailSection>
    </>
  );
}
