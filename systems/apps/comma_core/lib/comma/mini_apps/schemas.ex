defmodule Comma.MiniApps.App do
  @moduledoc """
  A Mini App (`comma_mini_apps`): one Workspace's app, its GitHub repository,
  its live Version, sharing and the owner Workspace's grants. `secrets` maps a
  backend secret name to its sealed value (`Comma.MiniApps.Secrets`).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "comma_mini_apps" do
    field(:slug, :string)
    field(:workspace_id, :string)
    field(:group_id, :string)
    field(:created_by, :string)
    field(:name, :string)
    field(:description, :string, default: "")
    field(:repo_owner, :string)
    field(:repo_name, :string)
    field(:visibility, :string, default: "private")
    field(:status, :string, default: "active")
    field(:disabled_by, :string)
    field(:live_version_id, :binary_id)
    field(:next_version, :integer, default: 1)
    field(:grants, {:array, :string}, default: [])
    field(:secrets, :map, default: %{})
    field(:data_script, :boolean, default: false)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end

defmodule Comma.MiniApps.Version do
  @moduledoc """
  One immutable build of a Mini App (`comma_mini_app_versions`), numbered per
  app. `uploading` → `ready` | `failed`. `deploy_key` makes a repeated deploy
  return the same Version.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "comma_mini_app_versions" do
    field(:app_id, :binary_id)
    field(:number, :integer)
    field(:state, :string, default: "uploading")
    field(:deploy_key, :string)
    field(:commit, :string)
    field(:digest, :string)
    field(:manifest, :map, default: %{})
    field(:script_name, :string)
    field(:bundle_size, :integer, default: 0)
    field(:conversation_id, :string)
    field(:message_seq, :integer)
    field(:notes, :string)
    field(:error, :string)
    field(:failed_at, :utc_datetime_usec)
    field(:blobs_deleted_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end

defmodule Comma.MiniApps.Link do
  @moduledoc """
  The share link of a Mini App (`comma_mini_app_links`): the Task Share token
  model. One active link per app; reset revokes it and issues a new token.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "comma_mini_app_links" do
    field(:app_id, :binary_id)
    field(:token, :string)
    field(:created_by, :string)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end

defmodule Comma.MiniApps.Install do
  @moduledoc """
  A Workspace's Install of another Workspace's Mini App
  (`comma_mini_app_installs`): its grants, and the Version it pins (nil
  follows the live Version).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "comma_mini_app_installs" do
    field(:app_id, :binary_id)
    field(:workspace_id, :string)
    field(:installed_by, :string)
    field(:pinned_version, :integer)
    field(:grants, {:array, :string}, default: [])

    timestamps(
      type: :utc_datetime_usec,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end
end
