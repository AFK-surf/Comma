defmodule BridgeForTeams.Schema.OrgSsoConnection do
  @moduledoc """
  Per-org SSO IdP configuration (design §5 `org_sso_connections`, §7).
  `client_secret` is stored as-is (no encryption at rest). `allowed_domains`
  gates generic OIDC provisioning; Feishu uses an org-scoped provider subject
  instead of email-domain admission. `default_role` is the provisioned org role.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(generic_oidc feishu)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  schema "org_sso_connections" do
    field :provider, :string, default: "generic_oidc"
    field :issuer, :string
    field :client_id, :string
    field :client_secret, :string
    field :allowed_domains, {:array, :string}, default: []
    field :default_role, :string, default: "member"
    field :provider_config, :map, default: %{}
    field :last_verified_at, :utc_datetime_usec
    field :last_error_code, :string

    belongs_to :org, BridgeForTeams.Schema.Organization

    timestamps()
  end

  @doc "Changeset for an org SSO connection."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(conn, attrs) do
    conn
    |> cast(attrs, [
      :org_id,
      :provider,
      :issuer,
      :client_id,
      :client_secret,
      :allowed_domains,
      :default_role,
      :provider_config,
      :last_verified_at,
      :last_error_code
    ])
    |> validate_required([:org_id, :provider, :client_id])
    |> validate_inclusion(:provider, @providers)
    |> validate_provider_fields()
    |> unique_constraint(:org_id)
  end

  def providers, do: @providers

  defp validate_provider_fields(changeset) do
    case get_field(changeset, :provider) do
      "generic_oidc" -> validate_required(changeset, [:issuer])
      "feishu" -> validate_required(changeset, [:client_secret])
      _ -> changeset
    end
  end

  @type t :: %__MODULE__{}
end
