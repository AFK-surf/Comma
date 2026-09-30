defmodule SalixAgent.Tools.Compute do
  @moduledoc "Capability-gated tools for the current Compute Workload."

  @wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @request_id_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}\z/

  @definitions [
    {"compute.workspace.stat", "Read metadata for one relative workspace path.", :workspace_stat},
    {"compute.workspace.list", "List one bounded relative workspace directory.", :workspace_list},
    {"compute.workspace.read", "Read a bounded byte range from one workspace file.",
     :workspace_read},
    {"compute.workspace.write", "Write one bounded workspace file with an exact digest.",
     :workspace_write},
    {"compute.exec", "Run one bounded command in the current Compute Workload.", :compute_exec},
    {"process.start", "Start one long-lived process in the current Compute Workload.",
     :process_start},
    {"process.list", "List long-lived processes in the current Compute Workload.", :process_list},
    {"process.write", "Write bounded input to one current process.", :process_write},
    {"process.tail", "Read bounded output from one current process.", :process_tail},
    {"process.stop", "Stop one current long-lived process.", :process_stop},
    {"compute.build.run", "Run a bounded build in the current Compute Workload.", :build_run},
    {"compute.service.export", "Export one logical Workload endpoint.", :service_export},
    {"compute.service.import", "Import one authorized logical service endpoint.",
     :service_import},
    {"compute.route.revoke", "Revoke one exact ServiceRoute revision.", :route_revoke}
  ]

  @runtime_operations ~w(
    compute.exec
    process.start
    process.list
    process.write
    process.tail
    process.stop
    compute.build.run
  )

  def defs do
    Enum.map(@definitions, fn {name, description, operation} ->
      {name, description, schema(operation), fn args, ctx -> call(name, operation, args, ctx) end,
       @wait}
    end)
  end

  defp call(name, operation, args, ctx) do
    unless SalixAgent.PluginPolicy.allowed_tool?(ctx, name) do
      raise "compute admission is disabled for this agent snapshot"
    end

    adapter = ctx[:compute_adapter] || ctx["compute_adapter"] || SalixStore.Compute
    tenant_id = required_context(ctx, :tenant_id)
    agent_id = required_context(ctx, :agent_id)
    environment_id = required_context(ctx, :environment_id)
    grant_id = required_context(ctx, :workload_grant_id)

    with {:ok, workload} <-
           SalixStore.Compute.authorize_workload_grant(
             tenant_id,
             grant_id,
             environment_id,
             agent_id,
             permission(operation)
           ),
         {:ok, result} <-
           dispatch(
             adapter,
             operation,
             prepare_args(operation, stringify(args), ctx),
             workload.id
           ) do
      Jason.encode!(result)
    else
      false -> raise "compute is unavailable for this Workload"
      {:error, reason} -> raise "compute.#{operation} failed: #{inspect(reason)}"
    end
  end

  defp dispatch(adapter, operation, args, workload_id) do
    operation_name = operation_name(operation)

    if operation_name in @runtime_operations do
      if function_exported?(adapter, :dispatch_workload, 3),
        do: adapter.dispatch_workload(operation_name, args, workload_id),
        else: {:error, :compute_runtime_dispatch_unavailable}
    else
      if function_exported?(adapter, :call_workload, 3) do
        adapter.call_workload(operation, args, workload_id)
      else
        {:error, :compute_workspace_dispatch_unavailable}
      end
    end
  end

  defp operation_name(:workspace_stat), do: "compute.workspace.stat"
  defp operation_name(:workspace_list), do: "compute.workspace.list"
  defp operation_name(:workspace_read), do: "compute.workspace.read"
  defp operation_name(:workspace_write), do: "compute.workspace.write"
  defp operation_name(:compute_exec), do: "compute.exec"
  defp operation_name(:process_start), do: "process.start"
  defp operation_name(:process_list), do: "process.list"
  defp operation_name(:process_write), do: "process.write"
  defp operation_name(:process_tail), do: "process.tail"
  defp operation_name(:process_stop), do: "process.stop"
  defp operation_name(:build_run), do: "compute.build.run"
  defp operation_name(:service_export), do: "compute.service.export"
  defp operation_name(:service_import), do: "compute.service.import"
  defp operation_name(:route_revoke), do: "compute.route.revoke"

  defp permission(operation) when operation in [:service_export, :service_import, :route_revoke],
    do: "service_route"

  defp permission(operation)
       when operation in [
              :compute_exec,
              :process_start,
              :process_list,
              :process_write,
              :process_tail,
              :process_stop,
              :build_run
            ],
       do: "runtime"

  defp permission(_), do: "workspace"

  defp required_context(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "compute requires an exact #{key}"
    end
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  defp schema(operation) do
    required =
      case operation do
        :workspace_stat -> ~w(path)
        :workspace_list -> ~w(path)
        :workspace_read -> ~w(path)
        :workspace_write -> ~w(path expected_prefix_sha256 content_base64)
        :compute_exec -> ~w(command)
        :process_start -> ~w(command)
        :process_list -> []
        :process_write -> ~w(process_id data_base64)
        :process_tail -> ~w(process_id)
        :process_stop -> ~w(process_id)
        :build_run -> ~w(dockerfile_path image context_base64)
        :service_export -> ~w(logical_endpoint port protocol)
        :service_import -> ~w(export_id virtual_service_name route_class)
        :route_revoke -> ~w(route_id expected_revision)
      end

    base = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => Map.new(required, &{&1, %{"type" => property_type(&1)}})
    }

    base =
      if operation in [:compute_exec, :process_start] do
        base =
          put_in(base, ["properties", "command"], %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "minItems" => 1,
            "maxItems" => 64
          })

        put_in(
          base,
          ["properties", "credential_env"],
          get_in(SalixAgent.Tools.Schemas.schema("env.exec"), ["properties", "credential_env"])
        )
      else
        base
      end

    if operation == :process_start do
      put_in(base, ["properties", "request_id"], %{
        "type" => "string",
        "minLength" => 1,
        "maxLength" => 63,
        "pattern" => "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$"
      })
    else
      base
    end
  end

  defp property_type(key) when key in ~w(port expected_revision), do: "integer"
  defp property_type(_), do: "string"

  defp prepare_args(operation, args, ctx) when operation in [:compute_exec, :process_start] do
    {entries, args} = Map.pop(args, "credential_env", [])

    case SalixAgent.OAuthCredentials.resolve(required_context(ctx, :agent_id), entries) do
      {:ok, resolved} ->
        args =
          if map_size(resolved) == 0 do
            args
          else
            Map.put(
              args,
              "env",
              Enum.map(Enum.sort(resolved), fn {key, value} -> "#{key}=#{value}" end)
            )
          end

        normalize_args(operation, args, ctx)

      {:error, message} ->
        raise message
    end
  end

  defp prepare_args(operation, args, ctx), do: normalize_args(operation, args, ctx)

  defp normalize_args(:process_start, %{"request_id" => request_id} = args, _ctx)
       when is_binary(request_id) do
    if Regex.match?(@request_id_pattern, request_id) do
      args
    else
      raise "process.start request_id must be a 1-63 character opaque identifier"
    end
  end

  defp normalize_args(:process_start, args, ctx) do
    case Map.get(ctx, :tool_call_id) || Map.get(ctx, "tool_call_id") do
      tool_call_id when is_binary(tool_call_id) and tool_call_id != "" ->
        request_id =
          "tps_" <>
            (:crypto.hash(:sha256, tool_call_id) |> Base.url_encode64(padding: false))

        Map.put(args, "request_id", request_id)

      _ ->
        raise "process.start requires request_id or tool_call_id"
    end
  end

  defp normalize_args(_operation, args, _ctx), do: args
end
