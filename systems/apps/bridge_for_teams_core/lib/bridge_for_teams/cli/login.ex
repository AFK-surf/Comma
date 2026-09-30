defmodule BridgeForTeams.CLI.Login do
  @moduledoc """
  Dashboard-to-CLI login handoff for the product `bft` API wrapper.

  The local CLI creates a time-bounded device authorization. A dashboard user
  approves or cancels it for one or more organizations, then the CLI consumes the
  approval for a separate bearer session accepted only by the `/v1/cli/*` API
  surface. Existing CLI sessions can also start a device authorization to add
  more organization grants later.
  """

  import Ecto.Query

  alias BridgeForTeams.{Accounts, Orgs, Repo}
  alias BridgeForTeams.Auth.Sessions

  alias BridgeForTeams.Schema.{
    AuthSession,
    CliDeviceAuthorization,
    CliDeviceAuthorizationOrgGrant,
    CliSessionOrgGrant,
    Organization
  }

  @cli_session_idle_ttl_seconds 7 * 24 * 60 * 60
  @device_authorization_ttl_seconds 7 * 24 * 60 * 60
  @device_authorization_poll_interval_seconds 5
  @cli_session_device "bft-cli"
  @default_client_name "bft CLI"

  @spec start_device_authorization(map()) ::
          {:ok,
           %{
             device_code: String.t(),
             authorization: CliDeviceAuthorization.t(),
             expires_in_seconds: pos_integer(),
             interval_seconds: pos_integer()
           }}
          | {:error, term()}
  def start_device_authorization(attrs \\ %{}) do
    attrs
    |> Map.put(:purpose, "login")
    |> create_device_authorization(3)
  end

  @spec start_session_org_grant_authorization(AuthSession.t(), map()) ::
          {:ok,
           %{
             device_code: String.t(),
             authorization: CliDeviceAuthorization.t(),
             expires_in_seconds: pos_integer(),
             interval_seconds: pos_integer()
           }}
          | {:error, term()}
  def start_session_org_grant_authorization(%AuthSession{} = session, attrs \\ %{}) do
    with :ok <- validate_cli_session(session) do
      attrs
      |> Map.put(:purpose, "session_org_grant")
      |> Map.put(:auth_session_id, session.id)
      |> create_device_authorization(3)
    end
  end

  @spec get_device_authorization(String.t()) ::
          {:ok, CliDeviceAuthorization.t()} | {:error, :not_found}
  def get_device_authorization(user_code) when is_binary(user_code) do
    case Repo.get_by(CliDeviceAuthorization, user_code: normalize_user_code(user_code)) do
      nil -> {:error, :not_found}
      auth -> {:ok, auth |> expire_if_needed() |> preload_authorization_grants()}
    end
  end

  def get_device_authorization(_user_code), do: {:error, :not_found}

  @doc "Normalize the human-entered CLI device user code."
  @spec normalize_user_code(term()) :: String.t()
  def normalize_user_code(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]/, "")
  end

  @spec approve_device_authorization(String.t(), map()) ::
          {:ok, CliDeviceAuthorization.t()} | {:error, term()}
  def approve_device_authorization(user_code, user) do
    org_ids = user.id |> Orgs.list_manageable_orgs_for_user() |> Enum.map(& &1.id)
    approve_device_authorization(user_code, user, org_ids)
  end

  @spec approve_device_authorization(String.t(), map(), [String.t()]) ::
          {:ok, CliDeviceAuthorization.t()} | {:error, term()}
  def approve_device_authorization(user_code, user, org_ids) do
    with {:ok, orgs} <- validate_manageable_orgs(user.id, org_ids) do
      transition_device_authorization(user_code, fn auth, now ->
        case expire_if_needed(auth, now) do
          %CliDeviceAuthorization{status: status} when status != "pending" ->
            {:error, status}

          auth ->
            :ok = insert_authorization_org_grants(auth, orgs, now)

            auth
            |> CliDeviceAuthorization.changeset(%{
              status: "approved",
              approved_by_user_id: user.id,
              approved_at: now
            })
            |> Repo.update()
            |> case do
              {:ok, updated} -> {:ok, preload_authorization_grants(updated)}
              error -> error
            end
        end
      end)
    end
  end

  @spec cancel_device_authorization(String.t(), map()) ::
          {:ok, CliDeviceAuthorization.t()} | {:error, term()}
  def cancel_device_authorization(user_code, user) do
    transition_device_authorization(user_code, fn auth, now ->
      case expire_if_needed(auth, now) do
        %CliDeviceAuthorization{status: status} when status != "pending" ->
          {:error, status}

        auth ->
          auth
          |> CliDeviceAuthorization.changeset(%{
            status: "cancelled",
            cancelled_by_user_id: user.id,
            cancelled_at: now
          })
          |> Repo.update()
          |> case do
            {:ok, updated} -> {:ok, preload_authorization_grants(updated)}
            error -> error
          end
      end
    end)
  end

  @spec poll_device_authorization(String.t()) ::
          {:ok, map()} | {:error, :invalid_device_code | term()}
  def poll_device_authorization(device_code) when is_binary(device_code) and device_code != "" do
    poll_authorization(device_code, nil, &consume_approved_login_authorization/2)
  end

  def poll_device_authorization(_device_code), do: {:error, :invalid_device_code}

  @spec poll_session_org_grant_authorization(String.t(), AuthSession.t()) ::
          {:ok, map()} | {:error, :invalid_device_code | term()}
  def poll_session_org_grant_authorization(device_code, %AuthSession{} = session)
      when is_binary(device_code) and device_code != "" do
    poll_authorization(device_code, session, fn auth, now ->
      consume_approved_session_org_grant_authorization(auth, session, now)
    end)
  end

  def poll_session_org_grant_authorization(_device_code, _session),
    do: {:error, :invalid_device_code}

  @spec validate_cli_session(AuthSession.t()) :: :ok | {:error, :invalid_cli_session}
  def validate_cli_session(%AuthSession{device: @cli_session_device}), do: :ok
  def validate_cli_session(_session), do: {:error, :invalid_cli_session}

  @spec authorize_cli_session_org(AuthSession.t() | nil, Ecto.UUID.t()) ::
          :ok | {:error, :cli_org_grant_required}
  def authorize_cli_session_org(%AuthSession{} = session, org_id) do
    if active_cli_session_org_grant?(session.id, org_id) do
      :ok
    else
      {:error, :cli_org_grant_required}
    end
  end

  def authorize_cli_session_org(nil, _org_id), do: :ok

  @spec refresh_cli_session(AuthSession.t()) :: {:ok, AuthSession.t()} | {:error, term()}
  def refresh_cli_session(%AuthSession{device: @cli_session_device} = session) do
    now = DateTime.utc_now()

    try do
      session
      |> AuthSession.changeset(%{
        last_seen_at: now,
        expires_at: DateTime.add(now, @cli_session_idle_ttl_seconds, :second)
      })
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, {:cli_session_refresh_failed, reason}}
      end
    rescue
      Ecto.StaleEntryError -> {:error, {:cli_session_refresh_failed, :stale_session}}
    end
  end

  def refresh_cli_session(_session), do: {:error, :invalid_cli_session}

  @spec revoke_cli_session(String.t()) :: :ok
  def revoke_cli_session(token) when is_binary(token) do
    with {:ok, session} <- Sessions.fetch(token),
         :ok <- validate_cli_session(session) do
      Sessions.revoke(token)
    else
      _ -> :ok
    end
  end

  def revoke_cli_session(_token), do: :ok

  @spec list_cli_sessions(map()) :: [AuthSession.t()]
  def list_cli_sessions(user) do
    user
    |> Sessions.list_for_user(device: @cli_session_device)
    |> Repo.preload(cli_org_grants: :org)
  end

  @spec revoke_cli_session_for_user(map(), String.t()) :: :ok
  def revoke_cli_session_for_user(user, session_id) do
    Sessions.revoke_for_user(user, session_id, device: @cli_session_device)
  end

  @spec grant_cli_session_orgs(
          AuthSession.t(),
          [Ecto.UUID.t()],
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil
        ) ::
          {:ok, [Organization.t()]} | {:error, term()}
  def grant_cli_session_orgs(
        %AuthSession{} = session,
        org_ids,
        granted_by_user_id,
        authorization_id \\ nil
      ) do
    org_ids = normalize_org_ids(org_ids)

    if org_ids == [] do
      {:error, :missing_org_grants}
    else
      now = DateTime.utc_now()

      rows =
        Enum.map(org_ids, fn org_id ->
          %{
            auth_session_id: session.id,
            org_id: org_id,
            granted_by_user_id: granted_by_user_id,
            grant_device_authorization_id: authorization_id,
            granted_at: now,
            revoked_by_user_id: nil,
            revoked_at: nil,
            created_at: now,
            updated_at: now
          }
        end)

      Repo.insert_all(CliSessionOrgGrant, rows,
        on_conflict:
          {:replace,
           [
             :granted_by_user_id,
             :grant_device_authorization_id,
             :granted_at,
             :revoked_by_user_id,
             :revoked_at,
             :updated_at
           ]},
        conflict_target: [:auth_session_id, :org_id]
      )

      {:ok, list_active_cli_session_orgs(session)}
    end
  end

  @spec revoke_cli_session_org(AuthSession.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, [Organization.t()]} | {:error, :not_found}
  def revoke_cli_session_org(%AuthSession{} = session, org_id, revoked_by_user_id) do
    now = DateTime.utc_now()

    {count, _} =
      from(g in CliSessionOrgGrant,
        where: g.auth_session_id == ^session.id and g.org_id == ^org_id and is_nil(g.revoked_at)
      )
      |> Repo.update_all(
        set: [revoked_by_user_id: revoked_by_user_id, revoked_at: now, updated_at: now]
      )

    if count > 0 do
      {:ok, list_active_cli_session_orgs(session)}
    else
      {:error, :not_found}
    end
  end

  @spec list_active_cli_session_orgs(AuthSession.t() | Ecto.UUID.t()) :: [Organization.t()]
  def list_active_cli_session_orgs(%AuthSession{id: id}), do: list_active_cli_session_orgs(id)

  def list_active_cli_session_orgs(session_id) when is_binary(session_id) do
    from(o in Organization,
      join: g in CliSessionOrgGrant,
      on: g.org_id == o.id,
      where: g.auth_session_id == ^session_id and is_nil(g.revoked_at),
      order_by: [asc: o.name, asc: o.slug],
      distinct: true
    )
    |> Repo.all()
  end

  defp poll_authorization(device_code, session, consume_fun) do
    hash = Sessions.hash_token(device_code)

    Repo.transaction(fn ->
      query =
        from(a in CliDeviceAuthorization,
          where: a.device_code_hash == ^hash,
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          Repo.rollback(:invalid_device_code)

        auth ->
          auth = expire_if_needed(auth)
          now = DateTime.utc_now()

          with :ok <- ensure_poll_flow(auth, session) do
            case auth.status do
              "pending" ->
                {:ok, auth} =
                  auth
                  |> CliDeviceAuthorization.changeset(%{last_polled_at: now})
                  |> Repo.update()

                %{
                  status: "pending",
                  authorization: preload_authorization_grants(auth),
                  interval_seconds: @device_authorization_poll_interval_seconds
                }

              "approved" ->
                consume_fun.(auth, now)

              status when status in ["cancelled", "expired", "consumed"] ->
                %{
                  status: status,
                  authorization: preload_authorization_grants(auth),
                  interval_seconds: @device_authorization_poll_interval_seconds
                }
            end
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> unwrap_transaction()
  end

  defp ensure_poll_flow(%CliDeviceAuthorization{purpose: "login"}, nil), do: :ok

  defp ensure_poll_flow(
         %CliDeviceAuthorization{purpose: "session_org_grant", auth_session_id: auth_session_id},
         %AuthSession{id: auth_session_id}
       ),
       do: :ok

  defp ensure_poll_flow(_auth, _session), do: {:error, :invalid_device_code}

  defp require_active_user(%{status: "active"}), do: :ok
  defp require_active_user(_user), do: {:error, :inactive_user}

  defp create_device_authorization(_attrs, 0), do: {:error, :device_authorization_collision}

  defp create_device_authorization(attrs, attempts_left) do
    device_code = Sessions.generate_token()
    now = DateTime.utc_now()

    attrs = %{
      user_code: generate_user_code(),
      device_code_hash: Sessions.hash_token(device_code),
      status: "pending",
      purpose: Map.get(attrs, "purpose") || Map.get(attrs, :purpose) || "login",
      auth_session_id: Map.get(attrs, "auth_session_id") || Map.get(attrs, :auth_session_id),
      client_name:
        clean_client_name(Map.get(attrs, "client_name") || Map.get(attrs, :client_name)),
      created_by_ip:
        clean_optional(Map.get(attrs, "created_by_ip") || Map.get(attrs, :created_by_ip)),
      expires_at: DateTime.add(now, @device_authorization_ttl_seconds, :second)
    }

    case %CliDeviceAuthorization{} |> CliDeviceAuthorization.changeset(attrs) |> Repo.insert() do
      {:ok, authorization} ->
        {:ok,
         %{
           device_code: device_code,
           authorization: preload_authorization_grants(authorization),
           expires_in_seconds: @device_authorization_ttl_seconds,
           interval_seconds: @device_authorization_poll_interval_seconds
         }}

      {:error, changeset} ->
        if changeset.errors[:user_code] || changeset.errors[:device_code_hash] do
          create_device_authorization(attrs, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp transition_device_authorization(user_code, fun) do
    Repo.transaction(fn ->
      query =
        from(a in CliDeviceAuthorization,
          where: a.user_code == ^normalize_user_code(user_code),
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil -> Repo.rollback(:not_found)
        auth -> fun.(auth, DateTime.utc_now())
      end
    end)
    |> unwrap_transaction()
  end

  defp consume_approved_login_authorization(auth, now) do
    with {:ok, user} <- Accounts.get_user(auth.approved_by_user_id),
         :ok <- require_active_user(user),
         orgs <- authorization_granted_orgs(auth),
         true <- orgs != [] || {:error, :missing_org_grants},
         {:ok, %{token: token, session: session}} <-
           Sessions.create(user,
             ttl_seconds: @cli_session_idle_ttl_seconds,
             device: @cli_session_device,
             client_name: auth.client_name || @default_client_name
           ),
         {:ok, granted_orgs} <-
           grant_cli_session_orgs(session, Enum.map(orgs, & &1.id), user.id, auth.id),
         {:ok, updated} <- mark_authorization_consumed(auth, now) do
      %{
        status: "approved",
        authorization: updated,
        token: token,
        token_type: "bearer",
        session: session,
        expires_in_seconds: @cli_session_idle_ttl_seconds,
        granted_orgs: granted_orgs
      }
    else
      {:error, reason} when reason in [:not_found, :inactive_user, :missing_org_grants] ->
        expire_unconsumable_authorization(auth, now)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp consume_approved_session_org_grant_authorization(auth, session, now) do
    with {:ok, user} <- Accounts.get_user(auth.approved_by_user_id),
         :ok <- require_active_user(user),
         orgs <- authorization_granted_orgs(auth),
         true <- orgs != [] || {:error, :missing_org_grants},
         {:ok, granted_orgs} <-
           grant_cli_session_orgs(session, Enum.map(orgs, & &1.id), user.id, auth.id),
         {:ok, updated} <- mark_authorization_consumed(auth, now) do
      %{
        status: "approved",
        authorization: updated,
        session: session,
        interval_seconds: @device_authorization_poll_interval_seconds,
        granted_orgs: granted_orgs
      }
    else
      {:error, reason} when reason in [:not_found, :inactive_user, :missing_org_grants] ->
        expire_unconsumable_authorization(auth, now)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp mark_authorization_consumed(auth, now) do
    auth
    |> CliDeviceAuthorization.changeset(%{
      status: "consumed",
      consumed_at: now,
      last_polled_at: now
    })
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, preload_authorization_grants(updated)}
      error -> error
    end
  end

  defp expire_unconsumable_authorization(auth, now) do
    {:ok, updated} =
      auth
      |> CliDeviceAuthorization.changeset(%{status: "expired", last_polled_at: now})
      |> Repo.update()

    %{
      status: "expired",
      authorization: preload_authorization_grants(updated),
      interval_seconds: @device_authorization_poll_interval_seconds
    }
  end

  defp expire_if_needed(%CliDeviceAuthorization{status: status} = auth)
       when status in ["pending", "approved"] do
    expire_if_needed(auth, DateTime.utc_now())
  end

  defp expire_if_needed(auth), do: auth

  defp expire_if_needed(%CliDeviceAuthorization{status: status} = auth, now)
       when status in ["pending", "approved"] do
    if DateTime.compare(auth.expires_at, now) == :gt do
      auth
    else
      {:ok, expired} =
        auth
        |> CliDeviceAuthorization.changeset(%{status: "expired"})
        |> Repo.update()

      expired
    end
  end

  defp expire_if_needed(auth, _now), do: auth

  defp validate_manageable_orgs(user_id, org_ids) do
    org_ids = normalize_org_ids(org_ids)

    cond do
      org_ids == [] ->
        {:error, :missing_org_grants}

      true ->
        manageable = Orgs.list_manageable_orgs_for_user(user_id)
        manageable_by_id = Map.new(manageable, &{&1.id, &1})

        if Enum.all?(org_ids, &Map.has_key?(manageable_by_id, &1)) do
          {:ok, Enum.map(org_ids, &Map.fetch!(manageable_by_id, &1))}
        else
          {:error, :forbidden}
        end
    end
  end

  defp insert_authorization_org_grants(auth, orgs, now) do
    rows =
      Enum.map(orgs, fn org ->
        %{
          cli_device_authorization_id: auth.id,
          org_id: org.id,
          created_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(CliDeviceAuthorizationOrgGrant, rows,
      on_conflict: :nothing,
      conflict_target: [:cli_device_authorization_id, :org_id]
    )

    :ok
  end

  defp authorization_granted_orgs(auth) do
    auth
    |> preload_authorization_grants()
    |> Map.get(:org_grants)
    |> Enum.map(& &1.org)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.slug || ""})
  end

  defp active_cli_session_org_grant?(session_id, org_id) do
    from(g in CliSessionOrgGrant,
      where: g.auth_session_id == ^session_id and g.org_id == ^org_id and is_nil(g.revoked_at),
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp preload_authorization_grants(%CliDeviceAuthorization{} = auth) do
    Repo.preload(auth, [org_grants: :org], force: true)
  end

  defp normalize_org_ids(org_ids) when is_list(org_ids) do
    org_ids
    |> Enum.map(&clean_optional/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_org_ids(_org_ids), do: []

  defp unwrap_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_transaction({:ok, value}), do: {:ok, value}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp generate_user_code do
    :crypto.strong_rand_bytes(5)
    |> Base.encode32(case: :upper, padding: false)
    |> binary_part(0, 8)
  end

  defp clean_client_name(nil), do: @default_client_name

  defp clean_client_name(value) do
    case value |> to_string() |> String.trim() do
      "" -> @default_client_name
      cleaned -> String.slice(cleaned, 0, 80)
    end
  end

  defp clean_optional(nil), do: nil

  defp clean_optional(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, 255)
    end
  end
end
