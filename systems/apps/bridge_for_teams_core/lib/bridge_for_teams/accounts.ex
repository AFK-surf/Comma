defmodule BridgeForTeams.Accounts do
  @moduledoc """
  User account context (design §5 `users`, §7). Handles user records and the
  JIT provisioning of users from OIDC claims.
  """
  import Ecto.Changeset, only: [validate_required: 2]

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.User
  alias BridgeForTeams.{Memberships, Orgs}

  @doc "Create a user."
  @spec create_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> validate_required([:email])
    |> Repo.insert()
  end

  @doc "Fetch a user by id."
  @spec get_user(Ecto.UUID.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc "Fetch a user by email (citext, case-insensitive)."
  @spec get_user_by_email(String.t()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc "Update a user."
  @spec update_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Set a user's preferred dashboard locale (e.g. `"en"`, `"zh_Hans"`). Invalid
  locales are rejected by the changeset's inclusion validation.
  """
  @spec update_locale(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_locale(%User{} = user, locale) do
    update_user(user, %{"preferred_locale" => locale})
  end

  @doc """
  Just-in-time provision a user (and, if needed, org membership) from verified
  OIDC claims on first login (design §7).

  Expects claim keys `"email"` (required) and optional `"name"`. The user row is
  created if absent (idempotent on email). When an `:org_id` is given, an org
  membership is ensured with `:role` (default "member"), mapping the IdP domain
  to a default role per `org_sso_connections.default_role`.
  """
  @spec provision_from_claims(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def provision_from_claims(claims, opts \\ []) do
    email = claims["email"] || claims[:email]

    if is_binary(email) and email != "" do
      with {:ok, user} <- upsert_user(email, claims["name"] || claims[:name]),
           :ok <- maybe_put_membership(user, opts) do
        {:ok, user}
      end
    else
      {:error, :missing_email}
    end
  end

  defp upsert_user(email, name) do
    case get_user_by_email(email) do
      {:ok, user} ->
        # Backfill a name we didn't have before; never clobber an existing one.
        if is_nil(user.name) and is_binary(name) do
          update_user(user, %{name: name})
        else
          {:ok, user}
        end

      {:error, :not_found} ->
        create_user(%{email: email, name: name})
    end
  end

  defp maybe_put_membership(user, opts) do
    case Keyword.get(opts, :org_id) do
      nil ->
        :ok

      org_id ->
        role = Keyword.get(opts, :role, "member")

        with {:ok, _org} <- Orgs.get_org(org_id),
             {:ok, _m} <- Memberships.put_org_member(org_id, user.id, role) do
          :ok
        end
    end
  end
end
