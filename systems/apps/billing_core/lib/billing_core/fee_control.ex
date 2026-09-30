defmodule BillingCore.FeeControl do
  @moduledoc """
  Fee-control checks with an explicit cache.

  `authorize/1` is the typed hard availability API. `check_cached/2` remains as
  the migration wrapper for product/runtime callers still passing maps; owner:
  billing platform, delete when Comma/BFT/Salix have all moved to typed requests.
  """

  alias BillingCore.{Credits, State}
  alias BillingCore.Entitlements.Policy
  alias BillingCore.FeeControl.{Decision, Request}

  @default_ttl_ms 60_000

  @spec check(State.t(), map()) :: {:ok, map(), State.t()}
  def check(%State{} = state, attrs) when is_map(attrs) do
    now = Map.get(attrs, :now, System.system_time(:millisecond))
    ttl_ms = Map.get(attrs, :cache_ttl_ms) || @default_ttl_ms

    key =
      cache_key(attrs)

    if enforce_mode?(attrs) do
      refresh(state, attrs, key, now, ttl_ms, false, nil)
    else
      case fresh_cache(state.fee_control_cache, key, now, ttl_ms) do
        {:ok, cached, age_ms} ->
          if refresh_probe?(attrs) do
            refresh(state, attrs, key, now, ttl_ms, true, age_ms)
          else
            {:ok, result(attrs, cached, true, false, 0, age_ms, ttl_ms), state}
          end

        :miss ->
          refresh(state, attrs, key, now, ttl_ms, false, nil)
      end
    end
  end

  @spec check_cached(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def check_cached(attrs, opts \\ []) when is_map(attrs) do
    BillingCore.FeeControl.Server.check(attrs, opts)
  end

  @spec authorize(Request.t() | map()) :: {:ok, Decision.t()} | {:error, term()}
  def authorize(%Request{} = request), do: authorize(Map.from_struct(request))

  def authorize(attrs) when is_map(attrs) do
    policy_context = attrs[:policy_context] || attrs["policy_context"] || %{}

    surface =
      attrs[:surface] || attrs["surface"] || policy_context[:surface] || policy_context["surface"] ||
        "system"

    SystemsObservability.Context.with_surface(surface, fn ->
      SystemsObservability.Trace.with_span(
        :billing,
        %{component: "billing", surface: surface, operation: "authorize"},
        fn -> do_authorize(attrs) end
      )
    end)
  end

  defp do_authorize(attrs) do
    state = attrs[:state]

    if match?(%State{}, state) do
      {:ok, decision, _state} = check(state, attrs)
      {:ok, decision}
    else
      attrs
      |> Map.put_new(:mode, :enforce)
      |> check_cached()
    end
  end

  defp fresh_cache(cache, key, now, ttl_ms) do
    case Map.fetch(cache, key) do
      {:ok, %{snapshot: snapshot, cached_at_ms: cached_at}} when now - cached_at <= ttl_ms ->
        {:ok, snapshot, now - cached_at}

      _ ->
        :miss
    end
  end

  defp refresh(state, attrs, key, now, ttl_ms, cache_hit, age_ms) do
    started = System.monotonic_time(:millisecond)
    {snapshot, query_performed} = perform_query(attrs)
    duration = max(System.monotonic_time(:millisecond) - started, 0)
    cache_entry = %{snapshot: snapshot, cached_at_ms: now}

    next_state = %{
      state
      | fee_control_cache: Map.put(state.fee_control_cache, key, cache_entry)
    }

    {:ok, result(attrs, snapshot, cache_hit, query_performed, duration, age_ms, ttl_ms),
     next_state}
  end

  defp refresh_probe?(attrs) do
    attrs[:force_refresh] == true or attrs["force_refresh"] == true or attrs[:probe] == true or
      attrs["probe"] == true or sampled_probe?(attrs)
  end

  defp sampled_probe?(attrs) do
    rate = attrs[:probe_rate] || attrs["probe_rate"] || 0
    is_number(rate) and rate > 0 and :rand.uniform() <= rate
  end

  defp perform_query(attrs) do
    query_fun = Map.get(attrs, :query_fun)
    balance_snapshot = Map.get(attrs, :balance_snapshot, 0)

    cond do
      is_function(query_fun, 0) ->
        {query_fun.(), true}

      repo_query?(attrs) ->
        {repo_availability(attrs), true}

      Map.has_key?(attrs, :state) ->
        {state_availability(attrs), true}

      true ->
        if enforce_mode?(attrs) do
          {%{
             balance_snapshot: 0,
             account_status: "missing",
             entitlement_mode: :metered,
             entitlement_policy: Policy.default()
           }, false}
        else
          {%{
             balance_snapshot: balance_snapshot,
             account_status: "active",
             entitlement_mode: :metered,
             entitlement_policy: Policy.default()
           }, false}
        end
    end
  end

  defp enforce_mode?(attrs), do: normalize_mode(Map.get(attrs, :mode, :shadow)) == :enforce

  defp repo_query?(attrs) do
    repo = attrs[:repo] || Application.get_env(:billing_core, :repo, BillingCore.Repo)
    attrs[:repo] || (is_atom(repo) and Process.whereis(repo) != nil)
  end

  defp repo_availability(attrs) do
    repo = attrs[:repo] || Application.get_env(:billing_core, :repo, BillingCore.Repo)
    sql = attrs[:sql_runner] || Ecto.Adapters.SQL
    account_id = Map.fetch!(attrs, :billing_account_id)
    checked_at = checked_at(attrs)

    account_status =
      sql.query!(
        repo,
        """
        SELECT status
        FROM billing_accounts
        WHERE id = $1
        LIMIT 1
        """,
        [account_id]
      )
      |> case do
        %{rows: [[status] | _]} when status in ["active", "inactive", "suspended"] -> status
        _ -> "missing"
      end

    result =
      sql.query!(
        repo,
        """
        SELECT
          COALESCE(SUM(GREATEST(remaining_credits, 0)), 0),
          COALESCE(jsonb_agg(policy_snapshot) FILTER (WHERE policy_snapshot IS NOT NULL), '[]'::jsonb)
        FROM credit_grants
        WHERE billing_account_id = $1
          AND status = 'active'
          AND valid_from <= $2
          AND (expires_at IS NULL OR expires_at > $2)
        """,
        [account_id, checked_at]
      )

    balance =
      case result.rows do
        [[balance, _policies] | _] -> normalize_number(balance)
        [[balance] | _] -> normalize_number(balance)
        [] -> 0
        _ -> 0
      end

    policies =
      case result.rows do
        [[_balance, policies] | _] when is_list(policies) -> normalize_policies(policies)
        [[_balance, policies] | _] when is_binary(policies) -> decode_policies(policies)
        _ -> []
      end

    entitlement_policy = Policy.merge_active(policies)

    %{
      balance_snapshot: balance,
      account_status: account_status,
      entitlement_mode: Policy.usage_mode(entitlement_policy),
      entitlement_policy: entitlement_policy
    }
  end

  defp result(attrs, snapshot, cache_hit, query_performed, duration, age_ms, ttl_ms) do
    estimated_credits = Map.get(attrs, :estimated_credits, 0)
    mode = normalize_mode(Map.get(attrs, :mode, :shadow))

    balance_snapshot =
      Map.get(snapshot, :balance_snapshot, Map.get(snapshot, "balance_snapshot", 0))

    account_status =
      Map.get(snapshot, :account_status, Map.get(snapshot, "account_status", "active"))

    entitlement_policy =
      Map.get(
        snapshot,
        :entitlement_policy,
        Map.get(snapshot, "entitlement_policy", Policy.default())
      )

    entitlement_mode =
      Map.get(
        snapshot,
        :entitlement_mode,
        Map.get(snapshot, "entitlement_mode", Policy.usage_mode(entitlement_policy))
      )
      |> normalize_entitlement_mode()

    reason = reason(account_status, entitlement_mode, balance_snapshot, estimated_credits)
    would_block = reason in ["missing_account", "account_inactive", "insufficient_credits"]
    allowed? = mode == :shadow or not would_block

    %Decision{
      decision_id: Map.get(attrs, :decision_id) || id("decision"),
      billing_account_id: Map.get(attrs, :billing_account_id),
      mode: mode,
      allowed?: allowed?,
      would_block: would_block,
      reason: reason,
      resource_kind: Map.get(attrs, :resource_kind),
      action: Map.get(attrs, :action),
      cache_hit: cache_hit,
      cache_age_ms: age_ms,
      cache_ttl_ms: ttl_ms,
      query_performed: query_performed,
      query_duration_ms: duration,
      balance_snapshot: balance_snapshot,
      entitlement_mode: entitlement_mode,
      entitlement_policy: entitlement_policy,
      provider: Map.get(attrs, :provider),
      sku: Map.get(attrs, :sku),
      checked_at: checked_at(attrs)
    }
  end

  @doc false
  def cache_key(attrs) do
    if Map.has_key?(attrs, :resource_kind) or Map.has_key?(attrs, :action) or
         Map.has_key?(attrs, :mode) do
      {
        Map.fetch!(attrs, :billing_account_id),
        Map.get(attrs, :resource_kind, :unknown),
        Map.get(attrs, :action, :unknown),
        Map.get(attrs, :provider),
        Map.get(attrs, :sku),
        normalize_mode(Map.get(attrs, :mode, :shadow)),
        Map.get(attrs, :policy_cache_version, 0)
      }
    else
      {Map.fetch!(attrs, :billing_account_id), Map.get(attrs, :provider), Map.get(attrs, :sku)}
    end
  end

  defp state_availability(%{state: %State{} = state} = attrs) do
    account_id = Map.fetch!(attrs, :billing_account_id)
    at = checked_at(attrs)

    %{
      balance_snapshot: Credits.available_credits(state.grants, account_id, at),
      account_status: Map.get(attrs, :account_status, "active"),
      entitlement_policy:
        state.grants
        |> Credits.active_policies(account_id, at)
        |> Policy.merge_active()
    }
  end

  defp reason("missing", _entitlement_mode, _balance, _estimated), do: "missing_account"

  defp reason(status, _entitlement_mode, _balance, _estimated) when status != "active",
    do: "account_inactive"

  defp reason(_status, :unlimited_metered, _balance, _estimated), do: "allowed_unlimited"

  defp reason(_status, _entitlement_mode, balance, estimated) when estimated > balance,
    do: "insufficient_credits"

  defp reason(_status, _entitlement_mode, _balance, _estimated), do: "allowed"

  defp checked_at(attrs) do
    attrs[:checked_at] || attrs[:metered_at] || DateTime.utc_now()
  end

  defp normalize_mode(:enforce), do: :enforce
  defp normalize_mode("enforce"), do: :enforce
  defp normalize_mode(_mode), do: :shadow

  defp normalize_entitlement_mode(:unlimited_metered), do: :unlimited_metered
  defp normalize_entitlement_mode("unlimited_metered"), do: :unlimited_metered
  defp normalize_entitlement_mode(_mode), do: :metered

  defp normalize_number(%Decimal{} = value), do: Decimal.to_integer(value)
  defp normalize_number(value) when is_integer(value), do: value
  defp normalize_number(value) when is_float(value), do: floor(value)
  defp normalize_number(_value), do: 0

  defp decode_policies(value) do
    case Jason.decode(value) do
      {:ok, policies} when is_list(policies) -> normalize_policies(policies)
      _ -> []
    end
  end

  defp normalize_policies(policies) do
    policies
    |> Enum.map(&normalize_policy/1)
    |> Enum.filter(&is_map/1)
  end

  defp normalize_policy(%{} = policy), do: policy

  defp normalize_policy(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = policy} -> policy
      _ -> nil
    end
  end

  defp normalize_policy(_value), do: nil

  defp id(prefix),
    do: prefix <> "_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
end
