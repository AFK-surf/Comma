defmodule SalixStore.Repo.Migrations.TemplatePinChoices do
  @moduledoc "Give Routers and Workers that pin a template the model choice it stands for, during a rolling release."
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    {:ok, _} = Application.ensure_all_started(:salix_store)

    case SalixAgent.Migrations.TemplatePinChoices.run() do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Template pin choices migration failed: #{inspect(reason)}"
    end
  end
end
