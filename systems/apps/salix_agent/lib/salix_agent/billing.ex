defmodule SalixAgent.Billing do
  @moduledoc """
  Agent billing and resource usage public API.
  """

  alias SalixAgent.{
    Control,
    ExternalSessionStore,
    InternalSession,
    InternalSessionStore,
    Templates
  }

  alias SalixStore.{Keys, S3}

  @list_read_concurrency 8

  def put_state(agent_id, attrs, tenant_id) when is_map(attrs) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id) do
      state = nonblank(attrs["state"], "active")
      vfs_exempt = truthy_value?(attrs["vfs_billing_exempt"])
      now = now()

      rec = %{
        "agent_id" => agent_id,
        "tenant_id" => tenant_id,
        "state" => state,
        "reason" => trim(attrs["reason"]),
        "vfs_billing_exempt" => vfs_exempt,
        "heartbeat_paused" => false,
        "auto_paused_schedule_ids" => [],
        "vm_deleted" => false,
        "created_at" => now,
        "updated_at" => now
      }

      result =
        upsert_record(Keys.ctl_agent_billing_state(agent_id), rec, fn current ->
          current
          |> Map.merge(rec)
          |> Map.put("created_at", current["created_at"] || now)
        end)

      with {:ok, rec} <- result do
        {:ok, billing_state_json(rec)}
      end
    end
  end

  def get_state(agent_id, tenant_id) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id) do
      case get_record(Keys.ctl_agent_billing_state(agent_id)) do
        {:ok, rec} ->
          {:ok, billing_state_json(rec)}

        {:error, :not_found} ->
          {:ok, billing_state_json(default_billing_state(agent_id, tenant_id))}

        {:error, _} = err ->
          err
      end
    end
  end

  def list_history(agent_id, tenant_id), do: list_history(agent_id, [], tenant_id)

  def list_history(agent_id, opts, tenant_id) do
    with {:ok, agent} <- Control.get(agent_id, tenant_id),
         {:ok, limit} <- billing_history_limit(Keyword.get(opts, :limit)),
         {:ok, after_id} <- billing_history_after_id(Keyword.get(opts, :after_id)),
         {:ok, round_entries} <- agent_round_billing_entries(agent) do
      entries =
        (round_entries ++ site_llm_billing_entries(agent))
        |> Enum.sort_by(&{&1["created_at"], &1["session_id"], &1["message_id"], &1["call_kind"]})
        |> Enum.with_index(1)
        |> Enum.map(fn {entry, idx} -> Map.put(entry, "billing_id", idx) end)
        |> Enum.filter(&(&1["billing_id"] > after_id))

      page = Enum.take(entries, limit)

      {:ok,
       %{
         "data" => page,
         "next_after_id" =>
           page |> List.last(%{"billing_id" => after_id}) |> Map.get("billing_id"),
         "has_more" => length(entries) > limit
       }}
    end
  end

  def list_resource_usage_history(agent_id, tenant_id),
    do: list_resource_usage_history(agent_id, [], tenant_id)

  def list_resource_usage_history(agent_id, _opts, tenant_id) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id) do
      {:ok, %{"data" => [], "next_after_id" => 0, "has_more" => false}}
    end
  end

  defp billing_state_json(rec) do
    %{
      "state" => rec["state"] || "active",
      "auto_paused_schedule_ids" => rec["auto_paused_schedule_ids"] || [],
      "heartbeat_paused" => rec["heartbeat_paused"] == true,
      "vfs_billing_exempt" => rec["vfs_billing_exempt"] == true,
      "vm_deleted" => rec["vm_deleted"] == true
    }
  end

  defp default_billing_state(agent_id, tenant_id) do
    %{
      "agent_id" => agent_id,
      "tenant_id" => tenant_id,
      "state" => "active",
      "auto_paused_schedule_ids" => [],
      "heartbeat_paused" => false,
      "vfs_billing_exempt" => false,
      "vm_deleted" => false
    }
  end

  defp agent_round_billing_entries(agent) do
    model = Templates.snapshot_for_record(agent)["model"] || agent["model"] || ""

    provider_type =
      agent["provider_type"] || Templates.provider_type_from_config(agent["provider_config"])

    case Control.runtime_kind(agent) do
      "external" -> external_round_billing_entries(agent, model, provider_type)
      _ -> internal_round_billing_entries(agent, model, provider_type)
    end
  end

  defp internal_round_billing_entries(agent, model, provider_type) do
    case InternalSessionStore.list(agent["agent_id"]) do
      {:ok, sessions} ->
        {:ok,
         Enum.flat_map(sessions, &internal_session_billing_entries(&1, model, provider_type))}

      {:error, _} = error ->
        error
    end
  end

  defp external_round_billing_entries(agent, model, provider_type) do
    agent_id = agent["agent_id"]

    case ExternalSessionStore.list_sessions(agent_id) do
      {:ok, sessions} ->
        sessions
        |> Enum.reduce_while({:ok, []}, fn session, {:ok, entries} ->
          case ExternalSessionStore.get_session(agent_id, session_value(session, "session_id")) do
            {:ok, detail} ->
              next = external_session_billing_entries(agent, detail, model, provider_type)
              {:cont, {:ok, Enum.reverse(next, entries)}}

            {:error, _} = error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, Enum.reverse(entries)}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp internal_session_billing_entries(session, model, provider_type),
    do:
      InternalSession.query(
        session,
        :internal_session_billing_entries,
        {model, provider_type}
      )

  defp external_session_billing_entries(agent, session, model, provider_type) do
    provider_type =
      get_in(session, ["runtime", "binding", "model_provider"]) ||
        get_in(agent, ["runtime_config", "provider"]) ||
        provider_type

    session
    |> session_value("events")
    |> List.wrap()
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {event, idx} ->
      usage = external_event_usage(event)
      input = usage_prompt_tokens(usage)
      output = usage_completion_tokens(usage)

      if input + output > 0 do
        [
          %{
            "session_id" => session_value(session, "session_id"),
            "message_id" => idx,
            "step_count" => 0,
            "model" =>
              to_string_or_empty(
                session_value(event, "model") ||
                  get_in(event, ["data", "model"]) ||
                  get_in(event, ["event", "params", "turn", "model"]) ||
                  get_in(session, ["runtime", "binding", "model"]) ||
                  model
              ),
            "provider_type" => to_string_or_empty(provider_type),
            "call_kind" => "agent",
            "input_tokens" => input,
            "output_tokens" => output,
            "total_tokens" => usage_total_tokens(usage, input, output),
            "cache_read_input_tokens" => usage_cache_read_tokens(usage),
            "cache_write_input_tokens" => usage_cache_write_tokens(usage),
            "cost_micros" => 0,
            "created_at" => int_value(session_value(event, "created_at"))
          }
        ]
      else
        []
      end
    end)
  end

  defp external_event_usage(event) when is_map(event) do
    session_value(event, "usage") || get_in(event, ["data", "usage"]) ||
      get_in(event, ["event", "params", "turn", "usage"]) || %{}
  end

  defp external_event_usage(_event), do: %{}

  defp site_llm_billing_entries(agent) do
    agent["agent_id"]
    |> Keys.ctl_site_llm_billing_prefix()
    |> list_records()
    |> Enum.map(fn rec ->
      input = int_value(rec["input_tokens"])
      output = int_value(rec["output_tokens"])
      total = int_value(rec["total_tokens"])

      %{
        "session_id" => nil,
        "site_name" => rec["site_name"],
        "message_id" => 0,
        "step_count" => 0,
        "model" => to_string_or_empty(rec["model"]),
        "provider_type" => rec["provider_type"] || "openai",
        "call_kind" => "site_llm",
        "input_tokens" => input,
        "output_tokens" => output,
        "total_tokens" => if(total > 0, do: total, else: input + output),
        "cache_read_input_tokens" => int_value(rec["cache_read_input_tokens"]),
        "cache_write_input_tokens" => int_value(rec["cache_write_input_tokens"]),
        "cost_micros" => 0,
        "created_at" => int_value(rec["created_at"])
      }
    end)
  end

  defp billing_history_limit(raw) when raw in [nil, ""], do: {:ok, 100}

  defp billing_history_limit(raw) do
    case Integer.parse(String.trim(to_string(raw))) do
      {n, ""} when n > 0 and n <= 500 -> {:ok, n}
      {n, ""} when n > 500 -> {:ok, 500}
      _ -> {:error, {:bad_request, "invalid limit"}}
    end
  end

  defp billing_history_after_id(raw) when raw in [nil, ""], do: {:ok, 0}

  defp billing_history_after_id(raw) do
    case Integer.parse(String.trim(to_string(raw))) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:bad_request, "invalid after_id"}}
    end
  end

  defp int_value(v) when is_integer(v), do: v
  defp int_value(v) when is_float(v), do: trunc(v)

  defp int_value(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp int_value(_), do: 0

  defp to_string_or_empty(nil), do: ""
  defp to_string_or_empty(value) when is_binary(value), do: value
  defp to_string_or_empty(value), do: to_string(value)

  defp usage_prompt_tokens(value),
    do: int_value(msg_value(value, :prompt_tokens) || msg_value(value, :input_tokens))

  defp usage_completion_tokens(value),
    do: int_value(msg_value(value, :completion_tokens) || msg_value(value, :output_tokens))

  defp usage_total_tokens(value, input, output) do
    case int_value(msg_value(value, :total_tokens)) do
      total when total > 0 -> total
      _ -> input + output
    end
  end

  defp usage_cache_read_tokens(value) do
    int_value(
      msg_value(value, :cache_read_input_tokens) ||
        get_in(value || %{}, ["prompt_tokens_details", "cached_tokens"])
    )
  end

  defp usage_cache_write_tokens(value),
    do:
      int_value(
        msg_value(value, :cache_write_input_tokens) ||
          msg_value(value, :cache_creation_input_tokens)
      )

  defp msg_value(msg, key) when is_map(msg), do: Map.get(msg, key) || Map.get(msg, to_string(key))
  defp msg_value(_msg, _key), do: nil

  defp session_value(session, key) when is_map(session) do
    Map.get(session, key) || Map.get(session, to_string(key)) ||
      Map.get(session, String.to_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp session_value(_session, _key), do: nil

  defp list_records(prefix) do
    case S3.list_all(prefix) do
      {:ok, objects} ->
        context = SystemsObservability.Context.capture()

        objects
        |> Task.async_stream(
          fn %{key: key} ->
            SystemsObservability.Context.run(context, fn ->
              case get_record(key) do
                {:ok, rec} -> [rec]
                _ -> []
              end
            end)
          end,
          max_concurrency: @list_read_concurrency,
          ordered: true,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, records} -> records end)

      {:error, _} ->
        []
    end
  end

  defp get_record(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> Jason.decode(body)
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp upsert_record(key, new_rec, update_fun), do: upsert_record(key, new_rec, update_fun, 5)

  defp upsert_record(_key, _new_rec, _update_fun, 0), do: {:error, :precondition_failed}

  defp upsert_record(key, new_rec, update_fun, attempts) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        current = Jason.decode!(body)
        updated = update_fun.(current)

        case S3.put(key, Jason.encode!(updated), if_match: etag) do
          {:ok, _} -> {:ok, updated}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, :not_found} ->
        case S3.put(key, Jason.encode!(new_rec), if_none_match: "*") do
          {:ok, _} -> {:ok, new_rec}
          {:error, :precondition_failed} -> upsert_record(key, new_rec, update_fun, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> fallback
      text -> text
    end
  end

  defp truthy_value?(value) when value in [true, "true", "1", 1, "yes", "on"], do: true
  defp truthy_value?(_value), do: false

  defp now, do: System.system_time(:second)
end
