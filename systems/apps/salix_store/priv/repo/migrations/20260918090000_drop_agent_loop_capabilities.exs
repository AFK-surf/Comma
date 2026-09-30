defmodule SalixStore.Repo.Migrations.DropAgentLoopCapabilities do
  use Ecto.Migration

  # Background Loops no longer carry a per-Loop capability grant list: the
  # program is the Agent's own, so every Loop may call the whole closed
  # allowlist under its creator's authorization
  # (`SalixAgent.Loops.Capabilities`). The stored grants are disposable by
  # that decision; nothing reads them after this release, so the column goes
  # rather than lingering as dead state. A pre-release binary that still
  # selects the column fails its Loop reads until the rollout completes,
  # which the rollout policy accepts as temporary feature unavailability.
  def change do
    alter table(:agent_loops) do
      remove(:capabilities, :map, null: false, default: %{})
    end
  end
end
