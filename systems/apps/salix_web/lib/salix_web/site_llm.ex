defmodule SalixWeb.SiteLLM do
  @moduledoc """
  `POST /_api/llm/chat` — the site LLM proxy, Salix port of willow's
  `internal/api/site_llm.go` (`serveSiteLLM`).

  Flow (willow order):

    1. per-agent global Redis sliding-window rate limit (default 60 rpm,
       `_api.json` `llm.rate_limit_rpm` overrides) → 429 + `Retry-After: 60`
    2. parse the OpenAI-style request (5 MiB body cap)
    3. resolve the agent template's provider config through
       `SalixAgent.Templates`; the model ALWAYS comes from the template,
       never the client
    4. clamp `max_tokens` by `_api.json` `llm.max_tokens`, then the
       template's `max_tokens`
    5. proxy via `SalixLlm.SiteProxy` — JSON response, or SSE forwarding
       where `data: [DONE]` is sent only on clean completion (clients detect
       truncation by its absence)
    6. metering: emits an LLM provider-call fact through `SalixAgent.LLMMetering`.
  """

  import Plug.Conn

  require Logger

  alias Salix.Control.Groups
  alias SalixAgent.{Control, LLMMetering, Templates}
  alias SalixWeb.Site

  @max_body_bytes 5 * 1024 * 1024

  def serve(conn, _agent, agent_id, site_name, cfg) do
    if not SalixWeb.SiteAPI.State.allow?(agent_id, cfg.llm.rate_limit_rpm) do
      conn
      |> put_resp_header("retry-after", "60")
      |> then(&Site.site_error(&1, 429, "Rate limit exceeded"))
    else
      case read_request(conn) do
        {:error, status, message, conn} ->
          Site.site_error(conn, status, message)

        {:ok, req, conn} ->
          case Templates.resolve_llm_for_agent(agent_id) do
            {:ok, llm} when is_map(llm) ->
              proxy(conn, agent_id, site_name, cfg, llm, req)

            _ ->
              Site.site_error(conn, 500, "Internal server error")
          end
      end
    end
  end

  defp read_request(conn) do
    case Plug.Conn.read_body(conn, length: @max_body_bytes, read_length: @max_body_bytes) do
      {:more, _partial, conn} ->
        {:error, 413, "Request body too large", conn}

      {:error, _} ->
        {:error, 400, "Invalid request body", conn}

      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, %{"messages" => messages}} when is_list(messages) and messages != [] ->
            {:ok, Jason.decode!(body), conn}

          {:ok, _} ->
            {:error, 400, "Messages required", conn}

          {:error, _} ->
            {:error, 400, "Invalid request body", conn}
        end
    end
  end

  defp proxy(conn, agent_id, site_name, cfg, llm, req) do
    max_tokens = clamp_max_tokens(req["max_tokens"], cfg.llm.max_tokens, llm["max_tokens"])

    proxy_req = %{
      model: llm["model"],
      prompt_cache_key: agent_id,
      messages: req["messages"],
      max_tokens: max_tokens,
      temperature: req["temperature"],
      top_p: req["top_p"]
    }

    if req["stream"] == true do
      proxy_stream(conn, agent_id, site_name, llm, proxy_req)
    else
      proxy_sync(conn, agent_id, site_name, llm, proxy_req)
    end
  end

  # Willow: client max_tokens, clamped down by the _api.json cap and then the
  # template cap; an unset/non-positive client value adopts the caps.
  defp clamp_max_tokens(client, api_cap, template_cap) do
    mt = if is_integer(client), do: client, else: 0
    mt = clamp(mt, api_cap)
    clamp(mt, template_cap)
  end

  defp clamp(mt, cap) when is_integer(cap) and cap > 0 do
    if mt <= 0 or mt > cap, do: cap, else: mt
  end

  defp clamp(mt, _cap), do: mt

  defp proxy_sync(conn, agent_id, site_name, llm, proxy_req) do
    meter_ctx = site_meter_context(agent_id, site_name, llm)

    case authorize_llm(conn, meter_ctx) do
      :ok ->
        started = System.monotonic_time(:millisecond)

        case SalixLlm.SiteProxy.complete(llm, proxy_req) do
          {:ok, resp} ->
            _ =
              LLMMetering.after_llm_call(
                site_meter_result(meter_ctx, resp["usage"], started, "ok")
              )

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(resp))

          {:error, reason} ->
            Logger.error("site llm proxy error: #{inspect(reason)}")

            _ =
              LLMMetering.after_llm_call(
                site_meter_result(meter_ctx, nil, started, "error", reason)
              )

            Site.site_error(conn, 502, "LLM request failed")
        end

      {:error, conn} ->
        conn
    end
  end

  defp proxy_stream(conn, agent_id, site_name, llm, proxy_req) do
    meter_ctx = site_meter_context(agent_id, site_name, llm)

    case authorize_llm(conn, meter_ctx) do
      :ok ->
        started = System.monotonic_time(:millisecond)

        sse_conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")

        # Chunks arrive synchronously in this process (Req `into:` callback), so
        # the live conn threads through the process dictionary. send_chunked is
        # deferred until the first chunk so connect-time failures can still
        # return willow's 502 error page.
        Process.delete(:site_llm_stream_conn)

        on_chunk = fn chunk ->
          live = Process.get(:site_llm_stream_conn) || send_chunked(sse_conn, 200)

          case Plug.Conn.chunk(live, "data: " <> Jason.encode!(chunk) <> "\n\n") do
            {:ok, live} -> Process.put(:site_llm_stream_conn, live)
            {:error, _} -> Process.put(:site_llm_stream_conn, live)
          end
        end

        result = SalixLlm.SiteProxy.stream(llm, proxy_req, on_chunk)
        streamed_conn = Process.get(:site_llm_stream_conn)
        Process.delete(:site_llm_stream_conn)

        case {result, streamed_conn} do
          {{:ok, usage}, nil} ->
            # Stream succeeded but produced no chunks — still a success envelope.
            _ = LLMMetering.after_llm_call(site_meter_result(meter_ctx, usage, started, "ok"))
            send_done(send_chunked(sse_conn, 200))

          {{:ok, usage}, live} ->
            _ = LLMMetering.after_llm_call(site_meter_result(meter_ctx, usage, started, "ok"))
            send_done(live)

          {{:error, reason, usage}, nil} ->
            Logger.error("site llm stream error: #{inspect(reason)}")

            _ =
              LLMMetering.after_llm_call(
                site_meter_result(meter_ctx, usage, started, "error", reason)
              )

            Site.site_error(conn, 502, "LLM request failed")

          {{:error, reason, usage}, live} ->
            # Partial stream: no [DONE] (willow — clients detect truncation);
            # metering is still recorded.
            Logger.error("site llm stream accumulate error: #{inspect(reason)}")

            _ =
              LLMMetering.after_llm_call(
                site_meter_result(meter_ctx, usage, started, "error", reason)
              )

            live
        end

      {:error, conn} ->
        conn
    end
  end

  defp authorize_llm(conn, meter_ctx) do
    case LLMMetering.before_llm_call(meter_ctx) do
      {:error, {:billing_unavailable, _decision}} ->
        {:error, Site.site_error(conn, 402, "Billing unavailable")}

      _ ->
        :ok
    end
  end

  defp send_done(conn) do
    case Plug.Conn.chunk(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # ---- metering ----

  defp site_meter_context(agent_id, site_name, llm) do
    owner = site_billing_owner(agent_id)

    %{
      entrypoint: "site_llm",
      actor_type: "external_user",
      agent_id: agent_id,
      salix_agent_id: agent_id,
      site_name: site_name,
      provider: infer_provider_type(llm["base_url"]),
      credential_scope: llm["credential_scope"],
      model: llm["model"],
      started_at_ms: System.system_time(:millisecond)
    }
    |> Map.merge(owner)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp site_billing_owner(agent_id) do
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
      _ ->
        %{
          tenant_id: nil,
          group_id: nil,
          quality: ["billing_owner_missing"]
        }
    end
  end

  defp site_meter_result(ctx, usage, started, status, reason \\ nil) do
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

  defp normalize_usage(usage) do
    %{
      "prompt_tokens" => usage["prompt_tokens"] || 0,
      "completion_tokens" => usage["completion_tokens"] || 0,
      "total_tokens" => usage["total_tokens"] || 0,
      "cache_read_input_tokens" => get_in(usage, ["prompt_tokens_details", "cached_tokens"]) || 0,
      "cache_write_input_tokens" => usage["cache_creation_input_tokens"] || 0
    }
  end

  # Willow inferProviderTypeFromURL.
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
