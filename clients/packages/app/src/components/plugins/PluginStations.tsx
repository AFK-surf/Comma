import {
  useCall,
  useTopic,
  type PluginStation,
  type PluginStationsValue,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { PluginDetailSection, PluginResourceRow } from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { type ReactNode, useState } from "react";

/**
 * The still.fail stations a plugin connected (the core's `pluginStations`),
 * for a plugin that connects them (`Plugin.stations`).
 */
export function PluginStations({
  icon,
  plugin,
  workspace,
  onConnectAnother,
  connectPending,
}: {
  /** The plugin's own logo, shown on each station. */
  icon: ReactNode;
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
      icon={icon}
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
    />
  );
}

/**
 * The stations as the core says them: each with whether it is connected and a
 * disconnect of its own, asked first; another connected by the plugin's line
 * made again (`onConnectAnother`). One disconnect at a time.
 */
export function PluginStationsList({
  icon,
  value,
  connectPending,
  onConnectAnother,
  onDisconnect,
}: {
  icon: ReactNode;
  value: PluginStationsValue | undefined;
  connectPending: boolean;
  onConnectAnother(): void;
  onDisconnect(station: PluginStation, name: string): void;
}) {
  const messages = useCommaMessages();
  const [asked, setAsked] = useState<PluginStation | null>(null);
  const stations = value?.stations;
  const busy = Boolean(value?.pending);
  const nameOf = (station: PluginStation) =>
    station.name ?? messages.plugins_station_unnamed();

  return (
    <PluginDetailSection
      title={messages.plugins_stations()}
      action={
        <Button
          hierarchy="tertiary-gray"
          size="sm"
          isDisabled={connectPending}
          onPress={onConnectAnother}
        >
          {messages.plugins_station_connect_another()}
        </Button>
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
            <PluginResourceRow
              key={station.id}
              resource={{
                icon,
                id: station.id,
                name: nameOf(station),
                detail: station.connected
                  ? messages.plugins_station_connected()
                  : station.connectedAt
                    ? messages.plugins_station_offline()
                    : messages.plugins_station_waiting(),
                trailingContent: (
                  <Button
                    hierarchy="tertiary-gray"
                    size="sm"
                    isDisabled={busy}
                    onPress={() => setAsked(station)}
                  >
                    {messages.plugins_station_disconnect()}
                  </Button>
                ),
              }}
            />
          ))}
        </ul>
      )}
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
  );
}
