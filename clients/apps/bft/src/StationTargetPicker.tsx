import { Dropdown } from "@comma/ui/components/dropdown";
import type { BftAgentTargets } from "./api";
import { messages } from "./messages";
import { useApi, useResource } from "./resource";

const t = messages.swarmAgents;

/** Where a Task runs: inside Salix, a device's station or the swarm's Cloud VM. */
export type PlaceLocation = "salix" | "station" | "cloud_vm";

/**
 * The swarm's places (`…/agents/targets`): its devices' stations and its
 * Cloud VM, or a retry row when they could not be read.
 */
export function useAgentTargets(org: string, project: string) {
  const api = useApi();
  return useResource(`agent-targets:${org}:${project}`, (signal) =>
    api.agentTargets(org, project, signal)
  );
}

export function TargetsUnavailable({ retry }: { retry: () => void }) {
  return (
    <div className="bft-quiet-row bft-quiet-row-flush" role="alert">
      <p className="bft-quiet bft-quiet-inline">{t.stationsUnavailable}</p>
      <button className="bft-btn bft-btn-sm" onClick={retry} type="button">
        {messages.states.retry}
      </button>
    </div>
  );
}

/**
 * The place fields: the location among `locations`, and for a station one of
 * the swarm's stations. A place the server marks not selectable is shown
 * disabled with its reason. A station that is gone or no longer selectable
 * does not count as chosen (`selected` is "").
 */
export function PlaceFields({
  targets,
  locations,
  location,
  deviceId,
  onLocation,
  onStation,
  disabled,
}: {
  targets: BftAgentTargets;
  locations: readonly PlaceLocation[];
  location: PlaceLocation;
  deviceId: string;
  onLocation: (location: PlaceLocation) => void;
  onStation: (deviceId: string) => void;
  disabled: boolean;
}) {
  const { stations, cloud_vm: cloud } = targets;
  const station = stations.find((item) => item.id === deviceId && item.selectable);
  return (
    <>
      <Dropdown
        className="bft-form-field"
        disabled={disabled}
        items={locations.map((item) => ({
          id: item,
          label: t.locations[item],
          ...(item === "cloud_vm" && !cloud.selectable
            ? { disabled: true, ...(cloud.issue ? { subtitle: cloud.issue } : {}) }
            : {}),
        }))}
        label={t.locationLabel}
        onChange={(item) => onLocation(item as PlaceLocation)}
        size="sm"
        value={location}
      />
      {location === "cloud_vm" ? (
        cloud.issue ? (
          <p className="bft-dialog-note" role="alert">
            {cloud.issue}
          </p>
        ) : null
      ) : location === "station" ? (
        <StationChoices
          disabled={disabled}
          onChoose={onStation}
          selected={station?.id ?? ""}
          stations={stations}
        />
      ) : null}
    </>
  );
}

function StationChoices({
  stations,
  selected,
  onChoose,
  disabled,
}: {
  stations: BftAgentTargets["stations"];
  selected: string;
  onChoose: (deviceId: string) => void;
  disabled: boolean;
}) {
  if (stations.length === 0) return <p className="bft-dialog-note">{t.noStations}</p>;
  return (
    <fieldset aria-label={t.stationsLabel} className="bft-choices">
      {stations.map((item) => (
        <label
          className="bft-choice"
          data-disabled={item.selectable ? undefined : true}
          key={item.id}
        >
          <input
            checked={selected === item.id}
            disabled={disabled || !item.selectable}
            name="station"
            onChange={() => onChoose(item.id)}
            type="radio"
            value={item.id}
          />
          <span className="bft-choice-main">
            <span className="bft-truncate" title={item.label}>
              {item.label}
            </span>
            <span className="bft-choice-meta">
              <span className="bft-status" data-tone={item.connected ? "ok" : "warn"}>
                {item.connected ? t.online : t.offline}
              </span>
            </span>
            {item.issue ? (
              <span className="bft-setting-row-sub bft-choice-issue">{item.issue}</span>
            ) : null}
          </span>
        </label>
      ))}
    </fieldset>
  );
}
