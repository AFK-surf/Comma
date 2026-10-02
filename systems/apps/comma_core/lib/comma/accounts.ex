defmodule Comma.Accounts do
  @moduledoc "Comma-owned PostgreSQL users and revocable sessions."

  import Ecto.Query

  alias Comma.Accounts.{Email, Repository, Sessions, User, UserPageCursor}
  alias Comma.Repo

  @max_user_page 100

  def create_user(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    changeset =
      User.changeset(%User{}, %{
        id: attrs["id"] || User.new_id(),
        email: attrs["email"],
        name: attrs["name"],
        status: attrs["status"] || "active"
      })

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, public_user(user)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def create_user(_attrs), do: {:error, :invalid_user}

  def list_users(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @max_user_page) |> clamp_user_limit()

    with {:ok, email} <- normalize_user_email_filter(Keyword.get(opts, :email)),
         filters = %{"email" => email},
         {:ok, cursor} <- UserPageCursor.decode(Keyword.get(opts, :cursor), filters, opts) do
      users =
        from(user in User,
          order_by: [desc: user.created_at, desc: user.id],
          limit: ^(limit + 1)
        )
        |> filter_users_by_email(email)
        |> users_after_cursor(cursor)
        |> Repo.all()

      page = Enum.take(users, limit)
      has_more = length(users) > limit

      with {:ok, next_cursor} <- next_user_cursor(page, has_more, filters, opts) do
        {:ok,
         %{
           "data" => Enum.map(page, &public_user/1),
           "has_more" => has_more,
           "next_cursor" => next_cursor
         }}
      end
    end
  end

  def get_user(id) do
    case Repository.get_user(id) do
      {:ok, user} -> {:ok, public_user(user)}
      {:error, _reason} = error -> error
    end
  end

  def get_user_by_email(email) do
    case Repository.get_user_by_email(email) do
      {:ok, user} -> {:ok, public_user(user)}
      {:error, :invalid_email} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_or_create_user_by_email(email) do
    case Repository.ensure_user_by_email(email) do
      {:ok, user} -> {:ok, public_user(user)}
      {:error, :invalid_email} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def update_user(id, attrs) when is_binary(id) and is_map(attrs) do
    attrs = stringify(attrs)

    if Map.has_key?(attrs, "email") do
      {:error, :email_change_not_supported}
    else
      update_user_fields(id, Map.take(attrs, ["name", "status", "locale"]))
    end
  end

  def update_user(_id, _attrs), do: {:error, :not_found}

  defp update_user_fields(id, attrs) do
    Repo.transaction(fn ->
      user = Repo.one(from(row in User, where: row.id == ^id, lock: "FOR UPDATE"))

      if is_nil(user) do
        Repo.rollback(:not_found)
      end

      disable? = attrs["status"] == "disabled" and user.status != "disabled"
      attrs = if disable?, do: Map.put(attrs, "auth_epoch", user.auth_epoch + 1), else: attrs

      case Repo.update(User.changeset(user, attrs)) do
        {:ok, updated} ->
          if disable? do
            {:ok, _count} =
              Sessions.revoke_all(updated.id,
                repo: Repo,
                reason: "user_disabled"
              )
          end

          public_user(updated)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  def create_session(user_id, opts \\ []) do
    Sessions.create(user_id, opts)
  end

  def validate_session(token) do
    case Sessions.validate(token) do
      {:ok, user, session} -> {:ok, public_user(user), session}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_session(token) do
    case Sessions.resolve(token) do
      {:ok, user, session} -> {:ok, public_user(user), session}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_session_id(session_id) do
    case Sessions.resolve_id(session_id) do
      {:ok, user, session} -> {:ok, public_user(user), session}
      {:error, reason} -> {:error, reason}
    end
  end

  def touch_session(session), do: Sessions.touch_last_seen(session)
  def touch_session_active(session), do: Sessions.touch_active(session)
  def present?(user_id), do: Sessions.present?(user_id)

  def list_sessions(user_id, opts \\ []), do: Sessions.list(user_id, opts)
  def revoke_session(user_id, session_id), do: Sessions.revoke(user_id, session_id)

  def revoke_session(user_id, session_id, reason),
    do: Sessions.revoke(user_id, session_id, reason)

  def revoke_all_sessions(user_id, opts \\ []), do: Sessions.revoke_all(user_id, opts)
  def revoke_session_token(token), do: Sessions.revoke_token(token)

  @doc """
  The account's app language for server-written text. An account that has not
  reported one yet reads as English.
  """
  def locale(user_id) when is_binary(user_id) do
    case Repo.one(from(row in User, where: row.id == ^user_id, select: row.locale)) do
      locale when is_binary(locale) -> locale
      _ -> "en"
    end
  end

  @doc """
  Adopt a client-reported app language only while the account has none.
  Clients released before the account setting report it on Routine reads;
  an account that already has a language keeps it. Returns `:adopted` when
  this call set it.
  """
  def adopt_locale(user_id, locale) when is_binary(user_id) and is_binary(locale) do
    if locale in User.locales() do
      case Repo.update_all(
             from(row in User, where: row.id == ^user_id and is_nil(row.locale)),
             set: [locale: locale, updated_at: DateTime.utc_now()]
           ) do
        {1, _} -> :adopted
        {0, _} -> :unchanged
      end
    else
      :unchanged
    end
  end

  def adopt_locale(_user_id, _locale), do: :unchanged

  def consume_budget(session, operation_id \\ nil) do
    Sessions.consume_budget(session, operation_id)
  end

  def public_user(%User{} = user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "name" => user.name,
      "avatar_id" => user.avatar_id,
      "status" => user.status,
      "locale" => user.locale,
      "created_at" => unix(user.created_at),
      "updated_at" => unix(user.updated_at)
    }
    |> put_guest_kind(user)
  end

  # Released clients parse the registered user shape strictly. Only a guest,
  # which those clients cannot create, carries `kind`.
  defp put_guest_kind(public, %User{kind: "guest"}), do: Map.put(public, "kind", "guest")
  defp put_guest_kind(public, _user), do: public

  defp clamp_user_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_user_page)
  defp clamp_user_limit(_limit), do: @max_user_page

  defp normalize_user_email_filter(nil), do: {:ok, nil}

  defp normalize_user_email_filter(email) do
    case Email.normalize(email) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, :invalid_email} -> {:error, :invalid_filter}
    end
  end

  defp filter_users_by_email(query, nil), do: query
  defp filter_users_by_email(query, email), do: from(user in query, where: user.email == ^email)

  defp users_after_cursor(query, nil), do: query

  defp users_after_cursor(query, {created_at, id}) do
    from(user in query,
      where:
        user.created_at < ^created_at or
          (user.created_at == ^created_at and user.id < ^id)
    )
  end

  defp next_user_cursor(_page, false, _filters, _opts), do: {:ok, nil}

  defp next_user_cursor(page, true, filters, opts),
    do: page |> List.last() |> UserPageCursor.encode(filters, opts)

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  defp unix(nil), do: nil
  defp unix(%DateTime{} = value), do: DateTime.to_unix(value)
end
