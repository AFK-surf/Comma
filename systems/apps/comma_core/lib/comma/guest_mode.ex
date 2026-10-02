defmodule Comma.GuestMode do
  @moduledoc """
  Guest mode: people try Comma without signing in.

  A guest is a throwaway `kind = "guest"` User with an undeliverable
  placeholder email. Its Workspace has only a Router agent and lives in the
  shared, router-only guest Salix Tenant. Guests never become registered
  Users. At sign-up the guest hands off a one-time claim, and the new account
  redeems it; `Comma.Workers.GuestImport` then posts the guest Router chat into
  the account's Router chat.

  The Comma Admin dashboard owns the policy singleton (`comma_guest_policy`):
  whether guest mode is enabled, the guest Tenant, the daily creation limit,
  the guest Tenant's per-node dependency concurrency and the guest session
  lifetime.
  """

  import Ecto.Query

  alias Comma.Accounts.{SessionClientMetadata, SessionIssuer, User}
  alias Comma.Data.ExternalOperation
  alias Comma.{Operations, Repo}
  alias Ecto.Multi

  @placeholder_domain "guest.comma.invalid"
  @claim_prefix "cgc_"
  @claim_ttl_seconds 60 * 60
  @operation_type "guest_import"
  @owner_type "comma_user"
  @policy_columns ~w(enabled salix_tenant_id daily_creation_limit tenant_concurrency session_ttl_seconds pow_difficulty revision)

  def placeholder_domain, do: @placeholder_domain
  def operation_type, do: @operation_type

  @doc "True for the undeliverable placeholder address of a guest User."
  def guest_email?(email) when is_binary(email),
    do: email |> String.downcase() |> String.ends_with?("@" <> @placeholder_domain)

  def guest_email?(_email), do: false

  @doc "Registered accounts can never use the guest placeholder domain."
  def reject_guest_email(email),
    do: if(guest_email?(email), do: {:error, :invalid_email}, else: :ok)

  def guest?(%User{kind: "guest"}), do: true
  def guest?(%{"kind" => "guest"}), do: true
  def guest?(_user), do: false

  ## Policy

  def get_policy do
    case Ecto.Adapters.SQL.query(Repo, policy_sql(""), [], timeout: 5_000) do
      {:ok, %{rows: [row]}} -> {:ok, with_created_today(policy_from_row(row))}
      {:ok, _result} -> {:error, :guest_policy_missing}
      {:error, _reason} -> {:error, :guest_policy_unavailable}
    end
  end

  @doc "Public sign-in screen status with a fresh proof-of-work challenge."
  def public_status do
    with {:ok, policy} <- get_policy(),
         true <- available?(policy),
         {:ok, pow} <- Comma.GuestPow.issue(policy["pow_difficulty"]) do
      %{"enabled" => true, "pow" => pow}
    else
      _unavailable -> %{"enabled" => false}
    end
  end

  @doc "Admin update of the policy fields. Guest Tenant creation is separate."
  def update_policy(attrs) when is_map(attrs) do
    with {:ok, changes} <- normalize_policy_changes(attrs),
         {:ok, revision} <- expected_revision(attrs) do
      Repo.transaction(fn ->
        current = lock_policy!()
        if current["revision"] != revision, do: Repo.rollback(:guest_policy_conflict)

        next = Map.merge(current, changes)

        if next["enabled"] and is_nil(next["salix_tenant_id"]),
          do: Repo.rollback(:guest_tenant_required)

        # Every Salix node reads the concurrency override from the Tenant profile.
        if is_binary(next["salix_tenant_id"]) and
             next["tenant_concurrency"] != current["tenant_concurrency"] do
          case salix().ensure_guest_tenant(next["salix_tenant_id"], next["tenant_concurrency"]) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        store_policy!(next, attrs["admin_command_id"], current)
      end)
    end
  end

  def update_policy(_attrs), do: {:error, :invalid_guest_policy}

  @doc """
  Create a new dedicated router-only Salix Tenant for guests. New guests use
  it; existing guest Workspaces stay in their Tenant.
  """
  def create_tenant(attrs) when is_map(attrs) do
    with {:ok, revision} <- expected_revision(attrs) do
      Repo.transaction(fn ->
        current = lock_policy!()
        if current["revision"] != revision, do: Repo.rollback(:guest_policy_conflict)

        tenant_id = SalixStore.Ids.new_tenant_id()

        case salix().ensure_guest_tenant(tenant_id, current["tenant_concurrency"]) do
          :ok -> store_policy!(%{current | "salix_tenant_id" => tenant_id}, attrs["admin_command_id"], current)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def create_tenant(_attrs), do: {:error, :invalid_guest_policy}

  ## Guest accounts

  @doc """
  Create a guest User and issue its session. The caller supplies client
  metadata and a solved `Comma.GuestPow` challenge in `pow`.
  """
  def create_guest(attrs) when is_map(attrs) do
    with {:ok, policy} <- get_policy(),
         true <- available?(policy) || {:error, :guest_mode_disabled},
         {:ok, pow_id} <- Comma.GuestPow.verify(attrs["pow"], policy["pow_difficulty"]),
         metadata = SessionClientMetadata.options(attrs) do
      Repo.transaction(fn ->
        policy = lock_policy!()

        cond do
          not available?(policy) ->
            Repo.rollback(:guest_mode_disabled)

          created_today() >= policy["daily_creation_limit"] ->
            Repo.rollback(:guest_daily_limit)

          true ->
            user = insert_guest!(pow_id)

            case SessionIssuer.issue(
                   user,
                   Keyword.merge(metadata,
                     auth_method: "guest",
                     ttl_seconds: policy["session_ttl_seconds"]
                   )
                 ) do
              {:ok, issued} -> issued
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Start sign-up from a guest session: revoke every guest session and return a
  one-time claim that a registered account can redeem within an hour.
  """
  def handoff(%{"id" => user_id, "kind" => "guest"}) do
    claim = @claim_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @claim_ttl_seconds, :second)

    Repo.transaction(fn ->
      guest = lock_user!(user_id)

      cond do
        guest.kind != "guest" or guest.status != "active" ->
          Repo.rollback(:guest_only)

        not is_nil(guest.guest_imported_into_user_id) ->
          Repo.rollback(:guest_already_imported)

        true ->
          {1, _rows} =
            from(row in User, where: row.id == ^user_id)
            |> Repo.update_all(
              set: [
                guest_claim_hash: claim_hash(claim),
                guest_claim_expires_at: expires_at,
                auth_epoch: guest.auth_epoch + 1,
                updated_at: DateTime.utc_now()
              ]
            )

          {:ok, _count} =
            Comma.Accounts.Sessions.revoke_all(user_id, repo: Repo, reason: "guest_handoff")

          %{"claim" => claim, "expires_at" => DateTime.to_unix(expires_at)}
      end
    end)
  end

  def handoff(_user), do: {:error, :guest_only}

  @doc """
  Redeem a guest claim for a registered User. Repeating the redemption from
  the same account returns the same import.
  """
  def redeem(%{"kind" => "guest"}, _claim), do: {:error, :guest_forbidden}

  def redeem(%{"id" => user_id}, claim) when is_binary(claim) do
    now = DateTime.utc_now()

    with true <- String.starts_with?(claim, @claim_prefix) || {:error, :guest_claim_invalid} do
      Multi.new()
      |> Multi.run(:guest, fn repo, _changes ->
        guest =
          repo.one(
            from(row in User,
              where: row.guest_claim_hash == ^claim_hash(claim) and row.kind == "guest",
              lock: "FOR UPDATE"
            )
          )

        cond do
          is_nil(guest) or DateTime.compare(guest.guest_claim_expires_at, now) != :gt ->
            {:error, :guest_claim_invalid}

          guest.guest_imported_into_user_id == user_id ->
            {:error, {:already_redeemed, guest}}

          not is_nil(guest.guest_imported_into_user_id) ->
            {:error, :guest_claim_invalid}

          true ->
            {1, _rows} =
              from(row in User, where: row.id == ^guest.id)
              |> repo.update_all(set: [guest_imported_into_user_id: user_id, updated_at: now])

            {:ok, guest}
        end
      end)
      |> Multi.merge(fn %{guest: guest} ->
        operation_id = import_operation_id()

        Operations.create_with_job(
          Multi.new(),
          %{
            operation_id: operation_id,
            operation_type: @operation_type,
            owner_type: @owner_type,
            owner_id: guest.id,
            generation: 1,
            status: "pending",
            attempt: 0,
            external_idempotency_key: "guest_import:" <> guest.id,
            metadata: %{"target_user_id" => user_id}
          },
          Comma.Workers.GuestImport.new(%{"operation_id" => operation_id})
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{comma_operation_row: operation}} ->
          {:ok, public_import(operation)}

        {:error, :guest, {:already_redeemed, guest}, _changes} ->
          import_for_guest(guest.id, user_id)

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def redeem(_user, _claim), do: {:error, :guest_claim_invalid}

  def import_status(%{"id" => user_id}, import_id) when is_binary(import_id) do
    case Repo.get(ExternalOperation, import_id) do
      %ExternalOperation{operation_type: @operation_type, metadata: %{"target_user_id" => ^user_id}} =
          operation ->
        {:ok, public_import(operation)}

      _other ->
        {:error, :not_found}
    end
  end

  def import_status(_user, _import_id), do: {:error, :not_found}

  ## Internals

  defp available?(policy),
    do: policy["enabled"] == true and is_binary(policy["salix_tenant_id"])

  defp import_for_guest(guest_id, user_id) do
    case Repo.one(
           from(operation in ExternalOperation,
             where:
               operation.operation_type == @operation_type and
                 operation.owner_type == @owner_type and operation.owner_id == ^guest_id
           )
         ) do
      %ExternalOperation{metadata: %{"target_user_id" => ^user_id}} = operation ->
        {:ok, public_import(operation)}

      _other ->
        {:error, :guest_claim_invalid}
    end
  end

  defp public_import(operation) do
    status =
      case operation.status do
        "succeeded" -> "succeeded"
        status when status in ["terminal_failed", "superseded"] -> "failed"
        _active -> "pending"
      end

    %{"import_id" => operation.operation_id, "status" => status}
    |> then(fn public ->
      if status == "failed" and is_binary(operation.last_error_class),
        do: Map.put(public, "error", operation.last_error_class),
        else: public
    end)
  end

  defp insert_guest!(pow_id) do
    email =
      "g-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> "@" <> @placeholder_domain

    %User{}
    |> User.changeset(%{id: User.new_id(), email: email, name: nil, status: "active"})
    |> Ecto.Changeset.put_change(:kind, "guest")
    |> Ecto.Changeset.put_change(:guest_pow_id, pow_id)
    |> Ecto.Changeset.unique_constraint(:guest_pow_id, name: :comma_users_guest_pow_id_index)
    |> Repo.insert()
    |> case do
      {:ok, user} -> user
      # One solved challenge creates at most one guest.
      {:error, _changeset} -> Repo.rollback(:guest_pow_invalid)
    end
  end

  defp created_today do
    day_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.one(
      from(user in User,
        where: user.kind == "guest" and user.created_at >= ^day_start,
        select: count(user.id)
      )
    )
  end

  defp with_created_today(policy), do: Map.put(policy, "created_today", created_today())


  defp lock_user!(user_id) do
    case Repo.one(from(row in User, where: row.id == ^user_id, lock: "FOR UPDATE")) do
      nil -> Repo.rollback(:not_found)
      user -> user
    end
  end

  defp lock_policy! do
    %{rows: [row]} = Ecto.Adapters.SQL.query!(Repo, policy_sql("FOR UPDATE"), [])
    policy_from_row(row)
  end

  defp store_policy!(next, command_id, previous) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      UPDATE comma_guest_policy
      SET enabled = $1, salix_tenant_id = $2, daily_creation_limit = $3,
          tenant_concurrency = $4, session_ttl_seconds = $5, pow_difficulty = $6,
          revision = revision + 1
      WHERE id = 1
      """,
      [
        next["enabled"],
        next["salix_tenant_id"],
        next["daily_creation_limit"],
        next["tenant_concurrency"],
        next["session_ttl_seconds"],
        next["pow_difficulty"]
      ]
    )

    if is_binary(command_id) do
      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE comma_admin_audit_events SET evidence = $2 WHERE id = $1::uuid",
        [
          Ecto.UUID.dump!(command_id),
          %{"before" => Map.delete(previous, "revision"), "after" => Map.delete(next, "revision")}
        ]
      )
    end

    with_created_today(%{next | "revision" => previous["revision"] + 1})
  end

  defp policy_sql(lock),
    do: "SELECT #{Enum.join(@policy_columns, ", ")} FROM comma_guest_policy WHERE id = 1 #{lock}"

  defp policy_from_row(row), do: @policy_columns |> Enum.zip(row) |> Map.new()

  defp normalize_policy_changes(attrs) do
    specs = [
      {"enabled", &is_boolean/1},
      {"daily_creation_limit", &(is_integer(&1) and &1 in 0..100_000)},
      {"tenant_concurrency", &(is_integer(&1) and &1 in 1..512)},
      {"session_ttl_seconds", &(is_integer(&1) and &1 in 3_600..2_592_000)},
      {"pow_difficulty", &(is_integer(&1) and &1 in 8..24)}
    ]

    Enum.reduce_while(specs, {:ok, %{}}, fn {key, valid?}, {:ok, changes} ->
      case Map.fetch(attrs, key) do
        :error -> {:cont, {:ok, changes}}
        {:ok, value} -> if valid?.(value), do: {:cont, {:ok, Map.put(changes, key, value)}}, else: {:halt, {:error, :invalid_guest_policy}}
      end
    end)
  end

  defp expected_revision(%{"revision" => revision}) when is_integer(revision) and revision >= 0,
    do: {:ok, revision}

  defp expected_revision(_attrs), do: {:error, :invalid_guest_policy}

  defp claim_hash(claim), do: :crypto.hash(:sha256, claim)

  defp import_operation_id,
    do: "gim_" <> Base.url_encode64(:crypto.strong_rand_bytes(15), padding: false)

  defp salix, do: Comma.Salix.Client.impl()
end
