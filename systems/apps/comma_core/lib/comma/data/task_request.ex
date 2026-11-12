defmodule Comma.Data.TaskRequestGrant do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_task_request_grants" do
    field(:workspace_id, :string)
    field(:created_by, :string)
    field(:grantee_user_id, :string)
    field(:invite_token, :string, redact: true)
    field(:invite_expires_at, :utc_datetime_usec)
    field(:status, :string)
    field(:mode, :string)
    field(:daily_limit, :integer)
    field(:pending_limit, :integer)
    field(:accepted_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end

defmodule Comma.Data.TaskRequest do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_task_requests" do
    field(:grant_id, :string)
    field(:workspace_id, :string)
    field(:sender_user_id, :string)
    field(:client_request_id, :string)
    field(:title, :string)
    field(:content, :string)
    field(:status, :string)
    field(:decline_reason, :string)
    field(:accepted_as, :string)
    field(:group_id, :string)
    field(:task_id, :string)
    field(:task_status, :string)
    field(:task_reply, :string)
    field(:task_updated_at, :utc_datetime_usec)
    field(:sender_group_id, :string)
    field(:source, :map)
    field(:reported_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:decided_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end

defmodule Comma.Data.ProviderUserLink do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "comma_provider_user_links" do
    field(:provider, :string)
    field(:connect_id, :string)
    field(:subject_id, :string)
    field(:subject_name, :string)
    field(:subject_email, :string)
    field(:subject_workspace, :string)
    field(:subject_bot, :string)
    field(:user_id, :string)
    field(:status, :string)
    field(:link_token, :string, redact: true)
    field(:link_expires_at, :utc_datetime_usec)
    field(:waiting_requests, {:array, :map}, default: [])
    field(:linked_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end
