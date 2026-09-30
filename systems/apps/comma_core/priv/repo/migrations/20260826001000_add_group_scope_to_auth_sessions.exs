defmodule Comma.Repo.Migrations.AddGroupScopeToAuthSessions do
  use Ecto.Migration

  @moduledoc """
  Expands restricted session storage with canonical Group scope.

  The database constraint temporarily accepts the previous
  workspace-plus-conversation shape so an older instance can finish a rolling
  deployment without write failures. The new runtime never issues or
  authorizes that shape: its changeset and scope checks require `group_id`.
  Removing the legacy database alternative and validating the expanded check
  are later online migrations, after historical rows have been audited.
  """

  @lock_timeout "5s"

  def up do
    execute("SET LOCAL lock_timeout TO '#{@lock_timeout}'")

    alter table(:comma_auth_sessions) do
      add(:group_id, :text)
    end

    drop(constraint(:comma_auth_sessions, :comma_auth_sessions_scope_valid))

    # NOT VALID still enforces the check for every row written after this
    # statement, while avoiding a historical table scan under the catalog lock
    # required by ALTER TABLE. A later bounded release owns audit + VALIDATE.
    execute("""
    ALTER TABLE comma_auth_sessions
    ADD CONSTRAINT comma_auth_sessions_scope_valid CHECK (
        (
          restricted
          AND session_source = 'ops_api'
          AND (
            conversation_id IS NULL
            OR group_id IS NOT NULL
            OR workspace_id IS NOT NULL
          )
        ) OR (
          NOT restricted
          AND workspace_id IS NULL
          AND group_id IS NULL
          AND conversation_id IS NULL
          AND interaction_budget_remaining IS NULL
          AND cardinality(tool_allowlist) = 0
          AND consumed_interaction_ids = '{}'::jsonb
        )
    ) NOT VALID
    """)
  end

  def down do
    raise "Group-scoped session authority is a hard cut and cannot be rolled back safely"
  end
end
