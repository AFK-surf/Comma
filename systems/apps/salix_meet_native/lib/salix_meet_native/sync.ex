defmodule SalixMeetNative.Sync do
  @moduledoc false

  alias SalixMeetNative.Codec
  alias SalixMeetNative.Events
  alias SalixMeetNative.Events.Event
  alias SalixMeetNative.Wire

  @type delta :: %{
          collection: :meeting_space | :devices,
          version: non_neg_integer() | nil,
          changed?: boolean(),
          resources: [binary()]
        }

  @spec encode_request(String.t(), %{optional(:meeting_space | :devices) => non_neg_integer()}) ::
          binary()
  def encode_request(space, versions) do
    Codec.encode(%Wire.SyncMeetingSpaceCollectionsRequest{
      space: space,
      meeting_space_cursor: cursor(versions, :meeting_space),
      devices_cursor: cursor(versions, :devices)
    })
  end

  defp cursor(versions, key) do
    case Map.fetch(versions, key) do
      {:ok, version} -> %Wire.CollectionCursor{version: version}
      :error -> nil
    end
  end

  @spec parse_response(binary()) :: [delta()]
  def parse_response(raw) do
    case Codec.decode_rpc_response(Wire.SyncMeetingSpaceCollectionsResponse, raw) do
      {:ok, resp} -> parse(resp)
      :error -> []
    end
  end

  defp parse(%Wire.SyncMeetingSpaceCollectionsResponse{} = resp) do
    [meeting_space: resp.meeting_space, devices: resp.devices]
    |> Enum.flat_map(fn
      {_id, nil} ->
        []

      {id, %Wire.SyncCollection{} = c} ->
        {state, changed?} = if c.changed, do: {c.changed, true}, else: {c.synced, false}
        version = state && state.cursor && state.cursor.version
        resources = if changed? and state, do: state.resource_messages, else: []

        if version != nil or changed?,
          do: [%{collection: id, version: version, changed?: changed?, resources: resources}],
          else: []
    end)
  end

  @spec events([delta()], String.t()) :: [%Event{}]
  def events(deltas, t) do
    for %{changed?: true} = d <- deltas,
        raw <- d.resources,
        event <- resource_event(d, raw, t),
        do: event
  end

  defp resource_event(%{collection: :meeting_space, version: version}, raw, t) do
    case Codec.decode(Wire.MeetingSpaceResource, raw) do
      {:ok, %Wire.MeetingSpaceResource{} = r} ->
        payload = %{"space" => r.space, "code" => r.code, "version" => version || 0}

        payload =
          case r.details do
            %{host: %{display_name: host}} when host != "" -> Map.put(payload, "host", host)
            _ -> payload
          end

        [%Event{t: t, type: "space", actor: r.code, payload: payload, source: "sync"}]

      :error ->
        []
    end
  end

  defp resource_event(%{collection: :devices, version: version}, raw, t) do
    case Codec.decode(Wire.MeetingDevice, raw) do
      {:ok, %Wire.MeetingDevice{name: name} = r} when name != "" ->
        payload = r |> Events.device_payload() |> Map.put("version", version || 0)
        actor = if r.display_name == "", do: name, else: r.display_name
        [%Event{t: t, type: "participant", actor: actor, payload: payload, source: "sync"}]

      _ ->
        []
    end
  end

  @spec apply_versions(map(), [delta()]) :: map()
  def apply_versions(versions, deltas) do
    Enum.reduce(deltas, versions, fn
      %{version: nil}, acc -> acc
      %{collection: id, version: v}, acc -> Map.put(acc, id, v)
    end)
  end

  @spec devices_changed?([delta()]) :: boolean()
  def devices_changed?(deltas),
    do: Enum.any?(deltas, &(&1.collection == :devices and &1.changed?))

  @spec membership_transitions(map(), [%Event{}], String.t()) :: {[%Event{}], map()}
  def membership_transitions(prev, events, t) do
    Enum.reduce(events, {[], prev}, fn
      %Event{type: "participant", payload: %{"device" => dev, "state" => st}} = e, {out, prev}
      when dev != "" and st != "" ->
        payload = %{"device" => dev, "name" => e.payload["name"]}

        out =
          case Map.fetch(prev, dev) do
            :error when st == "knocking" ->
              [
                %Event{
                  t: t,
                  type: "membership.requested",
                  actor: e.actor,
                  payload: payload,
                  source: "sync"
                }
                | out
              ]

            {:ok, "knocking"} when st == "joined" ->
              [
                %Event{
                  t: t,
                  type: "membership.admitted",
                  actor: e.actor,
                  payload: payload,
                  source: "sync"
                }
                | out
              ]

            _ ->
              out
          end

        {out, Map.put(prev, dev, st)}

      _e, acc ->
        acc
    end)
    |> then(fn {out, prev} -> {Enum.reverse(out), prev} end)
  end

  @spec dedupe_roster([%Event{}], map()) :: {[%Event{}], map()}
  def dedupe_roster(events, last) do
    Enum.reduce(events, {[], last}, fn e, {out, last} ->
      case signature(e) do
        nil ->
          {[e | out], last}

        {key, sig} ->
          if Map.get(last, key) == sig,
            do: {out, last},
            else: {[e | out], Map.put(last, key, sig)}
      end
    end)
    |> then(fn {out, last} -> {Enum.reverse(out), last} end)
  end

  defp signature(%Event{type: "participant", payload: %{"device" => dev} = p}) when dev != "",
    do: {"dev:" <> dev, "#{p["name"]}|#{p["state"]}"}

  defp signature(%Event{type: "space", payload: p}), do: {"space", "#{p["code"]}|#{p["host"]}"}
  defp signature(_), do: nil

  @spec roster([%Event{}]) :: [map()]
  def roster(events) do
    for %Event{type: "participant", payload: %{"device" => dev} = p} <- events, dev != "", do: p
  end
end
