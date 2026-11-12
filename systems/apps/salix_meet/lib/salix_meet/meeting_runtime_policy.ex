defmodule SalixMeet.MeetingRuntimePolicy do
  @moduledoc """
  Runtime placement policy for one Meeting attempt.

  Automatic placement prefers the Group's VMM Station, then another connected
  runtime, then native.
  The Meeting records the selected target before dispatch.
  `lark_bot` dispatches nothing: Lark holds the bot in the meeting
  (`SalixMeet.LarkBot`).
  """

  @sources ~w(automatic connected_runtime native_runtime lark_bot)

  def sources, do: @sources

  @doc "Runtime source recorded on new provider-triggered Meetings."
  def default_source do
    if SystemsRuntime.get_env(:salix_meet, :runtime_driver) == SalixMeet.RuntimeDriver.HTTP do
      case SystemsRuntime.get_env(:salix_meet, :http_runtime_source) do
        source when source in ~w(connected_runtime native_runtime) -> source
        _ -> "connected_runtime"
      end
    else
      "automatic"
    end
  end

  def select(payload) when is_map(payload) do
    source = payload["runtime_source"] || get_in(payload, ["runtime_policy", "source"])

    connected =
      payload["connected_runtime"] || get_in(payload, ["runtime_policy", "connected_runtime"])

    cond do
      source not in @sources ->
        {:error, :meeting_runtime_source_required}

      connected == true and source != "connected_runtime" ->
        {:error, :meeting_runtime_policy_conflict}

      true ->
        {:ok, source}
    end
  end

  def select(_), do: {:error, :invalid_meeting_runtime_policy}

  def terminal?(status) when status in ~w(done failed cancelled), do: true
  def terminal?(_), do: false
end
