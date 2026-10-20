defmodule BridgeForTeams.Schema.Organization do
  @moduledoc """
  Account/billing/identity root (design §5 `organizations`). Maps 1:1 onto a
  Salix **tenant** (`salix_tenant_id`) — the IM/OAuth/API-key isolation root.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_icon_chars 512_000
  @icon_prefixes [
    "data:image/png;base64,",
    "data:image/jpeg;base64,",
    "data:image/jpg;base64,",
    "data:image/gif;base64,",
    "data:image/webp;base64,"
  ]

  # Default dashboard locale for members who haven't picked one. Mirrors
  # BridgeForTeamsWeb.I18n; nil means "no org default" (fall through to
  # Accept-Language). See docs/bridge-for-teams/design.md.
  @supported_locales ~w(en zh_Hans)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [
    type: :utc_datetime_usec,
    inserted_at: :created_at,
    autogenerate: {SystemsClock, :timestamp, [:utc_datetime_usec]}
  ]

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :icon, :string
    field :billing_account_id, :string
    field :default_locale, :string
    # Model governance (`BridgeForTeams.Models`), as Salix model choices
    # (`SalixAgent.ModelChoice` values): the choices this org's admins can give
    # to Agents (empty = every model), and the choice that a new Router or
    # Worker gets. A nil default = the platform model of the role.
    field :allowed_models, {:array, :map}, default: []
    field :default_router_model, :map
    field :default_task_model, :map, source: :default_worker_model
    # The Org <-> Salix link: the canonical Salix tenant id.
    field :salix_tenant_id, :string

    has_many :memberships, BridgeForTeams.Schema.OrgMembership, foreign_key: :org_id
    has_many :projects, BridgeForTeams.Schema.Project, foreign_key: :org_id
    has_many :sso_connections, BridgeForTeams.Schema.OrgSsoConnection, foreign_key: :org_id

    timestamps()
  end

  @doc "Changeset for an organization. (schemas slice fills validations.)"
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(org, attrs) do
    org
    |> cast(attrs, [
      :name,
      :slug,
      :status,
      :icon,
      :billing_account_id,
      :salix_tenant_id,
      :default_locale,
      :allowed_models,
      :default_router_model,
      :default_task_model
    ])
    |> update_change(:icon, &blank_to_nil/1)
    |> update_change(:billing_account_id, &blank_to_nil/1)
    |> update_change(:salix_tenant_id, &blank_to_nil/1)
    |> update_change(:default_locale, &blank_to_nil/1)
    |> reject_identity_update(attrs, :salix_tenant_id)
    |> validate_required([:name, :slug, :billing_account_id, :salix_tenant_id])
    |> validate_length(:icon, max: @max_icon_chars)
    |> validate_icon()
    |> validate_model_choices()
    |> validate_inclusion(:default_locale, @supported_locales)
    |> unique_constraint(:slug)
    |> unique_constraint(:billing_account_id)
    |> unique_constraint(:salix_tenant_id)
  end

  defp reject_identity_update(%Ecto.Changeset{data: %{id: nil}} = changeset, _attrs, _field),
    do: changeset

  defp reject_identity_update(changeset, attrs, field) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
      add_error(changeset, field, "is immutable")
    else
      changeset
    end
  end

  @doc "The locales accepted for `:default_locale`."
  @spec supported_locales() :: [String.t()]
  def supported_locales, do: @supported_locales

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # The shape only; `BridgeForTeams.Models` checks choices against Salix.
  defp validate_model_choices(changeset) do
    changeset
    |> validate_change(:allowed_models, fn :allowed_models, choices ->
      if Enum.all?(choices, &model_choice?/1), do: [], else: [allowed_models: "is invalid"]
    end)
    |> validate_change(:default_router_model, &validate_model_choice/2)
    |> validate_change(:default_task_model, &validate_model_choice/2)
  end

  defp validate_model_choice(field, choice),
    do: if(model_choice?(choice), do: [], else: [{field, "is invalid"}])

  defp model_choice?(%{"kind" => kind}) when is_binary(kind), do: true
  defp model_choice?(_choice), do: false

  defp validate_icon(changeset) do
    validate_change(changeset, :icon, fn :icon, icon ->
      if Enum.any?(@icon_prefixes, &String.starts_with?(icon, &1)) do
        []
      else
        [icon: "must be an inline PNG, JPEG, GIF, or WebP data URL"]
      end
    end)
  end

  @type t :: %__MODULE__{}
end
