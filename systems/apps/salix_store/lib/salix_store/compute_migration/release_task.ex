defmodule SalixStore.ComputeMigration.ReleaseTask do
  @moduledoc "Bounded Group Compute inventory and post-rollout transfer entrypoints."
  alias SalixStore.ComputeMigration
  def run("inspect", attrs), do: ComputeMigration.inspect_page(attrs["cursor"])
  def run("transfer", attrs), do: ComputeMigration.transfer_page(attrs["cursor"])
  def run(_, _), do: {:error, :unsupported_command}
end
