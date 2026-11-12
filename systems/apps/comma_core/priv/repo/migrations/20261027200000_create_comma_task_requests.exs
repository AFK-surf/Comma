defmodule Comma.Repo.Migrations.CreateCommaTaskRequests do
  use Ecto.Migration

  # A Provider User Link says which Comma account a chat app's user (a Slack
  # user of one connect) is, so a Router serving them in that chat acts for
  # that account. It is made when the person opens the link a Router posted
  # them and confirms it signed in; until then it is `pending` with its token.
  #
  # A Task Request Grant lets one person send Task Requests to one Workspace.
  # Its owner creates it as an invite; the invite token is its only authority
  # until the person who opens it accepts it. A Task Request is what such a
  # person sent: it runs nothing until the Workspace owner accepts it.
  def change do
    create table(:comma_provider_user_links, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:provider, :text, null: false)
      add(:connect_id, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:subject_name, :text)
      add(:user_id, references(:comma_users, type: :string, on_delete: :delete_all))
      add(:status, :text, null: false)
      add(:link_token, :text)
      add(:link_expires_at, :utc_datetime_usec)
      # The Agent tool calls waiting for this link (their capability requests).
      add(:waiting_requests, {:array, :map}, null: false, default: [])
      add(:linked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:comma_provider_user_links, [:connect_id, :subject_id],
        where: "status = 'active'",
        name: :comma_provider_user_links_active_subject_index
      )
    )

    create(
      unique_index(:comma_provider_user_links, [:link_token],
        where: "link_token IS NOT NULL",
        name: :comma_provider_user_links_token_index
      )
    )

    create(index(:comma_provider_user_links, [:user_id]))
    create(index(:comma_provider_user_links, [:connect_id, :subject_id, :status]))

    create(
      constraint(:comma_provider_user_links, :comma_provider_user_links_status_check,
        check: "status IN ('pending', 'active')"
      )
    )

    create table(:comma_task_request_grants, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:created_by, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:grantee_user_id, references(:comma_users, type: :string, on_delete: :delete_all))
      add(:invite_token, :text)
      add(:invite_expires_at, :utc_datetime_usec)
      add(:status, :text, null: false)
      add(:mode, :text, null: false)
      add(:daily_limit, :integer, null: false)
      add(:pending_limit, :integer, null: false)
      add(:accepted_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:comma_task_request_grants, [:invite_token],
        where: "invite_token IS NOT NULL",
        name: :comma_task_request_grants_invite_token_index
      )
    )

    # One live grant per person and Workspace: accepting a second invite
    # replaces the first (`Comma.TaskRequests.accept_invite/2`).
    create(
      unique_index(:comma_task_request_grants, [:workspace_id, :grantee_user_id],
        where: "status = 'active'",
        name: :comma_task_request_grants_active_grantee_index
      )
    )

    create(index(:comma_task_request_grants, [:workspace_id, :inserted_at]))
    create(index(:comma_task_request_grants, [:grantee_user_id]))

    create(
      constraint(:comma_task_request_grants, :comma_task_request_grants_status_check,
        check: "status IN ('invited', 'active', 'revoked')"
      )
    )

    create(
      constraint(:comma_task_request_grants, :comma_task_request_grants_mode_check,
        check: "mode IN ('review', 'auto_accept')"
      )
    )

    create(
      constraint(:comma_task_request_grants, :comma_task_request_grants_limits_check,
        check: "daily_limit BETWEEN 1 AND 200 AND pending_limit BETWEEN 1 AND 50"
      )
    )

    create table(:comma_task_requests, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(
        :grant_id,
        references(:comma_task_request_grants, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:workspace_id, references(:comma_workspaces, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:sender_user_id, references(:comma_users, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:client_request_id, :text, null: false)
      add(:title, :text, null: false)
      add(:content, :text, null: false)
      add(:status, :text, null: false)
      add(:decline_reason, :text)
      # How an accepted request went on: as a Task, or to the Router's chat.
      add(:accepted_as, :text)
      add(:group_id, :text)
      add(:task_id, :text)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:decided_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:comma_task_requests, [:sender_user_id, :client_request_id]))
    create(index(:comma_task_requests, [:workspace_id, :status, :inserted_at]))
    create(index(:comma_task_requests, [:grant_id, :inserted_at]))
    create(index(:comma_task_requests, [:sender_user_id, :inserted_at]))

    create(
      constraint(:comma_task_requests, :comma_task_requests_status_check,
        check: "status IN ('pending', 'accepted', 'declined', 'withdrawn')"
      )
    )

    create(
      constraint(:comma_task_requests, :comma_task_requests_accepted_as_check,
        check: "accepted_as IS NULL OR accepted_as IN ('task', 'router')"
      )
    )
  end
end
