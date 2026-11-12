defmodule SalixStore.Repo.Migrations.AddLoopProductEvents do
  @moduledoc """
  A Loop may subscribe to one product event, such as `meeting.completed`
  (`SalixAgent.Loops.deliver_product_event/3`). Delivery reads the Group's
  active subscribers of one event through the partial index.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_loops) do
      add(:product_event, :text)
    end

    create(
      index(:agent_loops, [:group_id, :product_event],
        name: :agent_loops_product_event_idx,
        where: "status = 'active' AND product_event IS NOT NULL"
      )
    )
  end
end
