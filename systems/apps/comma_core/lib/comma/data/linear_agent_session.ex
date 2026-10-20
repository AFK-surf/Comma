defmodule Comma.Data.LinearAgentSession do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:agent_session_id, :string, autogenerate: false}
  schema "comma_linear_agent_sessions" do
    belongs_to(:installation, Comma.Data.LinearInstallation, type: :string)
    # The member whose Workspace holds the Task; gone when they unlink, while
    # the Task and its Workspace stay.
    belongs_to(:member, Comma.Data.LinearMember, type: :string)
    field(:workspace_id, :string)
    field(:group_id, :string)
    # The chat Conversation with the Router; the Task the Router created from
    # it, once one exists.
    field(:conversation_id, :string)
    field(:task_conversation_id, :string)
    field(:issue_id, :string)
    field(:issue_identifier, :string)
    field(:issue_url, :string)

    timestamps(
      type: :utc_datetime_usec,
      updated_at: false,
      autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
    )
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :agent_session_id,
      :installation_id,
      :member_id,
      :workspace_id,
      :group_id,
      :conversation_id,
      :task_conversation_id,
      :issue_id,
      :issue_identifier,
      :issue_url
    ])
    |> validate_required([
      :agent_session_id,
      :installation_id,
      :workspace_id,
      :group_id,
      :conversation_id
    ])
    |> foreign_key_constraint(:installation_id)
    |> foreign_key_constraint(:member_id)
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint(:agent_session_id, name: :comma_linear_agent_sessions_pkey)
  end
end
