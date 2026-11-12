defmodule Comma.Repo.Migrations.KeyMemberSourceConsentsByAccount do
  use Ecto.Migration

  # A member can consent to several accounts of one toolkit. Every existing
  # receipt keeps its account; only the key widens. A receipt also keeps the
  # provider identity it was checked against, so receipts of one provider
  # account can be told apart from those of another without a provider read.
  def up do
    alter table(:comma_member_source_consents) do
      add(:provider_subject, :map)
    end

    execute(
      "ALTER TABLE comma_member_source_consents DROP CONSTRAINT comma_member_source_consents_pkey"
    )

    execute(
      "ALTER TABLE comma_member_source_consents ADD PRIMARY KEY (workspace_id, user_id, toolkit, connection_id)"
    )
  end

  def down do
    alter table(:comma_member_source_consents) do
      remove(:provider_subject)
    end

    execute(
      "ALTER TABLE comma_member_source_consents DROP CONSTRAINT comma_member_source_consents_pkey"
    )

    execute(
      "ALTER TABLE comma_member_source_consents ADD PRIMARY KEY (workspace_id, user_id, toolkit)"
    )
  end
end
