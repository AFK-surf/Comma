defmodule SalixVoice.Drain do
  @moduledoc """
  End this node's calls before the pod stops (docs/messaging-voice.md).

  `Comma.PodLifecycle.pre_stop/1` calls `drain/0` after readiness is withdrawn,
  so `SalixVoice.admit/1` already refuses new calls with `:draining`. Each
  local `CallActor` gets `{:voice_drain, from, ref}`: it asks the model to tell
  the caller that the call must end now, waits up to 5 s for the notice, and
  ends with reason `:draining` (WebSocket close 4503). A call still running
  after the wait is ended at once.
  """

  @pg SalixVoice.PG
  @wait_ms 8_000
  @force_wait_ms 2_000

  @doc "Drain local calls. Returns `:ok` or `{:error, {:voice_calls_remaining, n}}`."
  @spec drain(keyword()) :: :ok | {:error, {:voice_calls_remaining, pos_integer()}}
  def drain(opts \\ []) do
    if Process.whereis(@pg) do
      pids = :pg.get_local_members(@pg, :calls)
      ref = make_ref()

      monitors =
        Map.new(pids, fn pid ->
          send(pid, {:voice_drain, self(), ref})
          {Process.monitor(pid), pid}
        end)

      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, @wait_ms)
      remaining = await(monitors, deadline)

      Enum.each(remaining, fn {_mref, pid} -> send(pid, :voice_drain_now) end)
      force_deadline = System.monotonic_time(:millisecond) + @force_wait_ms
      remaining = await(remaining, force_deadline)
      Enum.each(remaining, fn {mref, _pid} -> Process.demonitor(mref, [:flush]) end)
      flush_drained(ref)

      case map_size(remaining) do
        0 -> :ok
        n -> {:error, {:voice_calls_remaining, n}}
      end
    else
      :ok
    end
  end

  defp await(monitors, _deadline) when map_size(monitors) == 0, do: monitors

  defp await(monitors, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, mref, :process, _pid, _reason} when is_map_key(monitors, mref) ->
        await(Map.delete(monitors, mref), deadline)
    after
      timeout -> monitors
    end
  end

  defp flush_drained(ref) do
    receive do
      {:voice_drained, ^ref, _call_id} -> flush_drained(ref)
    after
      0 -> :ok
    end
  end
end
