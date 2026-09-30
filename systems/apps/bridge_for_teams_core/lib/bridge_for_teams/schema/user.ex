defmodule BridgeForTeams.Schema.User do
  @moduledoc "A person who authenticates to BridgeForTeams (design §5 `users`). No Salix object."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  # Dashboard locales the user may prefer. Mirrors BridgeForTeamsWeb.I18n /
  # the Gettext config; nil means "no explicit choice" (fall through to
  # Accept-Language negotiation). See docs/bridge-for-teams/design.md.
  @supported_locales ~w(en zh_Hans)

  schema "users" do
    field :email, :string
    field :name, :string
    field :status, :string, default: "active"
    field :preferred_locale, :string

    has_many :org_memberships, BridgeForTeams.Schema.OrgMembership, foreign_key: :user_id
    has_many :project_memberships, BridgeForTeams.Schema.ProjectMembership, foreign_key: :user_id
    has_many :org_sso_identities, BridgeForTeams.Schema.OrgSsoIdentity, foreign_key: :user_id
    has_many :sessions, BridgeForTeams.Schema.AuthSession, foreign_key: :user_id

    has_many :account_recovery_links, BridgeForTeams.Schema.AccountRecoveryLink,
      foreign_key: :user_id

    timestamps()
  end

  @doc "Changeset for a user. Email is optional for subject-based SSO, unique when present."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :status, :preferred_locale])
    |> normalize_blank_email()
    |> validate_inclusion(:preferred_locale, @supported_locales)
    |> unique_constraint(:email)
  end

  @doc "The locales accepted for `:preferred_locale`."
  @spec supported_locales() :: [String.t()]
  def supported_locales, do: @supported_locales

  defp normalize_blank_email(changeset) do
    case get_change(changeset, :email) do
      "" -> put_change(changeset, :email, nil)
      _ -> changeset
    end
  end

  @type t :: %__MODULE__{}
end
