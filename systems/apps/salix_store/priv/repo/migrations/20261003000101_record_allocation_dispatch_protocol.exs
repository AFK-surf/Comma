defmodule SalixStore.Repo.Migrations.RecordAllocationDispatchProtocol do
  use Ecto.Migration

  def change do
    alter table(:compute_allocations) do
      add(:dispatch_protocol, :text)
    end
  end
end
