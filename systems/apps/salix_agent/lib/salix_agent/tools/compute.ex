defmodule SalixAgent.Tools.Compute do
  @moduledoc "Capability-gated tools for authorized workspace Compute Workloads."

  @wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  @definitions [
    {"compute.workloads.list",
     "List one page of shared execution targets authorized for this workspace. Select workload_id for target operations. Use next_cursor as after_id for the next page.",
     :workloads_list},
    {"compute.workspace.stat", "Read metadata for one relative workspace path.", :workspace_stat},
    {"compute.workspace.list",
     "List one bounded relative workspace directory page. Use next_cursor as cursor for the next page.",
     :workspace_list},
    {"compute.workspace.read", "Read a bounded byte range from one workspace file.",
     :workspace_read},
    {"compute.workspace.write",
     "Atomically write or overwrite one workspace file under /workspace.", :workspace_write},
    {"compute.exec", "Run one bounded command in the current Compute Workload.", :compute_exec},
    {"process.start", "Start one long-lived process in the current Compute Workload.",
     :process_start},
    {"process.list", "List long-lived processes in the current Compute Workload.", :process_list},
    {"process.write", "Write bounded input to one current process.", :process_write},
    {"process.tail", "Read bounded output from one current process.", :process_tail},
    {"process.stop", "Stop one current long-lived process.", :process_stop}
  ]

  @runtime_operations ~w(
    compute.exec
    process.start
    process.list
    process.write
    process.tail
    process.stop
  )

  @workspace_operations [
    :workspace_stat,
    :workspace_list,
    :workspace_read,
    :workspace_write
  ]

  @target_help " Target Workload ID from compute.workloads.list. Never switch targets after an uncertain result."
  @workload_id_description "Target Workload ID from compute.workloads.list."

  def defs do
    Enum.map(@definitions, &build_def/1)
  end

  defp build_def({name, description, operation}) do
    entry =
      {name, description <> target_help(operation), schema(operation),
       fn args, ctx -> call(name, operation, args, ctx) end, @wait}

    if operation == :workloads_list,
      do: Tuple.insert_at(entry, tuple_size(entry), safety: "read", runtimes: [:internal]),
      else: entry
  end

  defp call(name, :workloads_list, args, ctx) do
    cond do
      not SalixAgent.PluginPolicy.allowed_tool?(ctx, name) ->
        failure(:compute_disabled)

      ctx[:runtime_kind] != :internal ->
        failure(:compute_workspace_unavailable)

      true ->
        case SalixAgent.ComputeAccess.list(ctx, stringify(args)) do
          {:ok, result} -> Jason.encode!(result)
          {:error, reason} -> failure(reason)
        end
    end
  end

  defp call(name, operation, args, ctx) do
    unless SalixAgent.PluginPolicy.allowed_tool?(ctx, name) do
      raise "compute admission is disabled for this agent snapshot"
    end

    adapter = ctx[:compute_adapter] || ctx["compute_adapter"] || SalixStore.Compute

    args = stringify(args)
    {target, args} = Map.pop(args, "workload_id")

    with {:ok, workload} <- authorize_workload(ctx, permission(operation), target),
         {:ok, prepared, secrets} <- prepare_args(operation, args, ctx),
         {:ok, result} <- dispatch(adapter, operation, prepared, workload.id) do
      result
      |> enrich_result(operation)
      |> SalixAgent.OAuthCredentials.redact(secrets)
      |> Jason.encode!()
    else
      false -> raise "compute is unavailable for this Workload"
      {:error, {:invalid_argument, message}} -> invalid_argument(message)
      {:error, reason} -> failure(reason)
    end
  end

  defp authorize_workload(ctx, permission, target) do
    with {:ok, workload} <- resolve_workload(ctx, permission, target),
         true <- target == workload.id do
      {:ok, workload}
    else
      false -> {:error, :workload_target_mismatch}
      {:error, _} = error -> error
    end
  end

  defp resolve_workload(ctx, permission, target) do
    _tenant_id = required_context(ctx, :tenant_id)
    _agent_id = required_context(ctx, :agent_id)

    if ctx[:runtime_kind] == :internal do
      if is_binary(target) and byte_size(target) in 1..128 do
        SalixAgent.ComputeAccess.authorize(ctx, target, permission)
      else
        {:error, :workload_target_required}
      end
    else
      {:error, :compute_workspace_unavailable}
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

  defp enrich_result(%{"content_base64" => b64} = result, :workspace_read) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} ->
        if String.valid?(bytes), do: Map.put(result, "content", bytes), else: result

      :error ->
        result
    end
  end

  defp enrich_result(result, operation)
       when is_map(result) and operation in [:compute_exec, :process_tail, :process_stop] do
    cond do
      result["oom_killed"] == true ->
        Map.put(
          result,
          "diagnostic",
          "Process was killed by the Linux OOM killer (SIGKILL). Reduce memory concurrency/heap size or split the task."
        )

      result["timed_out"] == true ->
        Map.put(
          result,
          "diagnostic",
          "Command reached its timeout_ms limit and the entire process group was terminated. Increase timeout_ms (up to 300000) or use process.start for long-lived commands."
        )

      true ->
        result
    end
  end

  defp enrich_result(result, _operation), do: result

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

  defp permission(operation)
       when operation in [
              :compute_exec,
              :process_start,
              :process_list,
              :process_write,
              :process_tail,
              :process_stop
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

  defp target_help(:workloads_list), do: ""
  defp target_help(_operation), do: @target_help

  defp schema(:workloads_list) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => [],
      "properties" => %{"after_id" => %{"type" => "string", "maxLength" => 128}}
    }
  end

  defp schema(operation) do
    required =
      case operation do
        :workspace_stat -> ~w(path)
        :workspace_list -> ~w(path)
        :workspace_read -> ~w(path)
        :workspace_write -> ~w(path)
        :compute_exec -> ~w(command)
        :process_start -> ~w(command)
        :process_list -> []
        :process_write -> ~w(process_id)
        :process_tail -> ~w(process_id)
        :process_stop -> ~w(process_id)
      end

    required = required ++ ["workload_id"]

    base = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" =>
        Map.new(required -- ["workload_id"], &{&1, %{"type" => "string"}})
        |> Map.put("workload_id", %{
          "type" => "string",
          "minLength" => 1,
          "maxLength" => 128,
          "description" => @workload_id_description
        })
    }

    base =
      if operation in @workspace_operations do
        path_description =
          if operation == :workspace_write do
            "Relative file path under /workspace (for example \"src/main.py\")."
          else
            "Relative path under /workspace (use \".\" for the workspace root)."
          end

        put_in(base, ["properties", "path"], %{
          "type" => "string",
          "description" => path_description
        })
      else
        base
      end

    base =
      case operation do
        :workspace_list ->
          base
          |> put_in(["properties", "limit"], %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 500,
            "description" => "Optional maximum number of entries to return (1..500, default 100)."
          })
          |> put_in(["properties", "cursor"], %{
            "type" => "string",
            "maxLength" => 1024,
            "description" => "Opaque pagination cursor (pass next_cursor from the previous page)."
          })

        :compute_exec ->
          put_in(base, ["properties", "timeout_ms"], %{
            "type" => "integer",
            "minimum" => 1_000,
            "maximum" => 300_000,
            "description" =>
              "Optional command timeout in milliseconds (1000..300000, default 60000). On timeout the entire process group is killed. Use process.start for long-lived or daemon commands."
          })

        :workspace_read ->
          base
          |> put_in(["properties", "offset"], %{
            "type" => "integer",
            "minimum" => 0,
            "description" => "Optional byte offset to start reading from (default 0)."
          })
          |> put_in(["properties", "max_bytes"], %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 1_048_576,
            "description" =>
              "Optional maximum number of bytes to read (1..1048576, default 1048576)."
          })

        :workspace_write ->
          base
          |> put_in(["properties", "content"], %{
            "type" => "string",
            "description" =>
              "UTF-8 text content to write. Provide exactly one of content or content_base64."
          })
          |> put_in(["properties", "content_base64"], %{
            "type" => "string",
            "description" =>
              "Base64-encoded raw bytes for binary files. Provide exactly one of content or content_base64."
          })
          |> put_in(["properties", "mode"], %{
            "type" => "integer",
            "description" =>
              "Optional file mode bits as a decimal integer (default 420, i.e. 0644)."
          })

        :process_write ->
          base
          |> put_in(["properties", "data"], %{
            "type" => "string",
            "description" =>
              "UTF-8 text input to write. Provide exactly one of data or data_base64."
          })
          |> put_in(["properties", "data_base64"], %{
            "type" => "string",
            "description" =>
              "Base64-encoded raw bytes to write. Provide exactly one of data or data_base64."
          })

        :process_stop ->
          put_in(base, ["properties", "signal"], %{
            "type" => "string",
            "enum" => ["term", "int", "kill"],
            "description" => "Optional signal to send to the process (default \"term\")."
          })

        _ ->
          base
      end

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

    if operation == :process_tail do
      put_in(base, ["properties", "wait_ms"], %{
        "type" => "integer",
        "minimum" => 0,
        "maximum" => 30_000,
        "description" =>
          "Optional maximum milliseconds to wait (0..30000) when no new output is available yet and the process is still running; returns immediately on new output or process exit (default 0)."
      })
    else
      base
    end
  end

  @public_errors %{
    compute_grant_required:
      "This operation requires an authorized Shell or an explicit Compute Grant.",
    workload_target_required: "Select workload_id from compute.workloads.list before this call.",
    workload_target_mismatch: "The selected Workload differs from this Session or Grant target.",
    workload_not_available:
      "The selected Workload is unavailable to this workspace. Refresh compute.workloads.list.",
    compute_workspace_unavailable:
      "This Agent has no current workspace access for shared Workloads.",
    compute_disabled: "Compute tools are disabled for this Agent.",
    invalid_cursor: "Use next_cursor from compute.workloads.list as after_id."
  }

  defp invalid_argument(message) do
    {:tool_failure, Jason.encode!(%{error_class: "invalid_argument", message: message}),
     "invalid_argument", "user_reportable", message, []}
  end

  defp failure(reason) do
    case Map.fetch(@public_errors, reason) do
      {:ok, message} ->
        code = Atom.to_string(reason)

        {:tool_failure, Jason.encode!(%{error_class: code, message: message}), code,
         "user_reportable", message, []}

      :error ->
        raise "Compute operation failed: #{inspect(reason)}"
    end
  end

  # The arguments to dispatch, and the credential values the result must not show.
  defp prepare_args(operation, args, ctx) when operation in [:compute_exec, :process_start] do
    {entries, args} = Map.pop(args, "credential_env", [])

    case SalixAgent.OAuthCredentials.resolve_for_command(
           ctx,
           required_context(ctx, :agent_id),
           entries
         ) do
      {:ok, resolved, secrets} ->
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

        with {:ok, normalized} <- normalize_args(operation, args, ctx) do
          {:ok, normalized, secrets}
        end

      {:error, message} ->
        raise message
    end
  end

  defp prepare_args(operation, args, ctx) do
    with {:ok, normalized} <- normalize_args(operation, args, ctx) do
      {:ok, normalized, []}
    end
  end

  defp normalize_args(:process_start, args, ctx) do
    args = Map.delete(args, "request_id")

    case Map.get(ctx, :tool_call_id) || Map.get(ctx, "tool_call_id") do
      tool_call_id when is_binary(tool_call_id) and tool_call_id != "" ->
        request_id =
          "tps_" <>
            (:crypto.hash(:sha256, tool_call_id) |> Base.url_encode64(padding: false))

        {:ok, Map.put(args, "request_id", request_id)}

      _ ->
        raise "process.start requires tool_call_id"
    end
  end

  defp normalize_args(:process_write, args, _ctx) do
    encode_text_or_base64(args, "data", "data_base64")
  end

  defp normalize_args(operation, args, _ctx) when operation in @workspace_operations do
    args =
      case Map.get(args, "path") do
        path when is_binary(path) ->
          Map.put(args, "path", normalize_workspace_path(operation, path))

        _ ->
          args
      end

    if operation == :workspace_write do
      args
      |> Map.drop(["offset", "expected_prefix_sha256"])
      |> encode_text_or_base64("content", "content_base64")
    else
      {:ok, args}
    end
  end

  defp normalize_args(_operation, args, _ctx), do: {:ok, args}

  defp encode_text_or_base64(args, text_key, b64_key) do
    has_text = Map.has_key?(args, text_key)
    has_b64 = Map.has_key?(args, b64_key)

    cond do
      has_text and has_b64 ->
        {:error,
         {:invalid_argument, "Provide exactly one of #{text_key} or #{b64_key}, not both."}}

      not has_text and not has_b64 ->
        {:error, {:invalid_argument, "Provide either #{text_key} or #{b64_key}."}}

      has_text ->
        case Map.get(args, text_key) do
          text when is_binary(text) ->
            {:ok, args |> Map.delete(text_key) |> Map.put(b64_key, Base.encode64(text))}

          _ ->
            {:error, {:invalid_argument, "#{text_key} must be a UTF-8 string."}}
        end

      true ->
        case Map.get(args, b64_key) do
          b64 when is_binary(b64) ->
            case Base.decode64(b64) do
              {:ok, _} -> {:ok, args}
              :error -> {:error, {:invalid_argument, "#{b64_key} must be valid base64."}}
            end

          _ ->
            {:error, {:invalid_argument, "#{b64_key} must be valid base64."}}
        end
    end
  end

  defp normalize_workspace_path(operation, "/" <> _ = path) do
    case String.trim_leading(path, "/") do
      "" when operation in [:workspace_stat, :workspace_list] -> "."
      "" -> "/"
      trimmed -> trimmed
    end
  end

  defp normalize_workspace_path(_operation, path), do: path
end
