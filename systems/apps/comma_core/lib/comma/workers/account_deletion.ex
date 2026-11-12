defmodule Comma.Workers.AccountDeletion do
  @moduledoc """
  Stops the outside effects of a deleted account's Workspaces
  (`Comma.AccountDeletion`): each Group's IM connections are removed and its
  Cloud VM retired, so no channel or schedule reaches the Workspace's agents
  any more and none of them starts its Cloud VM.

  The operation row owns claim, retry and terminal failure. Each step repeats
  harmlessly, so a retry starts again from the first Workspace.
  """

  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 12,
    unique: [period: :infinity, fields: [:worker, :queue, :args]]

  import Ecto.Query

  require Logger

  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.{Operations, Repo}

  @generation 1

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"operation_id" => operation_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case run(operation_id, final_attempt?: attempt >= max_attempts) do
      {:ok, _operation} -> :ok
      {:busy, seconds} -> {:snooze, seconds}
      {:error, reason} -> {:error, "account_deletion:" <> classify(reason)}
    end
  end

  @doc false
  def run(operation_id, opts \\ []) when is_binary(operation_id) do
    case Operations.claim(operation_id, @generation) do
      {:ok, {:execute, operation}} -> retire(operation, Keyword.get(opts, :final_attempt?, false))
      {:ok, {_complete, operation}} -> {:ok, operation}
      {:error, :not_due} -> {:busy, 1}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retire(%ExternalOperation{} = operation, final_attempt?) do
    ids = List.wrap(operation.metadata["workspace_ids"])

    result =
      try do
        from(w in Workspace, where: w.id in ^ids and w.status == "deleted", order_by: w.id)
        |> Repo.all()
        |> Enum.reduce_while(:ok, fn workspace, :ok ->
          case Comma.Salix.Client.retire_workspace_scope(payload(workspace)) do
            :ok -> {:cont, :ok}
            {:error, :salix_client_not_configured} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      rescue
        exception ->
          Logger.warning("Account deletion cleanup failed",
            exception: inspect(exception.__struct__)
          )

          {:error, {:provider_exception, exception.__struct__}}
      end

    case result do
      :ok ->
        case Operations.succeed(operation.operation_id, @generation, operation.owner_id, %{
               "workspaces" => length(ids)
             }) do
          {:ok, {_kind, succeeded}} -> {:ok, succeeded}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        fail(operation, reason, final_attempt?)
    end
  end

  defp payload(workspace) do
    %{
      "id" => workspace.id,
      "salix_tenant_id" => workspace.salix_tenant_id,
      "default_group_id" => workspace.salix_group_id
    }
  end

  defp fail(operation, reason, final_attempt?) do
    error_class = classify(reason)

    if final_attempt? do
      case Operations.terminal_failed(operation.operation_id, @generation, error_class) do
        {:ok, _transition} -> {:error, reason}
        {:error, transition_reason} -> {:error, transition_reason}
      end
    else
      delay = min(300, trunc(:math.pow(2, min(operation.attempt, 8))))
      next_attempt_at = DateTime.add(SystemsClock.utc_now(), delay, :second)

      case Operations.retryable(operation.operation_id, @generation, error_class, next_attempt_at) do
        {:ok, _transition} -> {:error, reason}
        {:error, transition_reason} -> {:error, transition_reason}
      end
    end
  end

  defp classify({:provider_exception, _module}), do: "provider_exception"
  defp classify({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp classify(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify(_reason), do: "unknown"
end
