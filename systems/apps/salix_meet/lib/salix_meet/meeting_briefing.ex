defmodule SalixMeet.MeetingBriefing do
  @moduledoc "Provider-neutral rendering for attendee-facing meeting preparation."

  alias SalixStore.JSON

  @max_title_length 160
  @max_scope_length 500
  @max_finding_length 500
  @max_findings 8
  @max_url_bytes 4_096

  @spec render(map(), map()) :: String.t()
  def render(context, baseline) do
    context = stringify_map(context)
    header(context) <> "\n\n" <> render_preparation(baseline)
  end

  @doc "Shared preparation body; the deterministic meeting notice supplies current time and links."
  def render_preparation(baseline) do
    baseline = stringify_map(baseline)

    [
      scope_section(baseline),
      findings_sections(baseline),
      "This briefing reflects the evidence available at publication time; unverified details remain provisional."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  The deterministic base card: title, time, event link, Meet link — the
  non-LLM header of the full briefing, and nothing else. Rendered by the
  system publication track, so it must stay a pure function of the stored
  occurrence facts: no research content, no clocks, no randomness (the
  idempotent delivery layer treats same-key different-content as a
  conflict by design).
  """
  @spec render_card(map()) :: String.t()
  def render_card(context), do: context |> stringify_map() |> header()

  @doc """
  Card completeness for the deterministic track. The card's promise is time +
  event link + Meet link; a card missing either link — including an event
  link removed by the HTTPS safety validation — must never be sent.
  """
  @spec card_completeness(map()) :: :complete | :missing_meet_link | :missing_event_link
  def card_completeness(context) do
    context = stringify_map(context)

    cond do
      is_nil(conference_url(context)) -> :missing_meet_link
      is_nil(event_url(context)) -> :missing_event_link
      true -> :complete
    end
  end

  defp header(context) do
    links =
      [
        link_line("Open event", event_url(context)),
        link_line("Join Meet", conference_url(context))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [
      "📅 " <> title(context),
      time_line(context),
      links
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp title(context) do
    context
    |> get_in(["calendar_item", "object", "title"])
    |> attendee_text(@max_title_length)
    |> case do
      nil -> "Calendar meeting"
      value -> value
    end
  end

  defp time_line(context) do
    occurrence = context["effective_occurrence"] || %{}
    object = get_in(context, ["calendar_item", "object"]) || %{}
    requested_zone = get_in(occurrence, ["effective", "timeZone"]) || object["timeZone"]

    with start_ms when is_integer(start_ms) <- occurrence["start_ms"],
         end_ms when is_integer(end_ms) <- occurrence["end_ms"],
         true <- end_ms >= start_ms,
         {:ok, start_at} <- DateTime.from_unix(start_ms, :millisecond),
         {:ok, end_at} <- DateTime.from_unix(end_ms, :millisecond),
         {:ok, start_at, end_at, zone} <- shift_interval(start_at, end_at, requested_zone) do
      format_interval(start_at, end_at) <> " (" <> zone <> ")"
    else
      _ -> nil
    end
  end

  defp shift_interval(start_at, end_at, "Etc/UTC"),
    do: {:ok, start_at, end_at, "Etc/UTC"}

  defp shift_interval(start_at, end_at, zone) when is_binary(zone) and zone != "" do
    with {:ok, shifted_start} <- DateTime.shift_zone(start_at, zone),
         {:ok, shifted_end} <- DateTime.shift_zone(end_at, zone) do
      {:ok, shifted_start, shifted_end, zone}
    else
      _ -> shift_interval(start_at, end_at, "Etc/UTC")
    end
  end

  defp shift_interval(start_at, end_at, _zone),
    do: shift_interval(start_at, end_at, "Etc/UTC")

  defp format_interval(start_at, end_at) do
    start_text = Calendar.strftime(start_at, "%Y-%m-%d %H:%M")

    end_text =
      if DateTime.to_date(start_at) == DateTime.to_date(end_at) do
        Calendar.strftime(end_at, "%H:%M")
      else
        Calendar.strftime(end_at, "%Y-%m-%d %H:%M")
      end

    start_text <> "–" <> end_text
  end

  defp event_url(context) do
    case get_in(context, ["calendar_item", "object", "links", "event"]) do
      %{"@type" => "Link", "rel" => "alternate", "href" => href} -> safe_https_url(href)
      _ -> nil
    end
  end

  defp conference_url(context) do
    object = get_in(context, ["calendar_item", "object"]) || %{}
    effective = get_in(context, ["effective_occurrence", "effective"]) || %{}

    locations =
      case effective["virtualLocations"] do
        nil -> object["virtualLocations"]
        occurrence_locations -> occurrence_locations
      end

    case locations do
      %{"conference" => %{"uri" => uri}} -> safe_google_meet_url(uri)
      _ -> nil
    end
  end

  defp safe_google_meet_url(url) do
    with canonical when is_binary(canonical) <- safe_https_url(url),
         {:ok, %URI{host: "meet.google.com"}} <- URI.new(canonical) do
      canonical
    else
      _ -> nil
    end
  end

  defp safe_https_url(url) when is_binary(url) and byte_size(url) <= @max_url_bytes do
    url = String.trim(url)

    with {:ok, %URI{} = uri} <- URI.new(url),
         "https" <- uri.scheme,
         host when is_binary(host) and host != "" <- uri.host,
         nil <- uri.userinfo,
         443 <- uri.port do
      uri
      |> Map.put(:scheme, "https")
      |> Map.put(:host, String.downcase(host))
      |> URI.to_string()
    else
      _ -> nil
    end
  end

  defp safe_https_url(_url), do: nil

  defp link_line(_label, nil), do: nil
  defp link_line(label, url), do: "[" <> label <> "](<" <> url <> ">)"

  defp scope_section(baseline) do
    case attendee_text(baseline["scope"], @max_scope_length) do
      nil -> nil
      scope -> "Scope: " <> scope
    end
  end

  defp findings_sections(baseline) do
    known_facts = findings(baseline["known_facts"] || baseline["facts"])
    gaps = findings(baseline["gaps"])

    case {known_facts, gaps} do
      {[], []} ->
        "No verified research findings were available before this briefing."

      _ ->
        [
          findings_section("Known facts", known_facts),
          findings_section("Still to verify", gaps)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")
    end
  end

  defp findings(values) when is_list(values) do
    values
    |> Enum.reduce([], fn value, findings ->
      case attendee_text(value, @max_finding_length) do
        nil -> findings
        text -> [text | findings]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(@max_findings)
  end

  defp findings(_values), do: []

  defp findings_section(_heading, []), do: nil

  defp findings_section(heading, values),
    do: heading <> "\n" <> Enum.map_join(values, "\n", &("• " <> &1))

  defp attendee_text(value, max_length) when is_binary(value) do
    value
    |> String.replace(~r/[\p{Cc}\p{Cf}]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.replace("<", "‹")
    |> String.replace(">", "›")
    |> String.trim()
    |> truncate(max_length)
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp attendee_text(_value, _max_length), do: nil

  defp truncate(value, max_length) do
    if String.length(value) > max_length do
      String.slice(value, 0, max_length - 1) <> "…"
    else
      value
    end
  end

  defp stringify_map(value) when is_map(value), do: JSON.stringify(value)
  defp stringify_map(_value), do: %{}
end
