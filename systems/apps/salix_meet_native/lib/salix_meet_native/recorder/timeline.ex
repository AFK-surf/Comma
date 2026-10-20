defmodule SalixMeetNative.Recorder.Timeline do
  @moduledoc false

  defstruct [:path, :started_mono, doc: %{}]

  def new(dir, meeting_code) do
    doc = %{
      "meetingCode" => meeting_code,
      "startedUnixMs" => SystemsClock.system_time(:millisecond),
      "tracks" => []
    }

    write(%__MODULE__{
      path: Path.join(dir, "timeline.json"),
      started_mono: SystemsClock.monotonic_time(:millisecond),
      doc: doc
    })
  end

  def path(%__MODULE__{path: path}), do: path

  def add_track(tl, ssrc, file) do
    {unix, offset} = now(tl)

    track = %{
      "ssrc" => ssrc,
      "kind" => "audio",
      "codec" => "audio/opus",
      "file" => file,
      "startUnixMs" => unix,
      "startOffsetMs" => offset
    }

    index = length(tl.doc["tracks"])
    {write(update_in(tl.doc["tracks"], &(&1 ++ [track]))), index}
  end

  def end_track(tl, index) do
    {unix, offset} = now(tl)

    tl
    |> update_track(index, fn track ->
      track
      |> end_route(unix, offset)
      |> Map.merge(%{"endUnixMs" => unix, "endOffsetMs" => offset})
    end)
    |> write()
  end

  def set_route(tl, index, stream, device, participant) do
    {unix, offset} = now(tl)

    route =
      %{
        "sourceStream" => stream,
        "device" => device,
        "startUnixMs" => unix,
        "startOffsetMs" => offset
      }
      |> then(fn r ->
        if participant != "", do: Map.put(r, "participant", participant), else: r
      end)

    # Routes change on every speaker switch; they reach disk with the next
    # track change or `flush/1` instead of rewriting the file per switch.
    update_track(tl, index, fn track ->
      track |> end_route(unix, offset) |> Map.update("routes", [route], &(&1 ++ [route]))
    end)
  end

  def set_participant(tl, device, name) do
    tracks =
      Enum.map(tl.doc["tracks"], fn track ->
        Map.update(track, "routes", [], fn routes ->
          Enum.map(routes, fn r ->
            if r["device"] == device, do: Map.put(r, "participant", name), else: r
          end)
        end)
        |> then(fn t -> if t["routes"] == [], do: Map.delete(t, "routes"), else: t end)
      end)

    put_in(tl.doc["tracks"], tracks)
  end

  def flush(tl), do: write(tl)

  defp end_route(%{"routes" => routes} = track, unix, offset) do
    case List.last(routes) do
      %{"endUnixMs" => _} ->
        track

      last ->
        %{
          track
          | "routes" =>
              List.replace_at(
                routes,
                -1,
                Map.merge(last, %{"endUnixMs" => unix, "endOffsetMs" => offset})
              )
        }
    end
  end

  defp end_route(track, _unix, _offset), do: track

  defp update_track(tl, index, fun),
    do: update_in(tl.doc["tracks"], &List.update_at(&1, index, fun))

  defp now(tl),
    do:
      {SystemsClock.system_time(:millisecond),
       SystemsClock.monotonic_time(:millisecond) - tl.started_mono}

  defp write(tl) do
    tmp = tl.path <> ".tmp"
    File.write!(tmp, Jason.encode_to_iodata!(tl.doc, pretty: true))
    File.rename!(tmp, tl.path)
    tl
  end
end
