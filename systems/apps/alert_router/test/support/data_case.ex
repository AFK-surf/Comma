defmodule AlertRouter.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      alias AlertRouter.Repo
    end
  end

  setup tags do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(AlertRouter.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end
end
