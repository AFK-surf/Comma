defmodule BillingCore.LLMMetering do
  @moduledoc """
  Production LLM metering adapter used by SalixAgent.LLMMetering.

  Production calls hand off usage to a bounded ETS buffer without waiting for
  ClickHouse or charging. Graceful shutdown drains within the worker budget.
  Crashes can lose buffered usage. Retries retain the same billing source key.
  """

  def before_llm_call(fact) when is_map(fact) do
    account_id = billing_account_id(fact)

    if present?(account_id) and not tenant_funded?(fact) do
      with {:ok, free?} <- free_router_call?(fact),
           result <-
             BillingCore.FeeControl.authorize(%{
               billing_account_id: account_id,
               resource_kind: :llm,
               action: :start,
               provider: provider(fact),
               sku: sku(fact),
               mode: :enforce,
               repo: fact[:repo] || fact["repo"],
               sql_runner: fact[:sql_runner] || fact["sql_runner"],
               estimated_credits:
                 if(free?,
                   do: 0,
                   else: max(fact[:estimated_credits] || fact["estimated_credits"] || 1, 1)
                 ),
               typed_sink: fact[:fee_control_typed_sink] || fact["fee_control_typed_sink"],
               row_context: fee_context(fact),
               source: "llm_metering",
               source_key: "fee:llm:#{source_key(fact)}",
               force_refresh:
                 fact[:force_refresh] || fact["force_refresh"] || fee_env(:force_refresh),
               probe: fact[:probe] || fact["probe"],
               probe_rate: fact[:probe_rate] || fact["probe_rate"] || fee_env(:probe_rate)
             }) do
        case result do
          {:ok, %{allowed?: true} = decision} when free? ->
            {:ok, Map.put(decision, :billing_exemption, "free_router_model")}

          {:ok, %{allowed?: true} = decision} ->
            {:ok, decision}

          {:ok, decision} ->
            {:error, {:billing_unavailable, decision}}

          error ->
            error
        end
      end
    else
      :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  def after_llm_call(fact) when is_map(fact) do
    row = usage_row(fact)

    if match?(%BillingCore.State{}, fact[:state] || fact["state"]) do
      deliver(row, fact)
    else
      SalixAnalytics.TypedSinkWorker.enqueue([%{row: row, fact: delivery_fact(fact)}],
        server: BillingCore.Metering.LLMUsageWorker
      )
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def usage_row(fact), do: SalixAnalytics.LLMCallEvent.build(row_attrs(fact))

  @doc false
  def deliver(row, fact) do
    with {:ok, _} <- sink(fact).insert([row]), do: charge(fact)
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # Only billing facts enter the queue. Never buffer credentials,
  # provider options, content, runtime modules, or caller process state.
  defp delivery_fact(fact) do
    %{
      billing_account_id: billing_account_id(fact),
      source_key: source_key(fact),
      provider: provider(fact),
      sku: sku(fact),
      metered_at: metered_at(fact),
      usage:
        Map.new(usage_components(fact), fn component ->
          {component.component, component.quantity}
        end),
      surface: surface(fact),
      product_owner_type: product_owner_type(fact),
      product_owner_id: product_owner_id(fact),
      tenant_id: tenant_id(fact),
      group_id: group_id(fact),
      entrypoint: entrypoint(fact),
      actor_type: actor_type(fact),
      tenant_account_pool: tenant_funded?(fact),
      billing_exemption: fact[:billing_exemption]
    }
    |> Map.update!(:usage, fn usage ->
      %{
        prompt_tokens:
          Map.get(usage, :input, 0) + Map.get(usage, :cache_read, 0) +
            Map.get(usage, :cache_write, 0),
        completion_tokens: Map.get(usage, :output, 0),
        cache_read_input_tokens: Map.get(usage, :cache_read, 0),
        cache_write_input_tokens: Map.get(usage, :cache_write, 0)
      }
    end)
  end

  defp charge(fact) do
    account_id = billing_account_id(fact)
    state = fact[:state] || fact["state"]

    cond do
      fact[:billing_exemption] == "free_router_model" or tenant_funded?(fact) ->
        :ok

      not present?(account_id) ->
        :ok

      match?(%BillingCore.State{}, state) ->
        BillingCore.Charges.charge_meter_event(%{
          state: state,
          resource_kind: :llm,
          billing_account_id: account_id,
          source_key: source_key(fact),
          provider: provider(fact),
          sku: sku(fact),
          metered_at: metered_at(fact),
          meter_components: usage_components(fact),
          typed_sink: fact[:charge_typed_sink] || fact["charge_typed_sink"],
          owner_snapshot: owner_snapshot(fact),
          surface: surface(fact),
          product_owner_type: product_owner_type(fact),
          product_owner_id: product_owner_id(fact),
          tenant_id: tenant_id(fact),
          group_id: group_id(fact),
          entrypoint: entrypoint(fact),
          actor_type: actor_type(fact)
        })

      usage_components(fact) == [] ->
        :ok

      true ->
        BillingCore.RepoCharges.charge_meter_event(%{
          repo: fact[:repo] || fact["repo"],
          sql_runner: fact[:sql_runner] || fact["sql_runner"],
          resource_kind: "llm",
          billing_account_id: account_id,
          source_key: source_key(fact),
          provider: provider(fact),
          sku: sku(fact),
          metered_at: metered_at(fact),
          meter_components: usage_components(fact),
          owner_snapshot: owner_snapshot(fact),
          surface: surface(fact),
          product_owner_type: product_owner_type(fact),
          product_owner_id: product_owner_id(fact),
          tenant_id: tenant_id(fact),
          group_id: group_id(fact),
          entrypoint: entrypoint(fact),
          actor_type: actor_type(fact)
        })
    end
  end

  def model_key(provider, sku) do
    {normalize_provider(provider), canonical_openai_model(normalize_text(sku))}
  end

  defp free_router_call?(fact) do
    case Application.get_env(:billing_core, :llm_billing_policy) do
      nil ->
        {:ok, false}

      policy ->
        policy.free_call?(%{
          model_purpose: fact[:model_purpose],
          surface: surface(fact),
          product_owner_type: product_owner_type(fact),
          product_owner_id: product_owner_id(fact),
          billing_account_id: billing_account_id(fact),
          tenant_id: tenant_id(fact),
          salix_agent_id: fact[:salix_agent_id],
          provider: provider(fact),
          sku: sku(fact)
        })
    end
  end

  # The template resolver supplies this scope. Product request bodies cannot set it.
  defp tenant_funded?(fact) do
    fact[:tenant_account_pool] == true or fact["tenant_account_pool"] == true or
      (surface(fact) == "comma" and
         (fact[:credential_scope] || fact["credential_scope"]) == "tenant")
  end

  defp charge_status(fact, account_id) do
    cond do
      fact[:billing_exemption] == "free_router_model" -> "free_router_model"
      tenant_funded?(fact) -> "not_billable"
      present?(account_id) -> "unrated"
      true -> "unattributed"
    end
  end

  defp row_attrs(fact) do
    account_id = billing_account_id(fact)

    %{
      source: "salix_agent.llm",
      source_key: source_key(fact),
      entrypoint: entrypoint(fact),
      surface: surface(fact) || "unknown",
      billing_account_id: if(present?(account_id), do: account_id, else: "unattributed"),
      product_owner_type: product_owner_type(fact) || "unknown",
      product_owner_id: product_owner_id(fact) || "unknown",
      tenant_id: tenant_id(fact) || "unknown",
      group_id: group_id(fact) || "unknown",
      actor_type: actor_type(fact),
      provider: provider(fact),
      model: fact[:provider_model] || fact["provider_model"] || fact[:model] || fact["model"],
      sku: sku(fact),
      status: fact[:status] || fact["status"] || "ok",
      charge_status: charge_status(fact, account_id),
      usage: fact[:usage] || fact["usage"] || %{},
      trace_id: fact[:trace_id] || fact["trace_id"],
      request_id: fact[:request_id] || fact["request_id"],
      salix_agent_id:
        fact[:salix_agent_id] || fact["salix_agent_id"] || fact[:agent_id] || fact["agent_id"],
      session_id: fact[:session_id] || fact["session_id"],
      turn_id: fact[:turn_id] || fact["turn_id"],
      round_id: fact[:round_id] || fact["round_id"],
      stale: fact[:stale] || fact["stale"] || false,
      metered_at: metered_at(fact),
      duration_ms: int_field(fact, :duration_ms),
      started_at: started_at(fact),
      first_token_ms: int_field(fact, :first_token_ms),
      attempts: attempts(fact),
      response_kind: response_kind(fact),
      error_type: error_type(fact),
      http_status: http_status(fact),
      app_revision: fact[:app_revision] || fact["app_revision"],
      quality: quality(fact, account_id)
    }
  end

  defp fee_context(fact) do
    row_attrs(fact)
    |> Map.put(:resource_kind, "llm")
    |> Map.put(:source_key, "fee:llm:#{source_key(fact)}")
  end

  defp owner_snapshot(fact) do
    %{
      "billing_account_id" => billing_account_id(fact),
      "surface" => surface(fact),
      "product_owner_type" => product_owner_type(fact),
      "product_owner_id" => product_owner_id(fact),
      "salix_tenant_id" => tenant_id(fact),
      "salix_group_id" => group_id(fact)
    }
  end

  defp usage_components(fact) do
    usage = fact[:usage] || fact["usage"] || %{}
    cache_read = usage_value(usage, "cache_read_input_tokens")
    cache_write = usage_value(usage, "cache_write_input_tokens")
    input = max(usage_value(usage, "prompt_tokens") - cache_read - cache_write, 0)

    [
      {:input, input},
      {:output, usage_value(usage, "completion_tokens")},
      {:cache_read, cache_read},
      {:cache_write, cache_write}
    ]
    |> Enum.map(fn {component, quantity} ->
      %{component: component, meter_unit: :token, quantity: quantity}
    end)
    |> Enum.reject(&(&1.quantity == 0))
  end

  defp quality(fact, account_id) do
    quality =
      fact[:quality] || fact["quality"] || fact[:quality_flags] || fact["quality_flags"] || []

    if present?(account_id), do: quality, else: Enum.uniq(["billing_owner_missing" | quality])
  end

  defp source_key(fact) do
    fact[:source_key] || fact["source_key"] || fact[:request_id] || fact["request_id"] ||
      hash_source_key(fact)
  end

  defp hash_source_key(fact) do
    source =
      Map.take(fact, [
        :agent_id,
        :session_id,
        :turn_id,
        :round_id,
        :started_at_ms
      ])

    :crypto.hash(:sha256, :erlang.term_to_binary(source))
    |> Base.encode16(case: :lower)
    |> then(&("llm:" <> String.slice(&1, 0, 32)))
  end

  defp provider(fact) do
    explicit =
      fact[:provider] || fact["provider"] ||
        get_in(fact, [:billing_context, :provider]) ||
        get_in(fact, [:billing_context, "provider"]) ||
        get_in(fact, ["billing_context", :provider]) ||
        get_in(fact, ["billing_context", "provider"])

    normalize_provider(explicit) || infer_provider(fact) || "unknown"
  end

  defp infer_provider(fact) do
    base_url = normalize_text(fact[:base_url] || fact["base_url"])
    model = sku(fact)

    cond do
      contains?(base_url, "anthropic") -> "anthropic"
      contains?(base_url, "generativelanguage.googleapis.com") -> "gemini"
      contains?(base_url, "googleapis.com") -> "gemini"
      contains?(base_url, "deepseek") -> "deepseek"
      contains?(base_url, "moonshot") -> "kimi"
      contains?(base_url, "kimi") -> "kimi"
      contains?(base_url, "bigmodel") -> "glm"
      contains?(base_url, "z.ai") -> "glm"
      contains?(base_url, "openai") -> "openai"
      openai_model?(model) -> "openai"
      String.starts_with?(model, "claude-") -> "anthropic"
      String.starts_with?(model, "gemini-") -> "gemini"
      String.starts_with?(model, "deepseek-") -> "deepseek"
      String.starts_with?(model, ["kimi-", "moonshot-"]) -> "kimi"
      String.starts_with?(model, "glm-") -> "glm"
      true -> nil
    end
  end

  defp sku(fact) do
    value = fact[:sku] || fact["sku"] || fact[:model] || fact["model"]

    value
    |> normalize_text()
    |> canonical_openai_model()
    |> Kernel.||("unknown")
  end

  # Keep billed SKUs stable across the official GPT-5.6 family alias and the
  # legacy shorthand accepted by the internal template API. Canonical tier
  # names pass through unchanged; no unsupported bare Terra/Luna aliases are
  # invented here.
  defp canonical_openai_model("5.6-sol"), do: "gpt-5.6-sol"
  defp canonical_openai_model("gpt-5.6"), do: "gpt-5.6-sol"
  defp canonical_openai_model(model), do: model

  defp normalize_provider(value) do
    case normalize_text(value) do
      nil -> nil
      "google" -> "gemini"
      "google-ai" -> "gemini"
      "google_ai" -> "gemini"
      "moonshot" -> "kimi"
      "z.ai" -> "glm"
      "zai" -> "glm"
      "bigmodel" -> "glm"
      provider -> provider
    end
  end

  defp openai_model?(model) when is_binary(model) do
    String.starts_with?(model, ["gpt-", "o1", "o3", "o4", "o5"])
  end

  defp openai_model?(_), do: false

  defp contains?(nil, _needle), do: false
  defp contains?(value, needle), do: String.contains?(value, needle)

  defp normalize_text(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()
    if value == "", do: nil, else: value
  end

  defp normalize_text(_value), do: nil

  defp billing_account_id(fact), do: get_nested(fact, :billing_account_id)
  defp surface(fact), do: get_nested(fact, :surface)
  defp product_owner_type(fact), do: get_nested(fact, :product_owner_type)
  defp product_owner_id(fact), do: get_nested(fact, :product_owner_id)
  defp entrypoint(fact), do: get_nested(fact, :entrypoint) || "llm_call"
  defp actor_type(fact), do: get_nested(fact, :actor_type) || "user"

  defp tenant_id(fact),
    do:
      fact[:tenant_id] || fact["tenant_id"] || get_nested(fact, :salix_tenant_id) ||
        get_nested(fact, :tenant_id)

  defp group_id(fact),
    do:
      fact[:group_id] || fact["group_id"] || get_nested(fact, :salix_group_id) ||
        get_nested(fact, :group_id)

  defp get_nested(fact, key) do
    string_key = to_string(key)
    context = fact[:billing_context] || fact["billing_context"] || %{}
    fact[key] || fact[string_key] || context[key] || context[string_key]
  end

  defp usage_value(usage, "prompt_tokens"),
    do: usage["prompt_tokens"] || usage[:prompt_tokens] || 0

  defp usage_value(usage, "completion_tokens"),
    do: usage["completion_tokens"] || usage[:completion_tokens] || 0

  defp usage_value(usage, "cache_read_input_tokens"),
    do: usage["cache_read_input_tokens"] || usage[:cache_read_input_tokens] || 0

  defp usage_value(usage, "cache_write_input_tokens"),
    do: usage["cache_write_input_tokens"] || usage[:cache_write_input_tokens] || 0

  defp metered_at(fact) do
    fact[:metered_at] || fact["metered_at"] || fact[:completed_at] || fact["completed_at"] ||
      ms_to_datetime(fact[:completed_at_ms] || fact["completed_at_ms"]) ||
      DateTime.utc_now()
  end

  defp started_at(fact) do
    fact[:started_at] || fact["started_at"] ||
      ms_to_datetime(fact[:started_at_ms] || fact["started_at_ms"])
  end

  defp attempts(fact), do: int_field(fact, :attempts) || 1

  defp response_kind(fact) do
    case fact[:response_kind] || fact["response_kind"] do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp error_type(fact) do
    cond do
      present_text?(fact[:error_type] || fact["error_type"]) ->
        to_string(fact[:error_type] || fact["error_type"])

      present_text?(llm_error_value(fact, "category")) ->
        to_string(llm_error_value(fact, "category"))

      (fact[:status] || fact["status"]) == "error" ->
        "unknown"

      true ->
        "none"
    end
  end

  defp http_status(fact),
    do: int_field(fact, :http_status) || int_value(llm_error_value(fact, "status"))

  defp llm_error_value(fact, key) do
    error = fact[:llm_error] || fact["llm_error"] || %{}
    error[key] || error[String.to_atom(key)]
  end

  defp int_field(fact, key), do: int_value(fact[key] || fact[to_string(key)])

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int_value(_), do: nil

  defp ms_to_datetime(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)

  defp ms_to_datetime(ms) when is_binary(ms) do
    case Integer.parse(ms) do
      {int, ""} -> ms_to_datetime(int)
      _ -> nil
    end
  end

  defp ms_to_datetime(_), do: nil

  defp sink(fact) do
    fact[:typed_sink] || fact["typed_sink"] ||
      Application.get_env(:billing_core, :llm_typed_sink, SalixAnalytics.TypedSinkWorker)
  end

  defp fee_env(key), do: Application.get_env(:billing_core, :fee_control, []) |> Keyword.get(key)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp present_text?(value), do: is_binary(value) and String.trim(value) != ""
end
