defmodule Comma.PluginInstallAttempts do
  @moduledoc """
  Durable generation fence for the unified plugin installation command.

  The row lock serializes one workspace/plugin install, verification, or
  uninstall mutation while provider and Salix side effects are applied. A
  delayed verification therefore observes the generation written by a later
  cancellation, uninstall, or authorization and cannot re-enable the plugin.

  The former feature-level TLA model is historical. Runtime regressions cover
  this generation fence.
  """

  import Ecto.Query

  alias Comma.Data.PluginInstallAttempt
  alias Comma.Repo

  def with_lock(workspace_id, plugin_id, operation) when is_function(operation, 1) do
    with_lock_transaction(workspace_id, plugin_id, operation, false)
  end

  # Confirmation must commit its receipt, attempt retirement, and queue insert
  # together. A returned error tuple must roll the transaction back.
  def with_lock_rollback(workspace_id, plugin_id, operation) when is_function(operation, 1) do
    with_lock_transaction(workspace_id, plugin_id, operation, true)
  end

  defp with_lock_transaction(workspace_id, plugin_id, operation, rollback_errors?) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      %PluginInstallAttempt{
        workspace_id: workspace_id,
        plugin_id: plugin_id,
        generation: 0,
        inserted_at: now,
        updated_at: now
      }
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:workspace_id, :plugin_id])

      attempt =
        Repo.one!(
          from(attempt in PluginInstallAttempt,
            where:
              attempt.workspace_id == ^workspace_id and
                attempt.plugin_id == ^plugin_id,
            lock: "FOR UPDATE"
          )
        )

      case operation.(attempt) do
        {:error, reason} when rollback_errors? -> Repo.rollback(reason)
        result -> result
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} when rollback_errors? -> {:error, reason}
      {:error, _reason} -> {:error, :plugins_unavailable}
    end
  rescue
    _error -> {:error, :plugins_unavailable}
  end

  def reserve_locked(%PluginInstallAttempt{} = attempt) do
    attempt
    |> Ecto.Changeset.change(%{
      authorization_state: nil,
      generation: attempt.generation + 1,
      provider_state: nil,
      operation_kind: nil,
      initiator_user_id: nil,
      operation_data: nil,
      expires_at: nil
    })
    |> Repo.update()
  end

  # A confirmation reserves its generation before the provider identity read.
  # Network I/O then runs outside the row lock and finalization compares this
  # generation again before exposing the candidate to the client.
  def reserve_confirmation_locked(attempt, user_id, toolkit, connection_id, prior_revision) do
    with {:ok, reserved} <- reserve_locked(attempt) do
      reserved
      |> Ecto.Changeset.change(%{
        operation_kind: "confirm_existing",
        initiator_user_id: user_id,
        operation_data: %{
          "toolkit" => toolkit,
          "connection_id" => connection_id,
          "prior_revision" => prior_revision
        },
        expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
      })
      |> Repo.update()
    end
  end

  def record_confirmation_locked(attempt, generation, identity)
      when is_map(identity) do
    if attempt.generation == generation and attempt.operation_kind == "confirm_existing" and
         not expired?(attempt) do
      attempt
      |> Ecto.Changeset.change(%{
        authorization_state: Ecto.UUID.generate(),
        operation_data: Map.put(attempt.operation_data, "identity", identity)
      })
      |> Repo.update()
    else
      {:error, :stale_plugin_operation}
    end
  end

  def reserve_reauthorization_locked(attempt, user_id, connection_id) do
    if attempt.operation_kind == "reauthorize" and
         get_in(attempt.operation_data || %{}, ["callback_phase"]) == "committing" and
         not expired?(attempt) do
      {:error, :authorization_callback_in_progress}
    else
      do_reserve_reauthorization_locked(attempt, user_id, connection_id)
    end
  end

  defp do_reserve_reauthorization_locked(attempt, user_id, connection_id) do
    with {:ok, reserved} <- reserve_locked(attempt) do
      reserved
      |> Ecto.Changeset.change(%{
        operation_kind: "reauthorize",
        initiator_user_id: user_id,
        operation_data: %{"connection_id" => connection_id},
        expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
      })
      |> Repo.update()
    end
  end

  # The callback claims the generation after token exchange and before any
  # credential or binding write. Cancellation and another authorization cannot
  # succeed while that write is in progress.
  def claim_reauthorization_callback_locked(attempt, generation, provider_state, user_id) do
    if attempt.operation_kind == "reauthorize" and attempt.generation == generation and
         attempt.provider_state == provider_state and attempt.initiator_user_id == user_id and
         is_binary(attempt.authorization_state) and
         get_in(attempt.operation_data || %{}, ["callback_phase"]) == nil and
         not expired?(attempt) do
      attempt
      |> Ecto.Changeset.change(
        operation_data: Map.put(attempt.operation_data, "callback_phase", "committing")
      )
      |> Repo.update()
    else
      {:error, :stale_plugin_operation}
    end
  end

  def finish_reauthorization_callback_locked(attempt, generation, provider_state, outcome) do
    if attempt.operation_kind == "reauthorize" and attempt.generation == generation and
         attempt.provider_state == provider_state and
         get_in(attempt.operation_data || %{}, ["callback_phase"]) == "committing" do
      attempt
      |> Ecto.Changeset.change(
        operation_data: Map.put(attempt.operation_data, "callback_phase", outcome),
        expires_at: DateTime.add(DateTime.utc_now(), 120, :second)
      )
      |> Repo.update()
    else
      {:error, :stale_plugin_operation}
    end
  end

  def record_reauthorization_locked(attempt, generation, provider_state)
      when is_binary(provider_state) and provider_state != "" do
    if attempt.generation == generation and attempt.operation_kind == "reauthorize" and
         not expired?(attempt) do
      attempt
      |> Ecto.Changeset.change(%{
        authorization_state: Ecto.UUID.generate(),
        provider_state: provider_state
      })
      |> Repo.update()
    else
      {:error, :stale_plugin_operation}
    end
  end

  def record_authorization_locked(%PluginInstallAttempt{} = attempt, provider_state)
      when is_binary(provider_state) and provider_state != "" do
    attempt
    |> Ecto.Changeset.change(%{
      authorization_state: Ecto.UUID.generate(),
      provider_state: provider_state
    })
    |> Repo.update()
  end

  def active?(%PluginInstallAttempt{} = attempt, state),
    do:
      is_binary(state) and state != "" and attempt.authorization_state == state and
        not expired?(attempt)

  def expired?(%PluginInstallAttempt{expires_at: nil}), do: false

  def expired?(%PluginInstallAttempt{expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  def invalidate_locked(%PluginInstallAttempt{} = attempt) do
    reserve_locked(attempt)
  end

  def complete_locked(%PluginInstallAttempt{} = attempt) do
    attempt
    |> Ecto.Changeset.change(%{
      authorization_state: nil,
      provider_state: nil,
      operation_kind: nil,
      initiator_user_id: nil,
      operation_data: nil,
      expires_at: nil
    })
    |> Repo.update()
  end
end
