defmodule BridgeForTeams.Schema.OrgSsoIdentity do
  @moduledoc """
  Org-scoped external SSO identity. Feishu users may not have email, so the
  durable login key is the provider subject within an organization, not
  `users.email`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, inserted_at: :created_at]

  @providers ~w(feishu)
  @subject_types ~w(user_id union_id open_id)

  schema "org_sso_identities" do
    field :provider, :string
    field :provider_subject_type, :string
    field :provider_subject, :string
    field :email, :string
    field :mobile, :string
    field :display_name, :string
    field :provider_profile, :map, default: %{}
    field :last_seen_at, :utc_datetime_usec

    belongs_to :org, BridgeForTeams.Schema.Organization
    belongs_to :user, BridgeForTeams.Schema.User

    timestamps()
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [
      :org_id,
      :user_id,
      :provider,
      :provider_subject_type,
      :provider_subject,
      :email,
      :mobile,
      :display_name,
      :provider_profile,
      :last_seen_at
    ])
    |> normalize_blank(:email)
    |> normalize_blank(:mobile)
    |> normalize_blank(:display_name)
    |> validate_required([
      :org_id,
      :user_id,
      :provider,
      :provider_subject_type,
      :provider_subject
    ])
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:provider_subject_type, @subject_types)
    |> unique_constraint([:org_id, :provider, :provider_subject_type, :provider_subject],
      name: :org_sso_identities_provider_subject_index
    )
  end

  def providers, do: @providers
  def subject_types, do: @subject_types

  defp normalize_blank(changeset, field) do
    case get_change(changeset, field) do
      "" -> put_change(changeset, field, nil)
      _ -> changeset
    end
  end

  @type t :: %__MODULE__{}
end
