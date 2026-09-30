defmodule SalixAgent.LegacyGuardSnapshotRepair do
  @moduledoc """
  Retires duplicated guard diagnostic keys from hot history, not input identity
  or guard control state. Exact source bytes survive in an ETag-specific backup;
  the hot CAS never overwrites another writer. Sealed segments are not rewritten.
  Modeled in tla/salix/LegacyGuardRepair.tla.
  """
  alias SalixAgent.InternalSession
  alias SalixAgent.SessionStorageRevision
  alias SalixStore.{Codec, Keys, S3}
  alias SalixStore.S3.Settle

  def read_limit,
    do: Application.get_env(:salix_agent, :snapshot_read_max_bytes, 64 * 1024 * 1024)

  def recover(key) do
    timeout = Application.get_env(:salix_agent, :snapshot_repair_timeout_ms, 30_000)

    task =
      Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
        case Registry.register(SalixAgent.Registry, :snapshot_repair_lane, nil) do
          {:ok, _} ->
            # OTP owns this timer even if the original reader dies.
            {:ok, timer} = :timer.exit_after(timeout, self(), :kill)

            try do
              run(key, 256 * 1024 * 1024)
            after
              :timer.cancel(timer)
            end

          {:error, {:already_registered, _}} ->
            {:error, :snapshot_repair_busy}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :snapshot_repair_failed}
    end
  end

  def run(key, limit), do: repair(key, limit, 3)
  defp repair(_key, _limit, 0), do: {:error, :concurrent_session_write}

  defp repair(key, limit, attempts) do
    with {:ok, %{body: bytes, etag: etag}} <- S3.get(key),
         {:ok, raw} <- SalixStore.BoundedSnapshot.inflate(bytes, limit),
         {:ok, cleaned} <- SalixStore.GuardETF.clean(raw, read_limit()),
         {:ok, state} <- InternalSession.admit(cleaned),
         true <-
           Keys.agent_internal_runtime_session(
             InternalSession.agent_id(state),
             InternalSession.session_id(state)
           ) == key do
      if raw == cleaned do
        {:ok, :unchanged}
      else
        next =
          InternalSession.stamp(state,
            storage_revision: SessionStorageRevision.new(),
            flush_id: SessionStorageRevision.new()
          )

        backup =
          String.replace_suffix(
            key,
            "state.etf.zst",
            "backup/guard-keys/#{Base.url_encode64(etag, padding: false)}/state.etf.zst"
          )

        with :ok <- backup(backup, bytes) do
          body = next |> InternalSession.persist() |> Codec.compress_snapshot_etf()

          case Settle.cas_put(key, body, etag) do
            :ok -> {:ok, :repaired}
            {:error, :precondition_failed} -> repair(key, limit, attempts - 1)
            error -> error
          end
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_session_snapshot}
    end
  end

  defp backup(key, bytes) do
    case Settle.create_once(key, bytes, Settle.byte_settle(bytes)) do
      :created -> :ok
      :landed -> :ok
      {:exists, _} -> {:error, :backup_divergence}
      {:error, _} = error -> error
    end
  end

  @doc false
  def clean_event(%{"kind" => kind, "event" => payload} = event)
      when kind in ["runaway_guard_reset", "runaway_unsettled_round"] and is_map(payload),
      do: %{event | "event" => Map.delete(payload, "activation_key")}

  def clean_event(event), do: event
end
