defmodule BridgeForTeams.AccountRecovery do
  @moduledoc """
  System-admin account recovery for SSO lockout scenarios.

  Operators generate a one-time link from the Elixir shell, similar to org
  creation invite codes:

      BridgeForTeams.AccountRecovery.create_recovery_link(
        "owner@example.com",
        base_url: "https://teams.example.com",
        note: "SSO config rollback"
      )

  The raw token is returned once. Only its hash is stored, and redemption marks
  the link used before the web layer creates a normal dashboard session.
  """
  import Ecto.Query
  require Logger

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.{Observability, Orgs, Repo}
  alias BridgeForTeams.Schema.{AccountRecoveryLink, User}

  @default_ttl_seconds 60 * 60

  @doc """
  Create a one-time recovery link for an existing active account.

  `user_ref` may be a `%User{}`, a user id, or an email address. Options:

    * `:base_url` - optional dashboard base URL. When omitted, `:url` is the
      relative recovery path.
    * `:ttl_seconds` - seconds until expiry; defaults to 1 hour.
    * `:expires_at` - explicit UTC `DateTime`, overriding `:ttl_seconds`.
    * `:note` - optional operator note.
    * `:token` - optional caller-supplied token, mainly for deterministic tests.
    * `:audit` - set to `false` to suppress org-scoped audit rows.
    * `:actor_user_id`, `:actor_label`, `:request_id` - optional audit context.
  """
  @spec create_recovery_link(User.t() | Ecto.UUID.t() | String.t(), map() | keyword()) ::
          {:ok,
           %{
             token: String.t(),
             path: String.t(),
             url: String.t(),
             recovery_link: AccountRecoveryLink.t()
           }}
          | {:error, term()}
  def create_recovery_link(user_ref, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    with {:ok, %User{status: "active"} = user} <- fetch_user(user_ref) do
      token = attrs["token"] || generate_token()
      path = recovery_path(token)

      insert_attrs = %{
        "user_id" => user.id,
        "token_hash" => token_hash(token),
        "expires_at" => expires_at(attrs),
        "note" => attrs["note"]
      }

      case %AccountRecoveryLink{}
           |> AccountRecoveryLink.changeset(insert_attrs)
           |> Repo.insert() do
        {:ok, recovery_link} ->
          maybe_record_recovery_audits(
            "account_recovery.link_created",
            user,
            recovery_link,
            attrs
          )

          {:ok,
           %{
             token: token,
             path: path,
             url: recovery_url(path, attrs["base_url"]),
             recovery_link: recovery_link
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:ok, %User{}} -> {:error, :inactive_user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Redeem a one-time recovery token.

  Returns the recovered active user and marks the link used inside one database
  transaction. The caller should create a normal auth session after this returns.
  """
  @spec redeem_recovery_token(String.t()) ::
          {:ok, %{user: User.t(), recovery_link: AccountRecoveryLink.t()}} | {:error, term()}
  def redeem_recovery_token(token) when is_binary(token) do
    redeem_token(token, fn user, used_link ->
      {:ok, %{user: user, recovery_link: used_link}}
    end)
  end

  def redeem_recovery_token(_token), do: {:error, :invalid_recovery_token}

  @doc """
  Redeem a recovery token and create a normal dashboard auth session atomically.

  Options are passed through to `BridgeForTeams.Auth.Sessions.create/2`.
  """
  @spec redeem_recovery_token_for_session(String.t(), keyword()) ::
          {:ok,
           %{
             user: User.t(),
             token: String.t(),
             session: BridgeForTeams.Schema.AuthSession.t(),
             recovery_link: AccountRecoveryLink.t()
           }}
          | {:error, term()}
  def redeem_recovery_token_for_session(token, opts \\ [])

  def redeem_recovery_token_for_session(token, opts) when is_binary(token) do
    session_opts = Keyword.take(opts, [:device, :ttl_seconds])

    redeem_token(token, fn user, used_link ->
      with {:ok, %{token: session_token, session: session}} <- Sessions.create(user, session_opts) do
        {:ok, %{user: user, token: session_token, session: session, recovery_link: used_link}}
      end
    end)
  end

  def redeem_recovery_token_for_session(_token, _opts), do: {:error, :invalid_recovery_token}

  defp redeem_token(token, after_mark) do
    Repo.transaction(fn ->
      with {:ok, link} <- fetch_redeemable_link(token),
           {:ok, user} <- fetch_active_user(link),
           {:ok, used_link} <- mark_used(link),
           {:ok, result} <- after_mark.(user, used_link) do
        maybe_record_recovery_audits("account_recovery.redeemed", user, used_link, %{
          "actor_user_id" => user.id,
          "actor_label" => audit_actor_label(user),
          "request_id" => Ecto.UUID.generate()
        })

        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp fetch_user(%User{} = user), do: {:ok, user}

  defp fetch_user(ref) when is_binary(ref) do
    if String.contains?(ref, "@") do
      fetch_user_by_email(ref)
    else
      fetch_user_by_id(ref)
    end
  end

  defp fetch_user(_ref), do: {:error, :user_not_found}

  defp fetch_user_by_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp fetch_user_by_id(id) do
    case Repo.get(User, id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp fetch_redeemable_link(token) do
    hash = token_hash(token)

    query =
      from l in AccountRecoveryLink,
        where: l.token_hash == ^hash,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :invalid_recovery_token}
      %AccountRecoveryLink{used_at: %DateTime{}} -> {:error, :recovery_token_already_used}
      %AccountRecoveryLink{} = link -> check_expiry(link)
    end
  end

  defp fetch_active_user(%AccountRecoveryLink{user_id: user_id}) do
    case Repo.get(User, user_id) do
      %User{status: "active"} = user -> {:ok, user}
      %User{} -> {:error, :inactive_user}
      nil -> {:error, :user_not_found}
    end
  end

  defp check_expiry(%AccountRecoveryLink{expires_at: expires_at} = link) do
    case DateTime.compare(expires_at, now()) do
      :gt -> {:ok, link}
      _ -> {:error, :recovery_token_expired}
    end
  end

  defp mark_used(%AccountRecoveryLink{} = link) do
    link
    |> AccountRecoveryLink.changeset(%{"used_at" => now()})
    |> Repo.update()
  end

  defp expires_at(%{"expires_at" => %DateTime{} = expires_at}), do: expires_at

  defp expires_at(attrs) do
    ttl = Map.get(attrs, "ttl_seconds", @default_ttl_seconds)
    DateTime.add(now(), ttl, :second)
  end

  defp recovery_path(token), do: "/auth/recovery?" <> URI.encode_query(%{"token" => token})

  defp recovery_url(path, base_url) when is_binary(base_url) and base_url != "" do
    String.trim_trailing(base_url, "/") <> path
  end

  defp recovery_url(path, _base_url), do: path

  defp generate_token do
    "bft_recovery_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp token_hash(token), do: token |> normalize_token() |> Sessions.hash_token()

  defp normalize_token(token) when is_binary(token), do: String.trim(token)

  defp maybe_record_recovery_audits(action, %User{} = user, %AccountRecoveryLink{} = link, attrs) do
    if audit_enabled?(attrs) do
      user.id
      |> Orgs.list_orgs_for_user()
      |> Enum.each(fn org ->
        case Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: audit_actor_user_id(attrs),
               actor_label: audit_actor_label(attrs),
               action: action,
               resource_type: "account_recovery_link",
               resource_id: link.id,
               resource_label: recovery_link_label(link),
               result: "ok",
               request_id: audit_request_id(attrs),
               metadata: recovery_audit_metadata(user, link, action)
             }) do
          {:ok, _audit} -> :ok
          {:error, reason} -> log_recovery_audit_failure(action, link.id, reason)
        end
      end)
    end

    :ok
  end

  defp audit_enabled?(%{"audit" => false}), do: false
  defp audit_enabled?(%{"audit" => "false"}), do: false
  defp audit_enabled?(_attrs), do: true

  defp audit_actor_user_id(%{"actor_user_id" => actor_user_id}) when is_binary(actor_user_id),
    do: actor_user_id

  defp audit_actor_user_id(_attrs), do: nil

  defp audit_actor_label(%{"actor_label" => actor_label}) when is_binary(actor_label),
    do: blank_to_nil(actor_label)

  defp audit_actor_label(%User{} = user) do
    cond do
      is_binary(user.email) and String.trim(user.email) != "" -> String.trim(user.email)
      is_binary(user.name) and String.trim(user.name) != "" -> String.trim(user.name)
      true -> user.id
    end
  end

  defp audit_actor_label(_attrs), do: nil

  defp audit_request_id(%{"request_id" => request_id})
       when is_binary(request_id) and request_id != "",
       do: request_id

  defp audit_request_id(_attrs), do: Ecto.UUID.generate()

  defp recovery_audit_metadata(user, link, action) do
    %{
      "target_user_id" => user.id,
      "recovery_link_id" => link.id,
      "expires_at" => DateTime.to_iso8601(link.expires_at),
      "used_at" => iso8601_or_nil(link.used_at),
      "source" => "account_recovery",
      "action" => action
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp recovery_link_label(%AccountRecoveryLink{id: id}), do: "Recovery link #{short_id(id)}"

  defp short_id(id) when is_binary(id) and byte_size(id) > 8, do: String.slice(id, 0, 8)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: "unknown"

  defp iso8601_or_nil(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601_or_nil(_value), do: nil

  defp log_recovery_audit_failure(action, link_id, reason) do
    Logger.warning(
      "account_recovery_audit_failed action=#{action} recovery_link_id=#{link_id} reason=#{inspect(reason)}"
    )
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_attrs(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
