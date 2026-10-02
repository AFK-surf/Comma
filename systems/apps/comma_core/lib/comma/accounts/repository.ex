defmodule Comma.Accounts.Repository do
  @moduledoc "Bounded PostgreSQL persistence operations for Comma users and login identities."

  import Ecto.Query

  alias Comma.Accounts.{Email, Identity, User}
  alias Comma.Repo

  @spec get_user(String.t(), keyword()) :: {:ok, User.t()} | {:error, :not_found}
  def get_user(id, opts \\ [])

  def get_user(id, opts) when is_binary(id) do
    case repo(opts).get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def get_user(_id, _opts), do: {:error, :not_found}

  @spec get_user_by_email(String.t(), keyword()) ::
          {:ok, User.t()} | {:error, :not_found | :invalid_email}
  def get_user_by_email(email, opts \\ []) do
    with {:ok, normalized} <- Email.normalize(email) do
      case repo(opts).get_by(User, email: normalized) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end
  end

  @spec ensure_user_by_email(String.t(), map(), keyword()) ::
          {:ok, User.t()} | {:error, :not_found | :invalid_email | Ecto.Changeset.t()}
  def ensure_user_by_email(email, attrs \\ %{}, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- Email.normalize(email),
         :ok <- Comma.GuestMode.reject_guest_email(normalized),
         {:ok, values} <- user_values(normalized, attrs) do
      target_repo = repo(opts)
      now = DateTime.utc_now()

      target_repo.insert_all(
        User,
        [Map.merge(values, %{created_at: now, updated_at: now})],
        on_conflict: :nothing,
        conflict_target: [:email]
      )

      get_user_by_email(normalized, repo: target_repo)
    end
  end

  @spec get_identity(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Identity.t()} | {:error, :not_found | :invalid_identity}
  def get_identity(provider, issuer, subject, opts \\ []) do
    with {:ok, key} <- identity_key(provider, issuer, subject) do
      query =
        from(identity in Identity,
          where:
            identity.provider == ^key.provider and identity.issuer == ^key.issuer and
              identity.subject == ^key.subject
        )

      case repo(opts).one(query) do
        nil -> {:error, :not_found}
        identity -> {:ok, identity}
      end
    end
  end

  @spec ensure_identity(String.t(), map(), keyword()) ::
          {:ok, Identity.t()}
          | {:error,
             :not_found
             | :invalid_identity
             | :identity_conflict
             | :provider_already_linked
             | Ecto.Changeset.t()}
  def ensure_identity(user_id, attrs, opts \\ [])

  def ensure_identity(user_id, attrs, opts) when is_binary(user_id) and is_map(attrs) do
    target_repo = repo(opts)

    with {:ok, _user} <- get_user(user_id, repo: target_repo),
         {:ok, identity_attrs} <- identity_values(user_id, attrs) do
      changeset = Identity.changeset(%Identity{}, identity_attrs)

      case target_repo.insert(changeset) do
        {:ok, identity} ->
          {:ok, identity}

        {:error, changeset} ->
          resolve_identity_conflict(target_repo, user_id, identity_attrs, changeset)
      end
    end
  end

  def ensure_identity(_user_id, _attrs, _opts), do: {:error, :invalid_identity}

  @spec update_identity_metadata(Identity.t(), map(), keyword()) ::
          {:ok, Identity.t()} | {:error, Ecto.Changeset.t()}
  def update_identity_metadata(%Identity{} = identity, attrs, opts \\ []) when is_map(attrs) do
    allowed = [
      :email_snapshot,
      :email_verified,
      :hosted_domain,
      :last_authenticated_at
    ]

    attrs =
      Enum.reduce(allowed, %{}, fn key, acc ->
        case fetch_value(attrs, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    identity
    |> Identity.changeset(attrs)
    |> repo(opts).update()
  end

  defp user_values(email, attrs) do
    values = %{
      id: value(attrs, :id) || User.new_id(),
      email: email,
      name: value(attrs, :name),
      status: value(attrs, :status) || "active"
    }

    changeset = User.changeset(%User{signup_credit_eligible: true}, values)

    if changeset.valid? do
      user = Ecto.Changeset.apply_changes(changeset)
      {:ok, Map.take(user, [:id, :email, :name, :status, :signup_credit_eligible])}
    else
      {:error, changeset}
    end
  end

  defp identity_values(user_id, attrs) do
    with {:ok, key} <-
           identity_key(value(attrs, :provider), value(attrs, :issuer), value(attrs, :subject)) do
      values = %{
        user_id: user_id,
        provider: key.provider,
        issuer: key.issuer,
        subject: key.subject,
        email_snapshot: value(attrs, :email_snapshot),
        email_verified: value(attrs, :email_verified),
        hosted_domain: value(attrs, :hosted_domain),
        last_authenticated_at: value(attrs, :last_authenticated_at) || DateTime.utc_now()
      }

      changeset = Identity.changeset(%Identity{}, values)

      if changeset.valid? do
        identity = Ecto.Changeset.apply_changes(changeset)

        {:ok,
         Map.take(identity, [
           :user_id,
           :provider,
           :issuer,
           :subject,
           :email_snapshot,
           :email_verified,
           :hosted_domain,
           :last_authenticated_at
         ])}
      else
        {:error, changeset}
      end
    end
  end

  defp identity_key(provider, issuer, subject)
       when is_binary(provider) and is_binary(issuer) and is_binary(subject) do
    key = %{
      provider: provider |> String.trim() |> String.downcase(),
      issuer: String.trim(issuer),
      subject: String.trim(subject)
    }

    if Enum.all?(Map.values(key), &(&1 != "")), do: {:ok, key}, else: {:error, :invalid_identity}
  end

  defp identity_key(_provider, _issuer, _subject), do: {:error, :invalid_identity}

  defp resolve_identity_conflict(target_repo, user_id, attrs, changeset) do
    case get_identity(attrs.provider, attrs.issuer, attrs.subject, repo: target_repo) do
      {:ok, %Identity{user_id: ^user_id} = identity} ->
        {:ok, identity}

      {:ok, %Identity{}} ->
        {:error, :identity_conflict}

      {:error, :not_found} ->
        existing = target_repo.get_by(Identity, user_id: user_id, provider: attrs.provider)

        if existing, do: {:error, :provider_already_linked}, else: {:error, changeset}

      {:error, :invalid_identity} ->
        {:error, changeset}
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp fetch_value(attrs, key), do: Map.fetch(attrs, key) |> fallback_fetch(attrs, key)
  defp fallback_fetch({:ok, _value} = found, _attrs, _key), do: found
  defp fallback_fetch(:error, attrs, key), do: Map.fetch(attrs, Atom.to_string(key))
  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
