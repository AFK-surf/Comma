defmodule SalixIM.Provider do
  @moduledoc """
  Production backend for IM provider discovery and dynamic operations.

  Scope resolution is `agent_id -> agent -> group_id`. The fixed internal
  connect is always visible. External connects come from group-scoped
  `ctl/im_connects/<group>/...` records and are visible only to roles that are
  allowed to use external provider APIs. Routers see every external provider;
  workers normally see Slack read operations and `slack.fetch_file` through
  router-bound connects. A current Task execution scope can also expose its
  exact granted IM writes. Both discovery and dispatch validate that scope;
  every other role sees no external provider.

  This module is the public provider-tool facade. Concrete provider manuals and
  outbound transports live in `SalixIM.Provider.*` modules.
  """

  require Logger

  alias SalixIM.Provider.{Feishu, Internal, Manuals, OperationRegistry, Slack, Telegram, WeChat}
  alias SalixIM.{GroupDirectory, ProviderConnects}

  @internal_connect_id "internal"

  def task_execution_request(name, args, context) do
    case SalixIM.TaskExecution.ifc_request(name, args, context) do
      :none -> SalixIM.TaskContinuation.ifc_request(name, args, context)
      authority -> authority
    end
  end

  # Role-based access remains separate from the exact Task execution scope.
  @worker_external_providers ["slack"]

  # Non-mutating media downloads explicitly granted to workers beyond the
  # `safety: read` class. Uploads and any other non-read operation — including
  # newly added ones — fail closed without per-operation role labeling.
  @worker_media_downloads %{"slack" => ["slack.fetch_file"]}

  # ---- connects ----

  def list_connects(agent_id) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id),
         do: list_connects_in_scope(scope, [])
  end

  def list_connects(agent_id, context) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id),
         do: list_connects_in_scope(scope, SalixIM.TaskExecution.requests(scope, context))
  end

  @doc "Resolve one activation's IM catalog with one Agent scope and Task authorization read."
  def discovery_catalog(agent_id, context) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id) do
      requests = SalixIM.TaskExecution.requests(scope, context)

      with {:ok, connects} <- list_connects_in_scope(scope, requests) do
        manuals =
          connects
          |> Enum.map(& &1["provider"])
          |> Enum.uniq()
          |> Enum.flat_map(fn provider ->
            case manual_with_requests(provider, scope, requests) do
              {:ok, manual} -> [{provider, manual}]
              _ -> []
            end
          end)
          |> Map.new()

        {:ok, %{connects: connects, manuals: manuals}}
      end
    end
  end

  defp list_connects_in_scope(scope, requests) do
    with {:ok, connects} <-
           ProviderConnects.list_tool_connects(
             scope.group_id,
             visible_external_providers(scope),
             scope.agent_id,
             agent_role(scope)
           ) do
      delegated =
        requests
        |> Enum.group_by(&{&1["connect_id"], &1["provider"]})
        |> Enum.flat_map(fn {{id, provider}, requests} ->
          case ProviderConnects.get_delegatable_connect_by_id(scope.group_id, id, provider) do
            {:ok, connect} ->
              [
                connect
                |> ProviderConnects.delegated_tool_summary()
                |> Map.put(
                  "task_execution_requests",
                  Enum.map(requests, &Map.take(&1, ~w(api params)))
                )
              ]

            _ ->
              []
          end
        end)

      {:ok, Enum.uniq_by(delegated ++ [internal_connect() | connects], & &1["connect_id"])}
    end
  end

  defp internal_connect, do: %{"connect_id" => @internal_connect_id, "provider" => "internal"}

  @doc "Providers with group-owned operations that do not require a selected connect."
  def group_providers(agent_id) do
    with {:ok, _scope} <- GroupDirectory.scope_for_agent(agent_id), do: {:ok, ["slack"]}
  end

  # ---- manuals/contracts ----

  def provider_manual(platform), do: Manuals.manual(platform)

  # Agent-aware manual used by discovery surfaces. Non-router agents get the
  # manual only for providers they can see, with external apis filtered to the
  # granted worker operations; the dispatch fence below applies the same grant
  # regardless of disclosure.
  def provider_manual(platform, agent_id) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id) do
      manual_with_requests(to_string(platform), scope, [])
    end
  end

  def provider_manual(platform, agent_id, context) do
    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id) do
      manual_with_requests(
        to_string(platform),
        scope,
        SalixIM.TaskExecution.requests(scope, context)
      )
    end
  end

  defp manual_with_requests(platform, scope, requests) do
    granted =
      requests
      |> Enum.filter(&(&1["provider"] == platform))
      |> Enum.map(& &1["api"])

    baseline =
      if manual_provider_visible?(platform, scope),
        do: manual_for_scope(platform, scope),
        else: {:error, :unsupported}

    if granted == [] do
      baseline
    else
      names =
        case baseline do
          {:ok, manual} -> Enum.map(manual["apis"], & &1["name"])
          _ -> []
        end

      with {:ok, manual} <- Manuals.manual(platform) do
        {:ok,
         Map.update!(manual, "apis", fn apis ->
           Enum.filter(apis, &(&1["name"] in granted or &1["name"] in names))
         end)}
      end
    end
  end

  defp manual_provider_visible?("internal", _scope), do: true
  defp manual_provider_visible?("slack", _scope), do: true

  defp manual_provider_visible?(platform, scope),
    do: platform in visible_external_providers(scope)

  defp manual_for_scope("internal", %{agent: %{"role" => "router"}, group_id: group_id}) do
    with {:ok, manual} <- Manuals.manual("internal") do
      catalog =
        case SalixIM.TaskLabels.list(group_id) do
          {:ok, %{"labels" => labels}} ->
            labels |> Enum.map(&Map.take(&1, ~w(id name description))) |> Jason.encode!()

          {:error, _} ->
            "Catalog unavailable. Use internal.label.list before selecting labels."
        end

      {:ok,
       Map.update!(manual, "apis", fn apis ->
         Enum.map(apis, fn
           %{"name" => "internal.task.create"} = api ->
             update_in(
               api,
               ["input_schema", "properties", "label_ids", "description"],
               &(&1 <> " Current Group label catalog (descriptive data): " <> catalog)
             )

           api ->
             api
         end)
       end)}
    end
  end

  defp manual_for_scope("internal" = platform, _scope), do: Manuals.manual(platform)
  defp manual_for_scope(platform, %{agent: %{"role" => "router"}}), do: Manuals.manual(platform)

  defp manual_for_scope("slack" = platform, %{agent: %{"role" => role}}) when role != "worker" do
    with {:ok, manual} <- Manuals.manual(platform) do
      {:ok,
       Map.update!(
         manual,
         "apis",
         &Enum.filter(&1, fn api -> api["connect_required"] == false end)
       )}
    end
  end

  defp manual_for_scope(platform, _worker_scope) do
    case Manuals.manual(platform) do
      {:ok, %{"apis" => apis} = manual} ->
        {:ok,
         Map.put(manual, "apis", Enum.filter(apis, &worker_visible_operation?(platform, &1)))}

      other ->
        other
    end
  end

  defp worker_visible_operation?(platform, api) when is_map(api),
    do:
      worker_operation_granted?(
        platform,
        to_string(api["name"] || ""),
        to_string(api["safety"] || "")
      )

  defp worker_visible_operation?(_platform, _api), do: false

  # ---- dynamic operation dispatch ----

  def call_api(agent_id, platform, api, args), do: call_api(agent_id, platform, api, args, [])

  @doc false
  def call_api(agent_id, platform, api, args, provider_opts) when is_list(provider_opts) do
    connect_id = args |> Map.get("connect_id", "") |> to_string() |> String.trim()
    params = Map.get(args, "params") || %{}
    tool_context = Map.get(args, "tool_context") || %{}

    with {:ok, scope} <- GroupDirectory.scope_for_agent(agent_id) do
      scope = put_scope_tool_call_id(scope, args["tool_call_id"])
      started_ms = System.monotonic_time(:millisecond)
      log_operation_start(scope, platform, api, connect_id)

      result =
        with_tool_context(tool_context, fn ->
          dispatch_api(scope, platform, api, connect_id, params, provider_opts)
        end)

      log_operation_finish(result, started_ms, scope, platform, api, connect_id)
      result
    end
  end

  def current_tool_context do
    Process.get(:salix_im_provider_tool_context) || %{}
  end

  defp with_tool_context(tool_context, fun) do
    previous = Process.get(:salix_im_provider_tool_context)
    Process.put(:salix_im_provider_tool_context, tool_context || %{})

    try do
      fun.()
    after
      if is_nil(previous),
        do: Process.delete(:salix_im_provider_tool_context),
        else: Process.put(:salix_im_provider_tool_context, previous)
    end
  end

  defp dispatch_api(scope, platform, api, connect_id, params, provider_opts) do
    case platform do
      "internal" ->
        if connect_id == @internal_connect_id do
          Internal.call(scope, api, params)
        else
          {:error, "connect not found"}
        end

      "slack" when api in ["slack.message_search", "slack.semantic_search"] ->
        Slack.MessageSearch.search(
          scope,
          connect_id,
          params,
          if(api == "slack.semantic_search", do: "semantic", else: "hybrid")
        )

      "slack" ->
        call_external(scope, connect_id, "slack", api, params, fn connect ->
          Slack.call(scope, scope.tenant_id, connect, api, params, provider_opts)
        end)

      "wechat" ->
        call_external(scope, connect_id, "wechat", api, params, fn connect ->
          WeChat.call(scope.agent_id, connect, api, params)
        end)

      "telegram" ->
        call_external(scope, connect_id, "telegram", api, params, fn connect ->
          if api == "telegram.open_task_topic",
            do: SalixIM.TelegramTaskTopics.open(scope, connect, params),
            else: Telegram.call(scope.agent_id, connect, api, params)
        end)

      "imessage" ->
        call_external(scope, connect_id, "imessage", api, params, fn connect ->
          SalixIM.Provider.IMessage.call(scope.agent_id, connect, api, params)
        end)

      "signal" ->
        call_external(scope, connect_id, "signal", api, params, fn connect ->
          SalixIM.Provider.Signal.call(scope.agent_id, connect, api, params)
        end)

      "voice" ->
        call_external(scope, connect_id, "voice", api, params, fn connect ->
          SalixIM.Provider.Voice.call(scope.agent_id, connect, api, params)
        end)

      "feishu" ->
        call_external(scope, connect_id, "feishu", api, params, fn connect ->
          with :ok <-
                 SalixIM.Provider.Feishu.MeetingActivationAuthorization.authorize(
                   scope,
                   connect,
                   api,
                   params
                 ) do
            Feishu.call(scope.agent_id, connect, api, params, scope)
          end
        end)

      _ ->
        {:error, "unsupported provider"}
    end
  end

  defp call_external(scope, connect_id, provider, api, params, fun) do
    with {:ok, connect} <- external_connect(scope, connect_id, provider, api, params),
         :ok <- triage_slack_read_source_fence(provider, api, connect) do
      fun.(connect)
      |> SalixIM.PlatformMessage.record_success(scope, connect, api, params)
    end
  end

  defp external_connect(scope, connect_id, provider, api, params) do
    baseline = baseline_external_connect(scope, connect_id, provider, api)

    case baseline do
      {:ok, _} ->
        baseline

      _ ->
        case SalixIM.TaskExecution.authorize(
               scope,
               current_tool_context(),
               provider,
               api,
               connect_id,
               params
             ) do
          {:ok, _} = allowed ->
            allowed

          denied ->
            if SalixIM.TaskExecution.active?(scope, current_tool_context()),
              do: denied,
              else: baseline
        end
    end
  end

  defp baseline_external_connect(scope, connect_id, provider, api) do
    if external_provider_visible?(scope, provider) do
      with {:ok, connect} <-
             ProviderConnects.get_agent_visible_connect_by_id(scope, connect_id, provider),
           :ok <- external_operation_fence(scope, provider, api) do
        {:ok, connect}
      else
        {:error, :not_found} -> {:error, "connect not found"}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "connect not found"}
    end
  end

  # auth.test and dispatch are separate I/O boundaries. Consume the wrapper's
  # installation snapshot here, after actual connect resolution, so a reconnect
  # cannot redirect a verified permalink read. Ordinary provider calls are unchanged.
  # Modelled in tla/salix/TriageSlackSourceRead.tla.
  defp triage_slack_read_source_fence(provider, api, connect) do
    case current_tool_context()["triage_slack_read_source"] do
      nil ->
        :ok

      pin when is_map(pin) ->
        keys = ~w(tenant_id group_id connect_id connect_generation workspace_id)

        if provider == "slack" and api in ~w(slack.get_channel_history slack.get_thread_replies) and
             Enum.sort(Map.keys(pin)) == Enum.sort(keys) and Map.take(connect, keys) == pin,
           do: :ok,
           else: {:error, "slack source installation changed before read"}

      _ ->
        {:error, "invalid slack source read context"}
    end
  end

  # The router keeps full external provider authority. Every other role may
  # dispatch only granted operations: the `safety: read` class plus the
  # explicitly enumerated non-mutating media downloads above.
  defp external_operation_fence(%{agent: %{"role" => "router"}}, _provider, _api), do: :ok

  defp external_operation_fence(_scope, provider, api) do
    case OperationRegistry.metadata(provider, api) do
      {:ok, %{"safety" => safety}} ->
        if(worker_operation_granted?(provider, api, safety),
          do: :ok,
          else: {:error, "operation is not available to this agent role"}
        )

      _non_read_or_unknown ->
        {:error, "operation is not available to this agent role"}
    end
  end

  defp worker_operation_granted?(_provider, _api, "read"), do: true

  defp worker_operation_granted?(provider, api, _other_safety),
    do: api in Map.get(@worker_media_downloads, provider, [])

  defp put_scope_tool_call_id(scope, tool_call_id) do
    case tool_call_id |> to_string() |> String.trim() do
      "" -> scope
      id -> Map.put(scope, :tool_call_id, id)
    end
  end

  defp log_operation_start(scope, provider, api, connect_id) do
    Logger.info(fn ->
      [
        "im_provider_operation_start",
        log_field("provider", provider),
        log_field("api", api),
        log_field("method", operation_metadata(provider, api, "method")),
        log_field("safety", operation_metadata(provider, api, "safety")),
        log_field("connect_id", connect_id),
        log_field("agent_id", scope.agent_id),
        log_field("group_id", scope.group_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end)
  end

  defp log_operation_finish(result, started_ms, scope, provider, api, connect_id) do
    duration_ms = System.monotonic_time(:millisecond) - started_ms

    Logger.info(fn ->
      [
        finish_event(result),
        log_field("provider", provider),
        log_field("api", api),
        log_field("method", operation_metadata(provider, api, "method")),
        log_field("safety", operation_metadata(provider, api, "safety")),
        log_field("connect_id", connect_id),
        log_field("agent_id", scope.agent_id),
        log_field("group_id", scope.group_id),
        "duration_ms=#{duration_ms}",
        result_count_field(result),
        download_bytes_field(result),
        next_cursor_field(result),
        error_class_field(result),
        error_code_field(result),
        http_status_field(result),
        retry_after_field(result)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end)
  end

  defp finish_event({:ok, _result}), do: "im_provider_operation_success"
  defp finish_event({:error, _reason}), do: "im_provider_operation_failure"

  # Keep diagnostics for the product-owned transport without exposing a tool.
  defp operation_metadata("slack", "slack.post_message", key),
    do: %{"method" => "chat.postMessage", "safety" => "write"}[key]

  defp operation_metadata(provider, api, key) do
    case OperationRegistry.metadata(provider, api) do
      {:ok, metadata} -> metadata[key]
      {:error, _reason} -> nil
    end
  end

  defp result_count_field({:ok, result}) when is_map(result) do
    Enum.find_value(
      ["channels", "users", "members", "messages", "files", "reactions", "pins", "emoji"],
      fn key ->
        case Map.get(result, key) do
          value when is_list(value) -> "result_count=#{length(value)}"
          value when is_map(value) -> "result_count=#{map_size(value)}"
          _ -> nil
        end
      end
    )
  end

  defp result_count_field(_result), do: nil

  defp download_bytes_field({:ok, %{"size" => size}}) when is_integer(size) and size >= 0,
    do: "download_bytes=#{size}"

  defp download_bytes_field(_result), do: nil

  defp next_cursor_field({:ok, result}) when is_map(result) do
    cond do
      present?(Map.get(result, "next_cursor")) -> "next_cursor=true"
      present?(Map.get(result, "next_page_token")) -> "next_page_token=true"
      true -> nil
    end
  end

  defp next_cursor_field(_result), do: nil

  defp error_class_field({:error, reason}), do: log_field("error_class", error_class(reason))
  defp error_class_field(_result), do: nil

  defp error_code_field({:error, reason}), do: log_field("error_code", error_code(reason))
  defp error_code_field(_result), do: nil

  defp http_status_field({:error, reason}) do
    case http_status(reason) do
      nil -> nil
      status -> "http_status=#{status}"
    end
  end

  defp http_status_field(_result), do: nil

  defp retry_after_field({:error, reason}) do
    case retry_after(reason) do
      nil -> nil
      retry_after -> log_field("retry_after", retry_after)
    end
  end

  defp retry_after_field(_result), do: nil

  defp error_class(reason) do
    reason = reason_text(reason)

    cond do
      String.contains?(reason, "write outcome unknown") ->
        "unknown_write_outcome"

      String.contains?(reason, "rate_limited") ->
        "rate_limited"

      String.contains?(reason, "missing_scope") ->
        "missing_scope"

      String.contains?(reason, "connect not found") ->
        "connect_not_found"

      String.contains?(reason, "OAuth-complete") ->
        "oauth_incomplete"

      String.contains?(reason, "operation is not available") ->
        "operation_role_restricted"

      String.contains?(reason, "unsupported provider") ->
        "unsupported_provider"

      String.contains?(reason, "unsupported") ->
        "unsupported_api"

      true ->
        "provider_error"
    end
  end

  defp error_code(reason) do
    reason = reason_text(reason)

    cond do
      match = Regex.run(~r/Feishu API error (?<code>\d+)/, reason, capture: ["code"]) ->
        List.first(match)

      String.contains?(reason, "write outcome unknown") ->
        "unknown_write_outcome"

      String.contains?(reason, "rate_limited") ->
        "rate_limited"

      String.contains?(reason, "missing_scope") ->
        "missing_scope"

      String.contains?(reason, "connect not found") ->
        "connect_not_found"

      String.contains?(reason, "operation is not available") ->
        "operation_role_restricted"

      String.contains?(reason, "OAuth-complete") ->
        "oauth_incomplete"

      String.contains?(reason, "unsupported provider") ->
        "unsupported_provider"

      String.contains?(reason, "unsupported") ->
        "unsupported_api"

      String.starts_with?(reason, "Slack HTTP ") ->
        "http_error"

      String.starts_with?(reason, "Feishu HTTP ") ->
        "http_error"

      true ->
        nil
    end
  end

  defp http_status(reason) do
    reason = reason_text(reason)

    cond do
      String.contains?(reason, "rate_limited") ->
        429

      match = Regex.run(~r/Slack HTTP (?<status>\d+)/, reason, capture: ["status"]) ->
        List.first(match)

      match = Regex.run(~r/Feishu HTTP (?<status>\d+)/, reason, capture: ["status"]) ->
        List.first(match)

      match =
          Regex.run(~r/Feishu API error \d+ \(HTTP (?<status>\d+)\)/, reason, capture: ["status"]) ->
        List.first(match)

      match =
          Regex.run(~r/Feishu write outcome unknown after HTTP (?<status>\d+)/, reason,
            capture: ["status"]
          ) ->
        List.first(match)

      true ->
        nil
    end
  end

  defp retry_after(reason) do
    reason = reason_text(reason)

    case Regex.run(~r/retry_after=(?<retry_after>[A-Za-z0-9_.:,+-]+)/, reason,
           capture: ["retry_after"]
         ) do
      [retry_after] -> retry_after
      _ -> nil
    end
  end

  defp log_field(_key, nil), do: nil
  defp log_field(_key, ""), do: nil
  defp log_field(key, value), do: "#{key}=#{safe_log_value(value)}"

  defp safe_log_value(value) do
    value
    |> reason_text()
    |> String.replace(~r/[^A-Za-z0-9_.:,+-]/, "_")
  end

  defp reason_text(value) when is_binary(value), do: value
  defp reason_text(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp reason_text(value), do: inspect(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp visible_external_providers(%{agent: %{"role" => "router"}}),
    do: Manuals.external_providers()

  defp visible_external_providers(%{agent: %{"role" => "worker"}}),
    do: @worker_external_providers

  defp visible_external_providers(_scope), do: []

  defp external_provider_visible?(scope, provider),
    do: provider in visible_external_providers(scope)

  defp agent_role(%{agent: %{"role" => role}}) when is_binary(role),
    do: String.trim(role)

  defp agent_role(_scope), do: ""
end
