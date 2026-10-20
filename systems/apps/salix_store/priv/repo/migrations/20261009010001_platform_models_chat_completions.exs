defmodule SalixStore.Repo.Migrations.PlatformModelsChatCompletions do
  @moduledoc """
  Run the platform models pass again: a platform default template without a
  protocol (Chat Completions, such as DeepSeek's) now becomes its tier too.
  """
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.PlatformModels.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Platform models migration failed: #{inspect(reason)}"
    end
  end
end
