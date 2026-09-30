defmodule BridgeForTeams.Schema.FeishuAppBinding do
  @moduledoc """
  One org-owned Feishu custom app, reusable across the SSO and bot capabilities.
  The binding stores only non-secret posture — capability flags and
  `*_configured` flags — never the secret bytes, which stay in their owning
  store (SSO secret in `org_sso_connections`, bot secret in Salix). The binding
  is the single place an admin enters credentials; saving fans the secret out to
  the enabled capabilities' stores. Verification status is not persisted here;
  it comes only from a live Run-checks result.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "feishu_app_bindings" do
    field :app_id, :string
    field :display_name, :string
    field :sso_enabled, :boolean, default: false
    field :bot_enabled, :boolean, default: false
    field :app_secret_configured, :boolean, default: false
    field :verification_token_configured, :boolean, default: false
    field :encrypt_key_configured, :boolean, default: false

    belongs_to :org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @castable ~w(org_id app_id display_name sso_enabled bot_enabled
               app_secret_configured verification_token_configured
               encrypt_key_configured)a

  @doc "Changeset for an org Feishu app binding (non-secret posture only)."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, @castable)
    |> validate_required([:org_id, :app_id])
    |> unique_constraint([:org_id, :app_id], name: :feishu_app_bindings_org_id_app_id_index)
  end

  @type t :: %__MODULE__{}
end
