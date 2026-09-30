defmodule BridgeForTeams.Schema.UserAssistantChat do
  @moduledoc """
  Binding between a user and their "New Home" assistant conversation.

  The dashboard's New Home chat panel talks to a real Salix agent through a
  project conversation; this row remembers which org/project/conversation
  backs that panel so the same thread is reused across visits. One row per
  user per project (swarm); `org_id` stays denormalized for org-scoped reads.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "user_assistant_chats" do
    field :conversation_id, :string
    # Which revision of the dashboard-context instructions the conversation
    # last received. NULL digests on pre-tracking rows refresh once on the next
    # visit. `context_summary_seq` is retained historical observation data;
    # compaction is no longer a refresh trigger (see AssistantChats).
    field :context_digest, :string
    field :context_summary_seq, :integer
    # Internal replacement recovery state. A marked row is never returned by
    # `AssistantChats.ensure_chat/4`; its seed advances deterministic Salix
    # create identities when a replacement candidate is explicitly malformed.
    field :disposition, :string
    field :replacement_seed_conversation_id, :string

    belongs_to :user, BridgeForTeams.Schema.User
    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :project, BridgeForTeams.Schema.Project

    timestamps()
  end

  @doc "Changeset for a user assistant chat binding."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [
      :user_id,
      :org_id,
      :project_id,
      :conversation_id,
      :context_digest,
      :context_summary_seq,
      :disposition,
      :replacement_seed_conversation_id
    ])
    |> validate_required([:user_id, :org_id, :project_id, :conversation_id])
    |> unique_constraint([:user_id, :project_id])
  end

  @type t :: %__MODULE__{}
end
