defmodule Comma.Billing.SignupCredits do
  @moduledoc "One registration grant per new Comma user, delivered to their default Workspace."
  import Ecto.Query
  alias Comma.Accounts.User
  alias Comma.Data.Workspace
  alias Comma.Repo

  @credits 20_000_000
  def public_policy do
    %{
      "amount_minor" => 2_000,
      "currency" => "usd",
      "credits" => @credits,
      "enabled" =>
        not SystemsRuntime.get_env(:comma_core, :selfhost, false) and daily_cap() >= @credits,
      "conditions" => [
        "eligible_email_address",
        "registration_utc_day",
        "daily_budget_available"
      ]
    }
  end

  defp daily_cap,
    do: SystemsRuntime.get_env(:comma_core, :signup_credit_daily_cap_usd, 2_000) * 1_000_000

  # Plus addresses and listed domains (`Comma.Auth.EmailRestriction.listed?/1`).
  # Cloudflare Email Routing is read from DNS at registration instead.
  @doc false
  def eligible_email?(email) do
    [local, _domain] = email |> String.downcase() |> String.split("@", parts: 2)
    not String.contains?(local, "+") and not Comma.Auth.EmailRestriction.listed?(email)
  end

  @doc false
  def registration_attrs(email, opts) do
    case gmail_local(email) do
      nil ->
        if Keyword.get(opts, :eligible, false), do: %{}, else: %{signup_credit_eligible: false}

      local ->
        target_repo = Keyword.get(opts, :repo, Repo)

        prior =
          target_repo.exists?(
            from(u in User,
              where:
                u.kind == "registered" and
                  fragment("split_part(?, '@', 2) = 'gmail.com'", u.email) and
                  fragment("replace(split_part(split_part(?, '@', 1), '+', 1), '.', '')", u.email) ==
                    ^local
            )
          )

        case reserve_gmail(email, target_repo) do
          {:ok, first} ->
            %{
              signup_credit_gmail_claimed: first,
              signup_credit_eligible:
                Keyword.get(opts, :eligible, false) and
                  Keyword.get(opts, :email_verified, false) == true and first and not prior and
                  not Comma.AccountDeletion.deleted_email?(local <> "@gmail.com") and
                  not Comma.EmailChange.released_email?(local <> "@gmail.com")
            }

          {:error, _} ->
            %{signup_credit_eligible: false}
        end
    end
  end

  @doc false
  def reserve_gmail_history(emails) do
    emails
    |> List.wrap()
    |> Enum.flat_map(fn email ->
      case gmail_registration_hash(email) do
        :not_gmail -> []
        {:ok, hash} -> [hash]
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&reserve_gmail_hash(&1, Repo))

    :ok
  end

  defp reserve_gmail(email, target_repo) do
    case gmail_registration_hash(email) do
      :not_gmail -> {:ok, false}
      {:ok, hash} -> {:ok, reserve_gmail_hash(hash, target_repo)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_gmail_hash(hash, target_repo) do
    {inserted, _} =
      target_repo.insert_all(
        "comma_released_emails",
        [%{email_hash: hash, released_at: SystemsClock.timestamp(:utc_datetime_usec)}],
        on_conflict: :nothing
      )

    inserted == 1
  end

  defp gmail_local(email) do
    case String.split(email, "@", parts: 2) do
      [local, "gmail.com"] ->
        local |> String.split("+", parts: 2) |> hd() |> String.replace(".", "")

      _ ->
        nil
    end
  end

  # The existing auth key protects guessed mailbox tests by a database reader.
  # The separate purpose keeps canonical occupancy apart from exact email history.
  @doc false
  def gmail_registration_hash(email) do
    case gmail_local(email) do
      nil ->
        :not_gmail

      local ->
        case SystemsRuntime.get_env(:comma_core, :auth, []) |> get_in([:secret]) do
          secret when is_binary(secret) and secret != "" ->
            {:ok,
             :crypto.mac(:hmac, :sha256, secret, "comma-signup-gmail:" <> local <> "@gmail.com")}

          _ ->
            {:error, :auth_not_configured}
        end
    end
  end

  defp claimed_email?(%User{email: email, signup_credit_gmail_claimed: claimed}) do
    case String.split(email, "@", parts: 2) do
      [local, "gmail.com"] -> not String.contains?(local, ".") or claimed
      _ -> true
    end
  end

  @doc "Complete registration gifts after old Workspace workers leave the rollout."
  def converge do
    if SystemsRuntime.get_env(:comma_core, :selfhost, false), do: :ok, else: converge_after(nil)
  end

  defp converge_after(cursor) do
    query =
      from(u in User,
        where:
          u.signup_credit_eligible == true and u.status == "active" and
            fragment(
              "? >= date_trunc('day', clock_timestamp() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'",
              u.created_at
            ),
        order_by: [asc: u.id],
        select: u.id,
        limit: 100
      )

    query = if cursor, do: from(u in query, where: u.id > ^cursor), else: query
    users = Repo.all(query)

    result =
      Enum.reduce_while(users, :ok, fn owner, :ok ->
        workspace =
          Repo.one(
            from(w in Workspace,
              where: w.owner_user_id == ^owner and w.status != "deleted",
              order_by: [asc: w.inserted_at, asc: w.id],
              limit: 1
            )
          )

        result =
          if workspace && workspace.status == "active" do
            ensure(%{"id" => workspace.id, "owner_user_id" => owner})
          else
            :ok
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {owner, reason}}}
        end
      end)

    case {result, users} do
      {{:error, _} = error, _} -> error
      {:ok, []} -> :ok
      {:ok, users} -> converge_after(List.last(users))
    end
  end

  def ensure(workspace) do
    if SystemsRuntime.get_env(:comma_core, :selfhost, false) do
      :ok
    else
      case Repo.transaction(fn -> ensure_locked(workspace) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp ensure_locked(workspace) do
    owner = workspace["owner_user_id"]
    user = Repo.one(from(u in User, where: u.id == ^owner, lock: "FOR UPDATE"))

    case user do
      %User{status: "active", signup_credit_eligible: true} ->
        default =
          Repo.one(
            from(w in Workspace,
              where: w.owner_user_id == ^owner and w.status != "deleted",
              order_by: [asc: w.inserted_at, asc: w.id],
              limit: 1
            )
          )

        if default && default.id == workspace["id"] do
          case BillingCore.Repo.transaction(fn ->
                 grant(default, user, "grant_comma_signup_" <> owner)
               end) do
            {:ok, :ok} ->
              user |> Ecto.Changeset.change(signup_credit_eligible: false) |> Repo.update!()

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end

        :ok

      %User{} ->
        :ok

      nil ->
        Repo.rollback(:not_found)
    end
  end

  defp grant(workspace, user, id) do
    repo = BillingCore.Repo
    sql = Ecto.Adapters.SQL
    existing = sql.query!(repo, "SELECT id FROM credit_grants WHERE id=$1", [id]).rows

    if existing == [] do
      case BillingCore.Accounts.verify_account(%{
             repo: repo,
             billing_account_id: workspace.billing_owner_id,
             required_surface: "comma",
             product_owner_type: "workspace",
             product_owner_id: workspace.id,
             enforce_product_owner_identity: true
           }) do
        :ok -> :ok
        {:error, reason} -> repo.rollback(reason)
      end

      sql.query!(repo, "SELECT pg_advisory_xact_lock(hashtext('comma:signup:daily-budget'))", [])
      [[now]] = sql.query!(repo, "SELECT clock_timestamp()", []).rows
      day = DateTime.to_date(now)

      if DateTime.to_date(user.created_at) == day and eligible_email?(user.email) and
           claimed_email?(user) and
           not Comma.AccountDeletion.deleted_email?(user.email) and
           not Comma.EmailChange.released_email?(user.email) do
        {:ok, start} = DateTime.new(day, ~T[00:00:00], "Etc/UTC")
        ending = DateTime.add(start, 86_400)

        [[issued]] =
          sql.query!(
            repo,
            "SELECT COALESCE(SUM(original_credits), 0)::bigint FROM credit_grants WHERE source_type='comma_signup' AND inserted_at >= $1 AND inserted_at < $2",
            [start, ending]
          ).rows

        if issued + @credits <= daily_cap() do
          case BillingCore.Credits.issue_grant(%{
                 repo: repo,
                 id: id,
                 billing_account_id: workspace.billing_owner_id,
                 idempotency_key: "comma:signup:" <> user.id,
                 source_type: "comma_signup",
                 source_id: user.id,
                 credits: @credits,
                 valid_from: user.created_at,
                 expires_at: nil,
                 now: now,
                 metadata: %{"surface" => "comma", "reason" => "registration"}
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> repo.rollback(reason)
          end
        end
      end
    end

    :ok
  end
end
