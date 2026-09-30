defmodule Salix.Bindings.TriageFollowUpThreadReader do
  @moduledoc false

  @behaviour SalixIM.Ports.TriageFollowUpThreadReader

  @impl true
  def read(authority, connect, target)
      when is_map(authority) and is_map(connect) and is_map(target) do
    with channel_id when is_binary(channel_id) and channel_id != "" <- target["channel_id"],
         thread_ts when is_binary(thread_ts) and thread_ts != "" <- target["thread_ts"],
         true <- authority["approved_channel_id"] == channel_id do
      scoped_connect = Map.put(connect, "approved_channel_id", channel_id)

      authority
      |> Map.put("channel_id", channel_id)
      |> Map.put("thread_ts", thread_ts)
      |> Map.put("scope_kind", "thread")
      |> Salix.Bindings.ClickHouseTriageThreadReader.read(scoped_connect, [])
    else
      _invalid -> {:error, :invalid_triage_follow_up_target}
    end
  end

  def read(_authority, _connect, _target), do: {:error, :invalid_triage_follow_up_target}
end
