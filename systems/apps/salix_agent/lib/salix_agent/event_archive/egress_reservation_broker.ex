defmodule SalixAgent.EventArchive.EgressReservationBroker do
  @moduledoc false

  alias SalixAgent.EventArchive.Emit

  @request_tag :salix_egress_archive_reserve
  @reply_tag :salix_egress_archive_reserved
  @stop_tag :salix_egress_archive_reservation_stop
  @idle_timeout_ms 30_000
  @owner_exit_grace_ms 1_000

  @doc false
  def start(context, session_id) when is_map(context) do
    if SalixAgent.EventArchive.enabled?() do
      owner = self()
      token = make_ref()

      pid =
        spawn(fn ->
          owner_ref = Process.monitor(owner)
          loop(owner, owner_ref, token, context, session_id, :unreserved)
        end)

      {pid, token}
    end
  end

  def start(_context, _session_id), do: nil

  @doc false
  def stop({pid, token}) when is_pid(pid) and is_reference(token) do
    send(pid, {@stop_tag, token})
    :ok
  end

  def stop(_broker), do: :ok

  defp loop(owner, owner_ref, token, context, session_id, reservation) do
    receive do
      {@request_tag, ^token, request_ref, reply_to}
      when is_reference(request_ref) and is_pid(reply_to) ->
        reservation = reserve_once(reservation, context, session_id)
        send(reply_to, {@reply_tag, token, request_ref, reservation})
        loop(owner, owner_ref, token, context, session_id, reservation)

      {@stop_tag, ^token} ->
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        owner_exit_grace(token, context, session_id, reservation)
    after
      @idle_timeout_ms -> :ok
    end
  end

  defp owner_exit_grace(token, context, session_id, reservation) do
    receive do
      {@request_tag, ^token, request_ref, reply_to}
      when is_reference(request_ref) and is_pid(reply_to) ->
        reservation = reserve_once(reservation, context, session_id)
        send(reply_to, {@reply_tag, token, request_ref, reservation})
        owner_exit_grace(token, context, session_id, reservation)

      {@stop_tag, ^token} ->
        :ok
    after
      @owner_exit_grace_ms -> :ok
    end
  end

  defp reserve_once(:unreserved, context, session_id),
    do: Emit.reserve_egress(context, session_id)

  defp reserve_once(reservation, _context, _session_id), do: reservation
end
