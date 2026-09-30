defmodule Comma.DataCase do
  @moduledoc "SQL sandbox setup for Comma-owned PostgreSQL tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Comma.Repo

      import Ecto.Query
      import Comma.WorkspaceTestSupport
    end
  end

  setup tags do
    if tags[:sandbox] == false do
      :ok
    else
      owner_opts = [shared: not tags[:async]]

      owner_opts =
        case tags[:database_isolation] do
          isolation when is_binary(isolation) -> Keyword.put(owner_opts, :isolation, isolation)
          _other -> owner_opts
        end

      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Comma.Repo, owner_opts)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      :ok
    end
  end
end
