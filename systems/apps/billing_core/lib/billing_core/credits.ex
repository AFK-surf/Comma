defmodule BillingCore.Credits do
  @moduledoc """
  Credit grant lot issuance and derived availability helpers.

  Grant issuance and provider compensation are modeled in
  `tla/billing/StripeCredits.tla`.
  """

  alias BillingCore.Entitlements.Policy

  @active_status "active"

  @spec issue_grant(map()) :: {:ok, map()} | {:error, term()}
  def issue_grant(attrs) when is_map(attrs) do
    if attrs[:repo] || attrs["repo"] do
      issue_repo_grant(attrs)
    else
      issue_state_grant(attrs)
    end
  end

  @doc """
  Removes up to the requested credits from one grant lot.

  This is the authoritative compensation path for provider refunds and
  disputes. Already-consumed credits are never taken from unrelated grants;
  the result reports the unapplied portion for audit and collections policy.
  """
  @spec reduce_grant(map()) :: {:ok, map()} | {:error, term()}
  def reduce_grant(attrs) when is_map(attrs) do
    repo = attrs[:repo] || attrs["repo"] || Application.fetch_env!(:billing_core, :repo)
    sql = attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL
    account_id = required(attrs, :billing_account_id)
    grant_id = required(attrs, :credit_grant_id)
    requested_credits = required(attrs, :credits)
    idempotency_key = required(attrs, :idempotency_key)

    if not is_integer(requested_credits) or requested_credits < 0 do
      {:error, :invalid_credit_reduction}
    else
      repo.transaction(fn ->
        case existing_reduction(repo, sql, account_id, idempotency_key) do
          nil ->
            grant = lock_grant!(repo, sql, account_id, grant_id)
            applied_credits = min(requested_credits, grant.remaining_credits)
            remaining_credits = grant.remaining_credits - applied_credits
            status = if remaining_credits == 0, do: "revoked", else: grant.status

            sql.query!(
              repo,
              """
              UPDATE credit_grants
              SET remaining_credits = $3, status = $4, updated_at = now()
              WHERE id = $1 AND billing_account_id = $2
              """,
              [grant_id, account_id, remaining_credits, status]
            )

            event_id = id("grant_event")

            sql.query!(
              repo,
              """
              INSERT INTO credit_grant_events (
                id, billing_account_id, credit_grant_id, event_type, source_type,
                source_id, source_event_id, idempotency_key, credits_delta,
                snapshot, inserted_at
              ) VALUES ($1, $2, $3, 'reduced', $4, $5, $6, $7, $8, $9, now())
              """,
              [
                event_id,
                account_id,
                grant_id,
                attrs[:source_type] || attrs["source_type"],
                attrs[:source_id] || attrs["source_id"],
                attrs[:source_event_id] || attrs["source_event_id"],
                idempotency_key,
                -applied_credits,
                Jason.encode!(%{
                  requested_credits: requested_credits,
                  applied_credits: applied_credits,
                  unapplied_credits: requested_credits - applied_credits,
                  remaining_credits: remaining_credits,
                  status: status,
                  reason: attrs[:reason] || attrs["reason"]
                })
              ]
            )

            %{
              event_id: event_id,
              credit_grant_id: grant_id,
              requested_credits: requested_credits,
              applied_credits: applied_credits,
              unapplied_credits: requested_credits - applied_credits,
              remaining_credits: remaining_credits,
              status: status,
              idempotent: false
            }

          reduction ->
            Map.put(reduction, :idempotent, true)
        end
      end)
    end
  end

  @spec available_credits([map()], String.t(), DateTime.t()) :: non_neg_integer()
  def available_credits(grants, account_id, at) when is_list(grants) do
    grants
    |> Enum.filter(&active_grant?(&1, account_id, at))
    |> Enum.reduce(
      0,
      &(Map.get(&1, :remaining_credits, Map.get(&1, "remaining_credits", 0)) + &2)
    )
  end

  @spec active_policies([map()], String.t(), DateTime.t()) :: [map()]
  def active_policies(grants, account_id, at) when is_list(grants) do
    grants
    |> Enum.filter(&active_entitlement?(&1, account_id, at))
    |> Enum.map(
      &(Map.get(&1, :policy_snapshot) || Map.get(&1, "policy_snapshot") || Policy.default())
    )
  end

  @spec active_usage_mode([map()], String.t(), DateTime.t()) :: :metered | :unlimited_metered
  def active_usage_mode(grants, account_id, at) when is_list(grants) do
    grants
    |> active_policies(account_id, at)
    |> Policy.active_usage_mode()
  end

  defp issue_state_grant(attrs) do
    state = Map.fetch!(attrs, :state)
    account_id = required(attrs, :billing_account_id)
    idempotency_key = required(attrs, :idempotency_key)

    case Enum.find(state.grants, &same_idempotency?(&1, account_id, idempotency_key)) do
      nil ->
        with {:ok, policy} <-
               Policy.normalize(attrs[:policy_snapshot] || attrs["policy_snapshot"]) do
          now = attrs[:now] || DateTime.utc_now()
          credits = required(attrs, :credits)
          expires_at = required(attrs, :expires_at)

          grant =
            attrs
            |> Map.take([
              :id,
              :billing_account_id,
              :package_code,
              :package_version,
              :source_type,
              :source_id,
              :source_event_id,
              :idempotency_key,
              :package_snapshot,
              :metadata,
              :valid_from,
              :expires_at,
              :priority
            ])
            |> Map.merge(%{
              id: attrs[:id] || id("grant"),
              billing_account_id: account_id,
              original_credits: credits,
              remaining_credits: credits,
              valid_from: required(attrs, :valid_from),
              expires_at: expires_at,
              status: @active_status,
              priority: attrs[:priority] || 0,
              policy_snapshot: policy,
              inserted_at: now,
              updated_at: now
            })

          event = grant_event(grant, "issued", now)

          next_state = %{
            state
            | grants: [grant | state.grants],
              grant_events: [event | state.grant_events]
          }

          {:ok, %{grant: grant, event: event, idempotent: false}, next_state}
        end

      grant ->
        {:ok, %{grant: grant, idempotent: true}, state}
    end
  end

  defp issue_repo_grant(attrs) do
    repo = attrs[:repo] || attrs["repo"]
    sql = attrs[:sql_runner] || attrs["sql_runner"] || Ecto.Adapters.SQL
    account_id = required(attrs, :billing_account_id)
    idempotency_key = required(attrs, :idempotency_key)
    credits = required(attrs, :credits)
    valid_from = required(attrs, :valid_from)
    expires_at = required(attrs, :expires_at)
    policy = Policy.normalize!(attrs[:policy_snapshot] || attrs["policy_snapshot"])

    repo.transaction(fn ->
      grant_id = attrs[:id] || id("grant")

      inserted =
        sql.query!(
          repo,
          """
          INSERT INTO credit_grants (
            id, billing_account_id, original_credits, remaining_credits, valid_from,
            expires_at, source_type, source_id, source_event_id, idempotency_key,
            package_code, package_version, package_snapshot, policy_snapshot,
            status, priority, metadata, inserted_at, updated_at
          ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            $11, $12, $13, $14, 'active', $15, $16, now(), now()
          )
          ON CONFLICT (billing_account_id, idempotency_key) DO NOTHING
          RETURNING id, billing_account_id, remaining_credits, status
          """,
          [
            grant_id,
            account_id,
            credits,
            credits,
            valid_from,
            expires_at,
            attrs[:source_type],
            attrs[:source_id],
            attrs[:source_event_id],
            idempotency_key,
            attrs[:package_code],
            attrs[:package_version],
            Jason.encode!(attrs[:package_snapshot] || %{}),
            Jason.encode!(policy),
            attrs[:priority] || 0,
            Jason.encode!(attrs[:metadata] || %{})
          ]
        )

      case inserted.rows do
        [[inserted_id, billing_account_id, remaining_credits, status] | _] ->
          event_id = id("grant_event")

          sql.query!(
            repo,
            """
            INSERT INTO credit_grant_events (
              id, billing_account_id, credit_grant_id, event_type, source_type,
              source_id, source_event_id, idempotency_key, credits_delta,
              snapshot, inserted_at
            ) VALUES ($1, $2, $3, 'issued', $4, $5, $6, $7, $8, $9, now())
            """,
            [
              event_id,
              account_id,
              inserted_id,
              attrs[:source_type],
              attrs[:source_id],
              attrs[:source_event_id],
              idempotency_key,
              credits,
              Jason.encode!(%{
                policy_snapshot: policy,
                package_snapshot: attrs[:package_snapshot] || %{}
              })
            ]
          )

          # A real top-up must not leave this account's charges sitting out a
          # long backoff: requeue them to be picked up on the next sweep.
          sql.query!(
            repo,
            """
            UPDATE pending_meter_charges
            SET next_attempt_at = now(), attempts = 0
            WHERE billing_account_id = $1 AND status = 'pending'
            """,
            [account_id],
            log: false
          )

          %{
            id: inserted_id,
            billing_account_id: billing_account_id,
            remaining_credits: remaining_credits,
            status: status,
            idempotent: false
          }

        [] ->
          repo_grant_by_idempotency(repo, sql, account_id, idempotency_key)
          |> Map.put(:idempotent, true)
      end
    end)
  end

  defp repo_grant_by_idempotency(repo, sql, account_id, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, billing_account_id, remaining_credits, status
        FROM credit_grants
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [account_id, idempotency_key]
      )

    case result.rows do
      [[id, billing_account_id, remaining_credits, status] | _] ->
        %{
          id: id,
          billing_account_id: billing_account_id,
          remaining_credits: remaining_credits,
          status: status
        }

      [] ->
        nil
    end
  end

  defp existing_reduction(repo, sql, account_id, idempotency_key) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, credit_grant_id, credits_delta, snapshot
        FROM credit_grant_events
        WHERE billing_account_id = $1 AND idempotency_key = $2
        LIMIT 1
        """,
        [account_id, idempotency_key]
      )

    case result.rows do
      [[event_id, grant_id, credits_delta, snapshot] | _] ->
        snapshot = if is_binary(snapshot), do: Jason.decode!(snapshot), else: snapshot

        %{
          event_id: event_id,
          credit_grant_id: grant_id,
          requested_credits: snapshot["requested_credits"],
          applied_credits: -credits_delta,
          unapplied_credits: snapshot["unapplied_credits"],
          remaining_credits: snapshot["remaining_credits"],
          status: snapshot["status"]
        }

      [] ->
        nil
    end
  end

  defp lock_grant!(repo, sql, account_id, grant_id) do
    result =
      sql.query!(
        repo,
        """
        SELECT id, remaining_credits, status
        FROM credit_grants
        WHERE id = $1 AND billing_account_id = $2
        FOR UPDATE
        """,
        [grant_id, account_id]
      )

    case result.rows do
      [[id, remaining_credits, status] | _] ->
        %{id: id, remaining_credits: remaining_credits, status: status}

      [] ->
        repo.rollback(:credit_grant_not_found)
    end
  end

  defp same_idempotency?(grant, account_id, idempotency_key) do
    Map.get(grant, :billing_account_id) == account_id and
      Map.get(grant, :idempotency_key) == idempotency_key
  end

  defp active_grant?(grant, account_id, at) do
    active_entitlement?(grant, account_id, at) and
      Map.get(grant, :remaining_credits, Map.get(grant, "remaining_credits", 0)) > 0
  end

  defp active_entitlement?(grant, account_id, at) do
    Map.get(grant, :billing_account_id, Map.get(grant, "billing_account_id")) == account_id and
      Map.get(grant, :status, Map.get(grant, "status", @active_status)) == @active_status and
      valid_at?(grant, at)
  end

  defp valid_at?(grant, at) do
    valid_from = Map.get(grant, :valid_from, Map.get(grant, "valid_from"))
    expires_at = Map.get(grant, :expires_at, Map.get(grant, "expires_at"))

    (is_nil(valid_from) or DateTime.compare(valid_from, at) != :gt) and
      (is_nil(expires_at) or DateTime.compare(expires_at, at) == :gt)
  end

  defp grant_event(grant, event_type, at) do
    %{
      id: id("grant_event"),
      billing_account_id: grant.billing_account_id,
      credit_grant_id: grant.id,
      event_type: event_type,
      source_type: grant.source_type,
      source_id: grant.source_id,
      source_event_id: grant.source_event_id,
      idempotency_key: grant.idempotency_key,
      credits_delta: grant.original_credits,
      snapshot: grant,
      inserted_at: at
    }
  end

  defp required(attrs, key) do
    attrs[key] || attrs[to_string(key)] || raise ArgumentError, "missing grant field #{key}"
  end

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
