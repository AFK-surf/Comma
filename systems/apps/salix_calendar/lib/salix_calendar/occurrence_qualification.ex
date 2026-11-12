defmodule SalixCalendar.OccurrenceQualification.Result do
  @moduledoc false

  @enforce_keys [:authorized, :reason]
  defstruct authorized: false, meet_url: nil, reason: :unauthorized_meeting

  @type reason ::
          :google_meet
          | :lark_meeting
          | :zoom_meeting
          | :teams_meeting
          | :not_event
          | :cancelled
          | :free_busy_only
          | :all_day_event
          | :unsupported_timing
          | :access_profile_restricted
          | :unauthorized_meeting
          | :no_supported_conference
          | :unsupported_conference

  @type t :: %__MODULE__{
          authorized: boolean(),
          meet_url: String.t() | nil,
          reason: reason()
        }
end

defmodule SalixCalendar.OccurrenceQualification do
  @moduledoc """
  The single qualification decision for a calendar occurrence.

  Stable item eligibility is evaluated independently from the occurrence-effective
  conference. An eligible occurrence qualifies when its conference is a
  recognized video-meeting link; every qualified meeting is prepared and
  announced, and only a Google Meet is joined by the meeting bot (the join
  path checks the Meet link again on its own).

  Recognized links (`canonical_meeting_url/1`) are HTTPS, without userinfo,
  on the default port, on one of these hosts (exact, or a subdomain on a
  label boundary where stated; never a substring) and, except for Google
  Meet, with a path that joins a meeting. A product page, a download page or
  a Teams channel or chat link on the same host is not a meeting.

  | Provider | Hosts | Meeting paths | Reason |
  | --- | --- | --- | --- |
  | `:google_meet` | `meet.google.com` | any | `:google_meet` |
  | `:lark` | `vc.feishu.cn`, `vc.larksuite.com`, `vc.larkoffice.com` and regional `vc-<region>.` forms of them | `/j/<digits>` | `:lark_meeting` |
  | `:zoom` | `zoom.us`, `zoom.com` and their subdomains | `/j/<id>`, `/s/<id>`, `/w/<id>`, `/my/<name>`, `/wc/join/<id>`, `/wc/<id>/join` | `:zoom_meeting` |
  | `:teams` | `teams.microsoft.com`, `teams.live.com` | `/l/meetup-join/...`, `/meet/<digits>` | `:teams_meeting` |

  The source adapter decides which of its fields may carry the conference.
  A Google Meet link is taken only from a provider's own conference fields:
  a link found in free text (`text_meeting_url/1`, the event's location or
  description, which an outside inviter can write) never names a Google Meet,
  so text cannot make the bot join a meeting.
  """

  alias SalixCalendar.OccurrenceQualification.Result

  # Stop one candidate before any adjacent later `https://`. Calendar titles
  # commonly separate URLs with punctuation rather than whitespace; allowing
  # the first match to swallow the second would let the first host decide
  # whether a later Google Meet URL is redacted.
  @https_url ~r{https://(?:(?!https://)[^\s<>"'])+}iu
  # The same scan over raw bytes for free text: a URL ends at whitespace,
  # markup, a quote or any non-ASCII byte (descriptions often run a link
  # straight into CJK text), so a byte-bounded slice needs no UTF-8 boundary.
  @text_url ~r{https://(?:(?!https://)[^\x00-\x20<>"'\x7f-\xff])+}i
  @max_text_bytes 64 * 1_024
  @lark_domains ~w(feishu.cn larksuite.com larkoffice.com)
  @lark_region ~r/\Avc-[a-z0-9]{1,16}\z/
  @teams_hosts ~w(teams.microsoft.com teams.live.com)
  @zoom_domains ~w(zoom.us zoom.com)
  @meeting_paths %{
    lark: ~r{\A/j/\d+/?\z},
    zoom: ~r{\A/(?:(?:j|s|w)/\d+|my/[a-z0-9._-]+|wc/join/\d+|wc/\d+/join)/?\z}i,
    teams: ~r{\A/(?:l/meetup-join/[^/]+(?:/.*)?|meet/\d+/?)\z}
  }
  @reasons %{
    google_meet: :google_meet,
    lark: :lark_meeting,
    zoom: :zoom_meeting,
    teams: :teams_meeting
  }

  @type result :: Result.t()

  @spec evaluate(map(), map()) :: result()
  def evaluate(item, occurrence) when is_map(item) and is_map(occurrence) do
    object = item["object"] || %{}

    cond do
      object["@type"] != "Event" or occurrence["object_type"] != "Event" ->
        denied(:not_event)

      item["tombstoned_at"] != nil or object["status"] == "cancelled" ->
        denied(:cancelled)

      object["freeBusyStatus"] == "free" ->
        denied(:free_busy_only)

      object["showWithoutTime"] == true ->
        denied(:all_day_event)

      item["normalization_state"] == "unsupported_timing" ->
        denied(:unsupported_timing)

      true ->
        qualify_eligible_item(item, object, occurrence)
    end
  end

  def evaluate(_item, _occurrence), do: denied(:unauthorized_meeting)

  @doc """
  Whether any occurrence of the item could qualify: a meeting scan leaves out
  the others (all-day, free, cancelled, no meeting link) before it counts
  occurrences against its limit. An item with per-occurrence overrides is kept,
  since an override can add a link.
  """
  @spec may_qualify?(map()) :: boolean()
  def may_qualify?(item) when is_map(item) do
    object = item["object"] || %{}

    object["@type"] == "Event" and is_nil(item["tombstoned_at"]) and
      object["status"] != "cancelled" and object["freeBusyStatus"] != "free" and
      object["showWithoutTime"] != true and
      (map_size(object["recurrenceOverrides"] || %{}) > 0 or
         meeting_url?(get_in(object, ["virtualLocations", "conference", "uri"])))
  end

  def may_qualify?(_item), do: false

  @spec google_meet_url?(term()) :: boolean()
  def google_meet_url?(url), do: not is_nil(canonical_google_meet_url(url))

  @doc "Whether the URL is a recognized video-meeting link."
  @spec meeting_url?(term()) :: boolean()
  def meeting_url?(url), do: not is_nil(canonical_meeting_url(url))

  @doc """
  The provider and canonical form (host in lower case) of a recognized
  video-meeting link, or nil. See the table in the moduledoc.
  """
  @spec canonical_meeting_url(term()) :: {:google_meet | :lark | :zoom | :teams, String.t()} | nil
  def canonical_meeting_url(url) when is_binary(url) and byte_size(url) <= 4_096 do
    with {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: 443} = uri}
         when is_binary(host) <- URI.new(String.trim(url)),
         host = String.downcase(host),
         provider when not is_nil(provider) <- meeting_provider(host),
         true <- meeting_path?(provider, uri.path) do
      {provider, uri |> Map.put(:host, host) |> URI.to_string()}
    else
      _ -> nil
    end
  end

  def canonical_meeting_url(_url), do: nil

  @doc """
  The first recognized meeting link in free text (an event's location or
  description, possibly HTML), other than a Google Meet link, or nil. Only
  the first #{div(@max_text_bytes, 1_024)} KiB are read.
  """
  @spec text_meeting_url(term()) :: String.t() | nil
  def text_meeting_url(text) when is_binary(text) do
    text = binary_part(text, 0, min(byte_size(text), @max_text_bytes))

    @text_url
    |> Regex.scan(text)
    |> Enum.find_value(fn [candidate] ->
      case candidate |> clean_text_url() |> canonical_meeting_url() do
        {:google_meet, _url} -> nil
        {_provider, url} -> url
        nil -> nil
      end
    end)
  end

  def text_meeting_url(_text), do: nil

  # An HTML attribute encodes `&` as `&amp;`; sentence punctuation or an
  # entity such as `&nbsp;` right after a link is not part of it.
  defp clean_text_url(candidate) do
    cleaned =
      candidate
      |> String.replace(~r/&(amp|#0*38|#x0*26);/i, "&")
      |> String.replace(~r/(&#?[a-z0-9]{1,8};|[.,;:!?*)\]}])+\z/i, "")

    if cleaned == candidate, do: cleaned, else: clean_text_url(cleaned)
  end

  defp meeting_path?(:google_meet, _path), do: true

  defp meeting_path?(provider, path) when is_binary(path),
    do: Regex.match?(Map.fetch!(@meeting_paths, provider), path)

  defp meeting_path?(_provider, _path), do: false

  defp meeting_provider("meet.google.com"), do: :google_meet
  defp meeting_provider(host) when host in @teams_hosts, do: :teams

  defp meeting_provider(host) do
    case String.split(host, ".", parts: 2) do
      [label, domain] when domain in @lark_domains ->
        if label == "vc" or Regex.match?(@lark_region, label), do: :lark

      _ ->
        if Enum.any?(@zoom_domains, &(host == &1 or String.ends_with?(host, "." <> &1))),
          do: :zoom
    end
  end

  @spec canonical_google_meet_url(term()) :: String.t() | nil
  def canonical_google_meet_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: "https", host: host} = uri
      when is_binary(host) and host != "" ->
        if String.downcase(host) == "meet.google.com" do
          uri
          |> Map.put(:scheme, "https")
          |> Map.put(:host, "meet.google.com")
          |> URI.to_string()
        end

      _ ->
        nil
    end
  end

  def canonical_google_meet_url(_url), do: nil

  @doc "Redact Google Meet URLs embedded in an untrusted public string."
  @spec redact_google_meet_urls(term()) :: term()
  def redact_google_meet_urls(value) when is_binary(value) do
    Regex.replace(@https_url, value, fn candidate ->
      if google_meet_url?(candidate), do: "[REDACTED_GOOGLE_MEET_URL]", else: candidate
    end)
  end

  def redact_google_meet_urls(value), do: value

  defp qualify_eligible_item(item, object, occurrence) do
    case item_eligibility(item["meeting_qualification"]) do
      :eligible ->
        qualify_conference(effective_conference_url(object, occurrence))

      {:denied, reason} ->
        denied(reason)
    end
  end

  defp item_eligibility(%{"item_eligible" => true}), do: :eligible

  defp item_eligibility(%{"item_eligible" => false} = qualification),
    do: {:denied, item_reason(qualification["item_reason"] || qualification["reason"])}

  # Compatibility for items normalized before item eligibility became explicit.
  # The legacy reason distinguishes a conference-only denial from an item denial;
  # the old `authorized` boolean alone is never used to revive a denied item.
  defp item_eligibility(%{"reason" => reason})
       when reason in [
              "google_meet",
              "lark_meeting",
              "zoom_meeting",
              "teams_meeting",
              "no_supported_conference"
            ],
       do: :eligible

  defp item_eligibility(%{"reason" => reason}), do: {:denied, item_reason(reason)}
  defp item_eligibility(_qualification), do: {:denied, :unauthorized_meeting}

  defp item_reason("access_profile_restricted"), do: :access_profile_restricted
  defp item_reason("unsupported_timing"), do: :unsupported_timing
  defp item_reason("all_day_event"), do: :all_day_event
  defp item_reason(_reason), do: :unauthorized_meeting

  defp qualify_conference(url) do
    case canonical_meeting_url(url) do
      {provider, meeting_url} ->
        %Result{authorized: true, meet_url: meeting_url, reason: Map.fetch!(@reasons, provider)}

      nil when url in [nil, ""] ->
        denied(:no_supported_conference)

      nil ->
        denied(:unsupported_conference)
    end
  end

  defp effective_conference_url(object, occurrence) do
    occurrence
    |> get_in(["effective", "virtualLocations"])
    |> case do
      nil -> object["virtualLocations"]
      locations -> locations
    end
    |> case do
      locations when is_map(locations) -> get_in(locations, ["conference", "uri"])
      _other -> nil
    end
  end

  defp denied(reason), do: %Result{authorized: false, meet_url: nil, reason: reason}
end
