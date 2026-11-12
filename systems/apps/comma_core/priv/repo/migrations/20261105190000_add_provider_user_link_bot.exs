defmodule Comma.Repo.Migrations.AddProviderUserLinkBot do
  use Ecto.Migration

  # Which bot a chat account is linked through, so that two links of one
  # person on one chat app read differently.
  def change do
    alter table(:comma_provider_user_links) do
      add(:subject_bot, :text)
    end
  end
end
