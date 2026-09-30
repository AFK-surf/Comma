defmodule SalixMeet.RuntimeDriver.SalixConnect do
  @moduledoc """
  Connector implementation of `SalixMeet.RuntimeDriver`.

  Instead of posting to a fixed runtime URL, the join is dispatched to a
  connected environment that advertises the meeting runtime capability. The
  connector drives a co-located meetnative process and streams runtime events
  back over the connector socket.
  """

  @behaviour SalixMeet.RuntimeDriver

  alias SalixMeet.Ports.MeetingDispatch

  @impl true
  def join(meeting_doc) when is_map(meeting_doc) do
    MeetingDispatch.join(join_payload(meeting_doc))
  end

  defp join_payload(%{"id" => meeting_id, "state" => state} = doc) do
    state = stringify(state || %{})

    %{
      "meeting_id" => meeting_id,
      "tenant_id" => state["tenant_id"],
      "group_id" => trim(state["group_id"]),
      "meeting_agent_id" => state["meeting_agent_id"],
      "meeting_session_id" => state["meeting_session_id"],
      "provider" => state["provider"],
      "connect_id" => state["connect_id"],
      "meet_url" => state["meet_url"],
      "title" => state["title"],
      "caption_language" => state["caption_language"],
      "bot_name" => state["bot_name"],
      "runtime_token" => state["runtime_token"],
      "runtime_ref" => state["runtime_ref"],
      "runtime_source" => state["runtime_source"],
      "runtime_policy" => state["runtime_policy"],
      "compute_environment_id" => state["compute_environment_id"],
      "workload_id" => state["workload_id"],
      "attempt" => state["attempt"],
      "artifact_root" => state["artifact_root"],
      "join_requested_at" => doc["join_requested_at"]
    }
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(value), do: String.trim(to_string(value || ""))
end
