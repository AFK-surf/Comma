defmodule SalixWeb.LLMProxy do
  @moduledoc false

  alias Salix.Control.Groups
  alias SalixAgent.{Control, LLMMetering, Templates}

  @transport_timeout_grace_ms 1_000

  @doc "Resolve an existing current Router and its actual template; never fall back."
  def resolve_project_router_llm(agent_id) do
    with {:ok, agent} <- Control.get(agent_id),
         {:ok, group} <- Groups.get(agent["group_id"], agent["tenant_id"]),
         true <- group["router_agent_id"] == agent_id,
         {:ok, template_id, _source} <- Templates.resolve_template_id_for_record(agent),
         {:ok, llm} when is_map(llm) <-
           Templates.resolve_llm_for_template(template_id, agent["tenant_id"]) do
      {:ok, Map.put(llm, "template_id", template_id)}
    else
      _ -> {:error, :project_router_template_unavailable}
    end
  end

  @spec resolve_llm(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def resolve_llm(agent_id) do
    case Templates.resolve_llm_for_agent(agent_id) do
      {:ok, llm} when is_map(llm) -> {:ok, llm}
      {:error, _} = error -> error
      _ -> default_llm()
    end
  end

  defp default_llm do
    case Application.get_env(:comma_core, :default_agent_template) do
      tmpl when is_map(tmpl) ->
        llm =
          (tmpl["provider_config"] || %{})
          |> Map.put("model", tmpl["model"])
          |> Map.put("max_tokens", tmpl["max_tokens"])
          |> Map.put("context_tokens", tmpl["context_tokens"])
          |> Map.put("credential_scope", "platform")

        {:ok, llm}

      _ ->
        {:ok, nil}
    end
  end

  @spec complete(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(agent_id, llm, req, opts \\ %{}) when is_map(llm) and is_map(req) do
    opts = Map.new(opts)
    proxy_req = build_req(agent_id, llm, req, opts)

    # This closure runs after billing authorization. Recompute an absolute
    # deadline here so a slow metering preflight cannot start a provider call
    # with a stale full timeout.
    call = fn -> provider_call(llm, proxy_req, opts) end

    if opts[:skip_metering] == true and opts[:require_billing_owner] != true do
      call.()
    else
      complete_metered(agent_id, llm, opts, call)
    end
  end

  @doc false
  def metered(ctx, call) when is_map(ctx) and is_function(call, 0) do
    case LLMMetering.before_llm_call(ctx) do
      {:error, {:billing_unavailable, _decision}} = err ->
        err

      _ ->
        finish_metered(ctx, call)
    end
  end

  defp complete_metered(agent_id, llm, opts, call) do
    case {opts[:require_billing_owner], opts[:provider_deadline_ms]} do
      {true, _} ->
        ctx = meter_context(agent_id, llm, opts)

        with :ok <- require_billing_owner(ctx) do
          case LLMMetering.before_llm_call(ctx) do
            :ok -> finish_metered(ctx, call)
            {:ok, _} -> finish_metered(ctx, call)
            {:error, _} = error -> error
            _ -> {:error, :billing_authorization_failed}
          end
        end

      {_, deadline} when is_integer(deadline) ->
        with {:ok, ctx} <- metering_preflight_before_deadline(agent_id, llm, opts, deadline) do
          finish_metered(ctx, call)
        end

      _ ->
        metered(meter_context(agent_id, llm, opts), call)
    end
  end

  defp require_billing_owner(ctx) do
    if Enum.all?(
         [
           :billing_account_id,
           :product_owner_type,
           :product_owner_id,
           :salix_tenant_id,
           :salix_group_id,
           :charge_policy
         ],
         fn key ->
           is_binary(ctx[key]) and String.trim(ctx[key]) != ""
         end
       ), do: :ok, else: {:error, :billing_owner_missing}
  end

  defp metering_preflight_before_deadline(agent_id, llm, opts, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 ->
        run_provider_call(
          fn ->
            ctx = meter_context(agent_id, llm, opts)

            case LLMMetering.before_llm_call(ctx) do
              {:error, {:billing_unavailable, _decision}} = error -> error
              _ -> {:ok, ctx}
            end
          end,
          remaining
        )

      _ ->
        {:error, :provider_timeout}
    end
  end

  defp finish_metered(ctx, call) do
    started = System.monotonic_time(:millisecond)
    result = safe_provider_call(call)

    {usage, status, reason} =
      case result do
        {:ok, resp} when is_map(resp) -> {resp["usage"], "ok", nil}
        {:ok, resp} -> {nil, "error", {:unexpected_response, resp}}
        {:error, reason} -> {nil, "error", reason}
        _ -> {nil, "error", :unexpected_result}
      end

    _ = LLMMetering.after_llm_call(meter_result(ctx, usage, started, status, reason))
    result
  end

  @doc false
  def run_provider_call(call, timeout_ms)
      when is_function(call, 0) and is_integer(timeout_ms) and timeout_ms > 0 do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_provider_call(call)
        send(parent, {result_ref, self(), result})
      end)

    receive do
      {^result_ref, ^pid, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        receive do
          {^result_ref, ^pid, result} -> result
        after
          0 -> {:error, {:provider_exit, reason}}
        end
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        await_provider_down(monitor_ref, pid)
        flush_provider_result(result_ref, pid)
        {:error, :provider_timeout}
    end
  end

  def run_provider_call(call, _timeout_ms) when is_function(call, 0),
    do: safe_provider_call(call)

  defp await_provider_down(monitor_ref, pid) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp flush_provider_result(result_ref, pid) do
    receive do
      {^result_ref, ^pid, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp safe_provider_call(call) do
    call.()
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp transport_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms + @transport_timeout_grace_ms

  defp transport_timeout(_timeout_ms), do: nil

  defp provider_call(llm, proxy_req, opts) do
    case provider_timeout(opts) do
      :expired ->
        {:error, :provider_timeout}

      timeout_ms ->
        raw_call = fn ->
          SalixLlm.SiteProxy.complete(llm, proxy_req,
            # The monitor below owns the provider deadline. Keep Req's
            # transport timer slightly outside it so a per-transport timeout
            # cannot win the race and expose a different boundary result.
            receive_timeout: transport_timeout(timeout_ms),
            retry: Map.get(opts, :provider_retry, :transient)
          )
        end

        run_provider_call(raw_call, timeout_ms)
    end
  end

  defp provider_timeout(opts) do
    case opts[:provider_deadline_ms] do
      deadline when is_integer(deadline) ->
        case deadline - System.monotonic_time(:millisecond) do
          remaining when remaining > 0 -> remaining
          _ -> :expired
        end

      _ ->
        opts[:provider_timeout_ms]
    end
  end

  defp build_req(agent_id, llm, req, opts) do
    %{
      model: llm["model"],
      prompt_cache_key: agent_id,
      messages: req["messages"],
      max_tokens: clamp(req["max_tokens"], opts[:max_tokens_cap], llm["max_tokens"]),
      temperature: req["temperature"],
      top_p: req["top_p"]
    }
  end

  defp clamp(client, api_cap, template_cap) do
    mt = if is_integer(client), do: client, else: 0
    mt |> clamp_to(api_cap) |> clamp_to(template_cap)
  end

  defp clamp_to(mt, cap) when is_integer(cap) and cap > 0 do
    if mt <= 0 or mt > cap, do: cap, else: mt
  end

  defp clamp_to(mt, _cap), do: mt

  defp meter_context(agent_id, llm, opts) do
    %{
      entrypoint: opts[:entrypoint] || "llm_proxy",
      actor_type: opts[:actor_type] || "system",
      agent_id: agent_id,
      salix_agent_id: agent_id,
      provider: llm["provider"] || infer_provider_type(llm["base_url"]),
      credential_scope: llm["credential_scope"],
      model: llm["model"],
      started_at_ms: System.system_time(:millisecond)
    }
    |> Map.merge(billing_owner(agent_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp billing_owner(agent_id) do
    with {:ok, agent} <- Control.get(agent_id),
         {:ok, group} <- Groups.get(agent["group_id"], agent["tenant_id"]),
         owner when is_map(owner) <- group["billing_owner"] do
      %{
        billing_account_id: owner["billing_account_id"],
        surface: owner["surface"],
        product_owner_type: owner["product_owner_type"],
        product_owner_id: owner["product_owner_id"],
        tenant_id: owner["salix_tenant_id"] || agent["tenant_id"],
        group_id: owner["salix_group_id"] || agent["group_id"],
        salix_tenant_id: owner["salix_tenant_id"] || agent["tenant_id"],
        salix_group_id: owner["salix_group_id"] || agent["group_id"],
        charge_policy: owner["charge_policy"]
      }
    else
      _ -> %{tenant_id: nil, group_id: nil, quality: ["billing_owner_missing"]}
    end
  end

  defp meter_result(ctx, usage, started, status, reason) do
    ctx
    |> Map.merge(%{
      status: status,
      duration_ms: System.monotonic_time(:millisecond) - started,
      completed_at_ms: System.system_time(:millisecond),
      response_kind: "site_proxy",
      usage: normalize_usage(usage),
      error: if(reason, do: inspect(reason))
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_usage(nil), do: %{}

  defp normalize_usage(usage) when is_map(usage) do
    %{
      "prompt_tokens" => usage["prompt_tokens"] || 0,
      "completion_tokens" => usage["completion_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0,
      "cache_read_input_tokens" => get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
      "cache_write_input_tokens" => usage["cache_creation_input_tokens"] || 0
    }
  end

  defp normalize_usage(_usage), do: %{}

  defp infer_provider_type(base_url) do
    u = base_url |> to_string() |> String.trim() |> String.downcase()

    cond do
      String.contains?(u, "anthropic.com") -> "anthropic"
      String.contains?(u, "generativelanguage.googleapis.com") -> "gemini"
      String.contains?(u, "x.ai") -> "xai"
      String.contains?(u, "groq.com") -> "groq"
      true -> "openai"
    end
  end
end
