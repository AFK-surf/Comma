defmodule Comma.Billing.FreeMonthlyCredits do
  @moduledoc """
  One Credit Grant per calendar month for each free Comma User, delivered to
  their default Workspace. The grant pays only for Cloud VM and storage usage,
  and expires at the end of the UTC month.
  """
  import Ecto.Query
  alias Comma.Accounts.User
  alias Comma.Billing.SignupCredits
  alias Comma.Data.Workspace
  alias Comma.Repo

  require Logger

  @credits 5_000_000
  @policy %{"usage_credits" => %{"mode" => "metered", "resource_kinds" => ["vm", "storage"]}}
  @page 200

  @doc "Issue this month's grants to every free User who has none yet."
  def converge do
    if SystemsRuntime.get_env(:comma_core, :selfhost, false) do
      :ok
    else
      converge_after(nil, SystemsClock.utc_now())
    end
  end

  @doc "Issue this month's grant when `workspace` is the default Workspace of a free User."
  def ensure(workspace) do
    if SystemsRuntime.get_env(:comma_core, :selfhost, false) do
      :ok
    else
      now = SystemsClock.utc_now()
      users = Repo.all(from(u in users_query(), where: u.id == ^workspace["owner_user_id"]))
      workspace_id = workspace["id"]

      case candidates(users, now) do
        [{_user, %{id: ^workspace_id}, _id} = candidate] -> issue(candidate, now)
        _ -> :ok
      end
    end
  end

  defp converge_after(cursor, now) do
    query = from(u in users_query(), order_by: [asc: u.id], limit: @page)
    query = if cursor, do: from(u in query, where: u.id > ^cursor), else: query

    case Repo.all(query) do
      [] ->
        :ok

      users ->
        users
        |> candidates(now)
        |> Enum.filter(fn {_user, default, _id} -> default.status == "active" end)
        |> Enum.each(fn candidate ->
          with {:error, reason} <- issue(candidate, now) do
            {user, _default, _id} = candidate
            Logger.warning("free monthly credits failed for #{user.id}: #{inspect(reason)}")
          end
        end)

        converge_after(List.last(users).id, now)
    end
  end

  defp users_query do
    from(u in User, where: u.kind == "registered" and u.status == "active")
  end

  # One read per store for a whole page of Users.
  defp candidates(users, now) do
    users = Enum.filter(users, &SignupCredits.eligible_email?(&1.email))
    owners = Enum.map(users, & &1.id)

    workspaces =
      from(w in Workspace,
        where: w.owner_user_id in ^owners and w.status != "deleted",
        order_by: [asc: w.inserted_at, asc: w.id]
      )
      |> Repo.all()
      |> Enum.group_by(& &1.owner_user_id)

    subscribed = subscribed_accounts(Enum.flat_map(workspaces, fn {_, list} -> list end))

    listed =
      for user <- users,
          [default | _] = owned <- [Map.get(workspaces, user.id, [])],
          not Enum.any?(owned, &MapSet.member?(subscribed, &1.billing_owner_id)) do
        {user, default, grant_id(user.id, now)}
      end

    issued = issued_grants(Enum.map(listed, fn {_user, _default, id} -> id end))

    listed
    |> Enum.reject(fn {_user, _default, id} -> MapSet.member?(issued, id) end)
    |> reject_routed()
  end

  # An address on Cloudflare Email Routing gets no grant
  # (`Comma.Auth.EmailRestriction`). Users not yet granted this month are
  # asked, one MX lookup per distinct domain of the page.
  defp reject_routed(candidates) do
    routed =
      candidates
      |> Enum.map(fn {user, _default, _id} -> domain(user.email) end)
      |> Enum.uniq()
      |> Enum.filter(&Comma.Auth.EmailRestriction.restricted_domain?/1)
      |> MapSet.new()

    Enum.reject(candidates, fn {user, _default, _id} ->
      MapSet.member?(routed, domain(user.email))
    end)
  end

  defp domain(email), do: Comma.Auth.EmailRestriction.domain(email)

  defp subscribed_accounts(workspaces) do
    accounts = Enum.map(workspaces, & &1.billing_owner_id)

    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      """
      SELECT DISTINCT billing_account_id
      FROM billing_subscriptions
      WHERE billing_account_id = ANY($1)
        AND status IN ('active', 'trialing', 'past_due', 'unpaid', 'paused')
      """,
      [accounts]
    ).rows
    |> MapSet.new(fn [account] -> account end)
  end

  defp issued_grants(ids) do
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "SELECT id FROM credit_grants WHERE id = ANY($1)",
      [ids]
    ).rows
    |> MapSet.new(fn [id] -> id end)
  end

  defp issue({user, workspace, id}, now) do
    repo = BillingCore.Repo

    repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [id])

      if Ecto.Adapters.SQL.query!(repo, "SELECT id FROM credit_grants WHERE id = $1", [id]).rows ==
           [] do
        with :ok <-
               BillingCore.Accounts.verify_account(%{
                 repo: repo,
                 billing_account_id: workspace.billing_owner_id,
                 required_surface: "comma",
                 product_owner_type: "workspace",
                 product_owner_id: workspace.id,
                 enforce_product_owner_identity: true
               }),
             {:ok, _} <-
               BillingCore.Credits.issue_grant(%{
                 repo: repo,
                 id: id,
                 billing_account_id: workspace.billing_owner_id,
                 idempotency_key: "comma:free_monthly:" <> user.id <> ":" <> month(now),
                 source_type: "comma_free_monthly",
                 source_id: user.id,
                 credits: @credits,
                 valid_from: now,
                 expires_at: next_month(now),
                 policy_snapshot: @policy,
                 now: now,
                 metadata: %{"surface" => "comma", "reason" => "free_monthly"}
               }) do
          :ok
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp grant_id(user_id, now), do: "grant_comma_free_monthly_" <> user_id <> "_" <> month(now)

  defp month(%DateTime{year: year, month: month}) do
    "#{year}-" <> String.pad_leading(Integer.to_string(month), 2, "0")
  end

  defp next_month(%DateTime{year: year, month: 12}), do: first_of(year + 1, 1)
  defp next_month(%DateTime{year: year, month: month}), do: first_of(year, month + 1)

  defp first_of(year, month) do
    {:ok, date} = Date.new(year, month, 1)
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end
end
