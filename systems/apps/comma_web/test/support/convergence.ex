defmodule CommaWeb.TestConvergence do
  @moduledoc false

  import Ecto.Query

  alias Comma.Data.ExternalOperation
  alias Comma.Workers.WorkspaceConvergence

  def workspace!(workspace_id) do
    operation =
      Comma.Repo.one!(
        from(operation in ExternalOperation,
          where:
            operation.operation_type == "workspace_convergence" and
              operation.owner_id == ^workspace_id,
          order_by: [desc: operation.generation],
          limit: 1
        )
      )

    case WorkspaceConvergence.run(operation.operation_id) do
      {:ok, %{status: "succeeded"}} -> :ok
      {:complete, %{status: "succeeded"}} -> :ok
      other -> raise "workspace convergence failed: #{inspect(other)}"
    end
  end
end
