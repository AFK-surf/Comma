defmodule SalixStore.Repo.Migrations.PlatformModelsMeetingTiers do
  @moduledoc """
  Run the platform models pass again: the deployment's meeting summary and
  transcription templates become the `summary` and `transcription` tiers.
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
