defmodule SalixMeet.MeetingRuntimePolicy do
  @moduledoc """
  Explicit, single-source runtime policy for one Meeting attempt.

  The policy is durable input to dispatch. It never selects whichever runtime
  happens to report ready first and it rejects a request that names both
  Connected and Compute targets.
  """

  @sources ~w(connected_runtime compute_workload)

  def sources, do: @sources

  def select(payload) when is_map(payload) do
    source = payload["runtime_source"] || get_in(payload, ["runtime_policy", "source"])

    connected =
      payload["connected_runtime"] || get_in(payload, ["runtime_policy", "connected_runtime"])

    compute =
      payload["compute_workload"] || get_in(payload, ["runtime_policy", "compute_workload"])

    cond do
      connected == true and compute == true ->
        {:error, :dual_meeting_runtime_selector}

      source not in @sources ->
        {:error, :meeting_runtime_source_required}

      connected == true and source != "connected_runtime" ->
        {:error, :meeting_runtime_policy_conflict}

      compute == true and source != "compute_workload" ->
        {:error, :meeting_runtime_policy_conflict}

      true ->
        {:ok, source}
    end
  end

  def select(_), do: {:error, :invalid_meeting_runtime_policy}

  def terminal?(status) when status in ~w(done failed cancelled), do: true
  def terminal?(_), do: false
end
