defmodule SalixCalendar.OccurrenceQualification.Result do
  @moduledoc false

  @enforce_keys [:authorized, :reason]
  defstruct authorized: false, meet_url: nil, reason: :unauthorized_meeting

  @type reason ::
          :google_meet
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
  conference. The only currently authorized conference is an HTTPS Google Meet URL
  on `meet.google.com`.
  """

  alias SalixCalendar.OccurrenceQualification.Result

  # Stop one candidate before any adjacent later `https://`. Calendar titles
  # commonly separate URLs with punctuation rather than whitespace; allowing
  # the first match to swallow the second would let the first host decide
  # whether a later Google Meet URL is redacted.
  @https_url ~r{https://(?:(?!https://)[^\s<>"'])+}iu

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

  @spec google_meet_url?(term()) :: boolean()
  def google_meet_url?(url), do: not is_nil(canonical_google_meet_url(url))

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
       when reason in ["google_meet", "no_supported_conference"],
       do: :eligible

  defp item_eligibility(%{"reason" => reason}), do: {:denied, item_reason(reason)}
  defp item_eligibility(_qualification), do: {:denied, :unauthorized_meeting}

  defp item_reason("access_profile_restricted"), do: :access_profile_restricted
  defp item_reason("unsupported_timing"), do: :unsupported_timing
  defp item_reason("all_day_event"), do: :all_day_event
  defp item_reason(_reason), do: :unauthorized_meeting

  defp qualify_conference(nil), do: denied(:no_supported_conference)
  defp qualify_conference(""), do: denied(:no_supported_conference)

  defp qualify_conference(url) do
    case canonical_google_meet_url(url) do
      meet_url when is_binary(meet_url) ->
        %Result{authorized: true, meet_url: meet_url, reason: :google_meet}

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
