defmodule Comma.Repo.Migrations.AddMemberSourceItemQuote do
  use Ecto.Migration

  # Display text outside the item version. Collection fills it on the next
  # read of each source. Until then the hover shows the item title.
  def change do
    alter table(:comma_member_source_items) do
      add(:quote, :map)
    end
  end
end
