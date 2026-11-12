defmodule Comma.AccountDeletion do
  @moduledoc """
  A registered User deletes their own Comma account.

  The User asks for a code (`request_code/2`), which is mailed to the account
  email, and confirms with it (`schedule/2`). Confirming refuses while a
  subscription of an owned Workspace still renews (the User cancels renewal
  in the Stripe portal first; a subscription that no longer renews ends by
  itself), signs the account out everywhere and sets `deletion_scheduled_at`
  seven days ahead. Signing in again before then takes the deletion back
  (`cancel/2`, called by `Comma.Accounts.Sessions`).

  When the seven days are over, the hourly sweep
  (`Comma.Workers.AccountDeletionSweep`, `delete_due/1`) deletes the account
  in one transaction, which cannot be undone:

    * revokes every Auth Session and the account's station credentials;
    * marks the owned Workspaces `deleted` and deletes their Mini Apps;
    * removes the account's identities, links, shares and per-user state;
    * keeps the User row without personal data: a placeholder email, no name,
      avatar or locale, status `deleted`, and a keyed hash of the old email
      (`deleted_email_hash`) so a new account with it gets no registration
      credits;
    * queues an `account_deletion` operation
      (`Comma.Workers.AccountDeletion`) that stops the Workspaces' outside
      effects in Salix and cleans up the avatar objects.

  Salix Conversation and file content of the Workspaces stays in their Tenant,
  where no one can reach it any more.
  """

  import Ecto.Query

  require Logger

  alias Comma.Accounts.{Repository, Sessions, User, UserAvatar}
  alias Comma.Data.Workspace
  alias Comma.{AuthChallenges, Operations, Repo}
  alias Ecto.Multi

  @operation_type "account_deletion"
  @owner_type "user"
  @placeholder_domain "deleted.comma.invalid"
  @renewing_statuses ~w(active trialing past_due unpaid paused)
  @grace_seconds 7 * 24 * 60 * 60
  @sweep_batch 100

  # Rows that exist only for the account, by table and the column naming it.
  # Auth Sessions and Workspace memberships stay: revoked sessions fence old
  # credentials, and memberships name the Groups that station revocations reach.
  @owned_rows [
    {"comma_user_identities", :user_id},
    {"comma_telegram_dm_links", :owner_user_id},
    {"comma_telegram_dm_claim_codes", :owner_user_id},
    {"comma_telegram_oidc_attempts", :owner_user_id},
    {"comma_imessage_dm_links", :owner_user_id},
    {"comma_imessage_dm_claim_codes", :owner_user_id},
    {"comma_line_dm_links", :owner_user_id},
    {"comma_line_dm_claim_codes", :owner_user_id},
    {"comma_linear_install_attempts", :owner_user_id},
    {"comma_linear_members", :user_id},
    {"comma_recommendation_profiles", :user_id},
    {"comma_member_source_consents", :user_id},
    {"comma_task_shares", :created_by},
    {"comma_task_requests", :sender_user_id},
    {"comma_task_request_grants", :grantee_user_id},
    {"comma_task_request_grants", :created_by},
    {"comma_provider_user_links", :user_id},
    {"comma_task_panel_dismissals", :user_id},
    {"comma_assistant_chat_bindings", :user_id},
    {"comma_admin_access_overrides", :user_id}
  ]

  def operation_type, do: @operation_type

  @doc "Mails the signed-in User the code that confirms deletion."
  def request_code(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, user} <- deletable_user(user_id),
         :ok <- no_renewing_subscription(user_id) do
      AuthChallenges.request_account_deletion(user, attrs)
    end
  end

  @doc """
  Confirms deletion with the mailed code: signs the account out everywhere and
  deletes it after seven days unless the User signs in again before then.
  """
  def schedule(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, _user} <- deletable_user(user_id),
         :ok <- no_renewing_subscription(user_id),
         :ok <- AuthChallenges.verify_account_deletion(user_id, attrs) do
      since = SystemsClock.system_time(:second)
      scheduled_at = DateTime.add(SystemsClock.timestamp(:utc_datetime_usec), @grace_seconds)

      case Repo.transaction(fn -> schedule_locked(user_id, scheduled_at) end) do
        {:ok, scheduled_at} ->
          Comma.Stations.Revocations.publish_since(user_id, since)
          {:ok, scheduled_at}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Takes back a deletion that has not happened yet; a no-op without one."
  def cancel(user_id, opts \\ []) when is_binary(user_id) do
    repo = Keyword.get(opts, :repo, Repo)

    from(u in User,
      where: u.id == ^user_id and u.status == "active" and not is_nil(u.deletion_scheduled_at)
    )
    |> repo.update_all(
      set: [deletion_scheduled_at: nil, updated_at: SystemsClock.timestamp(:utc_datetime_usec)]
    )

    :ok
  end

  @doc "Deletes up to #{@sweep_batch} accounts whose deletion time has come."
  def delete_due(now \\ SystemsClock.timestamp(:utc_datetime_usec)) do
    from(u in User,
      where: u.status == "active" and u.deletion_scheduled_at <= ^now,
      order_by: [asc: u.deletion_scheduled_at, asc: u.id],
      limit: @sweep_batch,
      select: u.id
    )
    |> Repo.all()
    |> Enum.each(fn user_id ->
      case delete(user_id, now) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("account deletion failed user_id=#{user_id} reason=#{inspect(reason)}")
      end
    end)
  end

  defp delete(user_id, now) do
    with {:ok, hash} <- email_hash_for(user_id) do
      since = SystemsClock.system_time(:second)

      case Repo.transaction(fn -> delete_locked(user_id, hash, now) end) do
        {:ok, avatar_ids} ->
          Comma.Stations.Revocations.publish_since(user_id, since)
          Enum.each(avatar_ids, &enqueue_avatar_cleanup/1)
          Comma.Analytics.identify(user_id)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Whether an account with this email was deleted before."
  def deleted_email?(email) when is_binary(email) do
    case email_hash(email) do
      {:ok, hash} ->
        Repo.exists?(from(u in User, where: u.deleted_email_hash == ^hash))

      {:error, _reason} ->
        false
    end
  end

  defp deletable_user(user_id) do
    case Repository.get_user(user_id) do
      {:ok, %User{kind: "registered", status: "active"} = user} -> {:ok, user}
      {:ok, %User{}} -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp email_hash_for(user_id) do
    {:ok, user} = Repository.get_user(user_id)

    case email_hash(user.email) do
      {:ok, hash} -> {:ok, hash}
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  # Keyed with the auth secret under its own purpose, so the stored hash does
  # not let a database reader test guessed emails.
  @doc false
  def email_hash(email) do
    case SystemsRuntime.get_env(:comma_core, :auth, []) |> get_in([:secret]) do
      secret when is_binary(secret) and secret != "" ->
        {:ok, :crypto.mac(:hmac, :sha256, secret, "comma-deleted-account-email-v1:" <> email)}

      _ ->
        {:error, :auth_not_configured}
    end
  end

  @doc false
  def no_renewing_subscription(user_id) do
    accounts =
      Repo.all(
        from(w in Workspace,
          where: w.owner_user_id == ^user_id and w.status != "deleted",
          select: w.billing_owner_id
        )
      )

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        """
        SELECT 1
        FROM billing_subscriptions
        WHERE billing_account_id = ANY($1)
          AND status = ANY($2)
          AND COALESCE(source_metadata ->> 'cancel_at_period_end', 'false') <> 'true'
        LIMIT 1
        """,
        [accounts, @renewing_statuses]
      )

    if rows == [], do: :ok, else: {:error, :subscription_active}
  end

  defp schedule_locked(user_id, scheduled_at) do
    user = Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

    unless match?(%User{kind: "registered", status: "active"}, user) do
      Repo.rollback(:forbidden)
    end

    {:ok, _count} =
      Sessions.revoke_all(user_id, repo: Repo, reason: "user_deletion_scheduled")

    _ = Comma.Stations.Revocations.user_revoked(Repo, user_id)

    user
    |> Ecto.Changeset.change(
      deletion_scheduled_at: scheduled_at,
      auth_epoch: user.auth_epoch + 1
    )
    |> Repo.update!()

    scheduled_at
  end

  # A sign-in that took the deletion back holds the same row lock, so the
  # schedule is read again under it.
  defp delete_locked(user_id, hash, now) do
    user = Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))

    due? =
      match?(%User{kind: "registered", status: "active"}, user) and
        not is_nil(user.deletion_scheduled_at) and
        DateTime.compare(user.deletion_scheduled_at, now) != :gt

    unless due?, do: Repo.rollback(:not_due)

    :ok = Comma.Billing.SignupCredits.reserve_gmail_history(user.email)

    case Comma.Auth.Abuse.retire_email(user.email) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    # Revocations reach the Groups of the account's Workspaces, so they run
    # while the memberships still name them.
    {:ok, _count} = Sessions.revoke_all(user_id, repo: Repo, reason: "user_deleted")
    _ = Comma.Stations.Revocations.user_revoked(Repo, user_id)

    workspace_ids =
      Repo.all(
        from(w in Workspace,
          where: w.owner_user_id == ^user_id and w.status != "deleted",
          lock: "FOR UPDATE",
          select: w.id
        )
      )

    from(w in Workspace, where: w.id in ^workspace_ids)
    |> Repo.update_all(set: [status: "deleted", updated_at: now])

    for workspace_id <- workspace_ids do
      {:ok, _count} = Comma.MiniApps.delete_workspace_apps(workspace_id)
    end

    avatar_ids =
      Repo.all(
        from(a in UserAvatar,
          where: a.user_id == ^user_id and a.status == "active",
          select: a.id
        )
      )

    from(a in UserAvatar, where: a.id in ^avatar_ids)
    |> Repo.update_all(set: [status: "cleanup", updated_at: now])

    for {table, column} <- @owned_rows do
      from(r in table, where: field(r, ^column) == ^user_id) |> Repo.delete_all()
    end

    user
    |> Ecto.Changeset.change(
      email: placeholder_email(),
      name: nil,
      avatar_id: nil,
      locale: nil,
      review_login_code_hash: nil,
      signup_credit_eligible: false,
      status: "deleted",
      auth_epoch: user.auth_epoch + 1,
      deletion_scheduled_at: nil,
      deleted_at: now,
      deleted_email_hash: hash
    )
    |> Repo.update!()

    operation_id = "op_account_deletion_" <> user_id

    Multi.new()
    |> Operations.create_with_job(
      %{
        operation_id: operation_id,
        operation_type: @operation_type,
        owner_type: @owner_type,
        owner_id: user_id,
        generation: 1,
        status: "pending",
        attempt: 0,
        external_idempotency_key: "account_deletion:" <> user_id,
        metadata: %{"workspace_ids" => workspace_ids}
      },
      Comma.Workers.AccountDeletion.new(%{"operation_id" => operation_id})
    )
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> avatar_ids
      {:error, _step, reason, _changes} -> Repo.rollback(reason)
    end
  end

  defp placeholder_email do
    "d-" <>
      Base.encode16(SystemsRuntime.Proc.random_bytes(12), case: :lower) <>
      "@" <> @placeholder_domain
  end

  defp enqueue_avatar_cleanup(avatar_id) do
    case Oban.insert(
           Comma.Oban,
           Comma.Workers.ProfileAvatarCleanup.new(%{"avatar_id" => avatar_id})
         ) do
      {:ok, _job} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
