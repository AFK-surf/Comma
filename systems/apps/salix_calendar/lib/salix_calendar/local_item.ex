defmodule SalixCalendar.LocalItem do
  @moduledoc """
  Validates a human-authored Comma-local Event proposal and builds its stored
  envelope.

  A local Event is `origin.kind=local` and carries an immutable
  `owner_principal_ref`. The agent supplies only the structured proposal
  (title/start/timezone/duration/attendees); the server supplies owner identity,
  ids and the creation request. Attendee names are bounded display data and never
  become principals or Feed grants. v1 accepts one non-recurring Event only.
  """

  alias SalixCalendar.Recurrence
  alias SalixStore.{Crypto, JSON}

  @max_title 512
  @max_participants 50
  @max_participant_name 256
  # Bounded ISO 8601 duration subset: PnDTnHnMnS with at least one component.
  @duration_regex ~r/^P(?=\d|T)(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$/
  @subject_keys ~w(namespace tenant_id subject_id)

  @spec build(String.t(), String.t(), map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def build(item_id, calendar_id, proposal, owner, creation_request_id)
      when is_binary(item_id) and is_binary(calendar_id) and is_map(proposal) and
             is_binary(creation_request_id) do
    with {:ok, owner} <- owner(owner),
         {:ok, title} <- title(proposal["title"]),
         {:ok, zone} <- time_zone(proposal["time_zone"]),
         {:ok, start, start_ms} <- start(proposal["start"], zone),
         {:ok, duration} <- duration(proposal["duration"]),
         {:ok, participants} <- participants(proposal["attendees"]) do
      now = now_ms()

      object =
        %{
          "@type" => "Event",
          "uid" => uid(item_id),
          "title" => title,
          "start" => start,
          "timeZone" => zone,
          "duration" => duration,
          "status" => "confirmed",
          "privacy" => "private",
          "freeBusyStatus" => "busy"
        }
        |> put_participants(participants)

      envelope = %{
        "calendar_item_id" => item_id,
        "calendar_id" => calendar_id,
        "origin" => %{
          "kind" => "local",
          "creation_request_id" => creation_request_id,
          "created_by" => %{"kind" => "principal", "principal_ref" => owner}
        },
        "object" => object,
        "owner_principal_ref" => owner,
        "revision" => 1,
        "created_at" => now,
        "updated_at" => now
      }

      {:ok, %{envelope: envelope, start_ms: start_ms, owner: owner}}
    end
  end

  @doc "Canonical typed digest of a complete principal_ref, for owner index markers."
  @spec owner_digest(map()) :: String.t()
  def owner_digest(%{} = owner),
    do: owner |> canonical_owner() |> JSON.stringify() |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()

  @doc "UTC year-month bucket (\"yyyy-mm\") for an epoch-millisecond instant."
  @spec month_bucket(integer()) :: String.t()
  def month_bucket(ms) when is_integer(ms) do
    dt = DateTime.from_unix!(ms, :millisecond)
    "#{dt.year}-#{pad2(dt.month)}"
  end

  @doc "Validate and normalize a sealed owner principal_ref."
  @spec owner(term()) :: {:ok, map()} | {:error, term()}
  def owner(%{} = owner) do
    if Enum.all?(@subject_keys, &present?(owner[&1])),
      do: {:ok, canonical_owner(owner)},
      else: {:error, :invalid_owner_principal_ref}
  end

  def owner(_owner), do: {:error, :invalid_owner_principal_ref}

  defp canonical_owner(owner), do: Map.take(owner, @subject_keys)

  defp title(value) do
    with true <- is_binary(value),
         trimmed <- String.trim(value),
         true <- trimmed != "" and String.length(trimmed) <= @max_title do
      {:ok, trimmed}
    else
      _ -> {:error, :invalid_event_title}
    end
  end

  defp time_zone(zone) when is_binary(zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _} -> {:ok, zone}
      {:error, _} -> {:error, :invalid_time_zone}
    end
  end

  defp time_zone(_zone), do: {:error, :invalid_time_zone}

  # v1 accepts only a local wall-time start (no trailing Z / offset), resolved in
  # the item's IANA zone with the recurrence domain's DST policy.
  defp start(value, zone) when is_binary(value) do
    cond do
      String.ends_with?(value, "Z") or Regex.match?(~r/[+-]\d{2}:\d{2}$/, value) ->
        {:error, :invalid_event_start}

      true ->
        with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
             {:ok, %{unix_ms: ms}} <- Recurrence.resolve_local_time(naive, zone) do
          {:ok, NaiveDateTime.to_iso8601(naive), ms}
        else
          _ -> {:error, :invalid_event_start}
        end
    end
  end

  defp start(_value, _zone), do: {:error, :invalid_event_start}

  defp duration(value) when is_binary(value) do
    if Regex.match?(@duration_regex, value),
      do: {:ok, value},
      else: {:error, :invalid_event_duration}
  end

  defp duration(_value), do: {:error, :invalid_event_duration}

  defp participants(nil), do: {:ok, %{}}

  defp participants(attendees) when is_list(attendees) do
    cond do
      length(attendees) > @max_participants ->
        {:error, :too_many_participants}

      not Enum.all?(attendees, &valid_attendee?/1) ->
        {:error, :invalid_attendee}

      true ->
        participants =
          attendees
          |> Enum.with_index(1)
          |> Map.new(fn {attendee, index} ->
            {"p#{index}",
             %{
               "name" => String.trim(attendee["display_name"]),
               "roles" => ["attendee"],
               "participationStatus" => "needs-action",
               "x-comma-resolution" => "unresolved"
             }}
          end)

        {:ok, participants}
    end
  end

  defp participants(_attendees), do: {:error, :invalid_attendee}

  defp valid_attendee?(%{"display_name" => name}) when is_binary(name) do
    trimmed = String.trim(name)
    trimmed != "" and String.length(trimmed) <= @max_participant_name
  end

  defp valid_attendee?(_attendee), do: false

  defp put_participants(object, participants) when map_size(participants) == 0, do: object
  defp put_participants(object, participants), do: Map.put(object, "participants", participants)

  defp uid(item_id), do: "urn:comma:calendar-item:#{item_id}"

  defp present?(value), do: is_binary(value) and value != ""

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp now_ms, do: System.system_time(:millisecond)
end
