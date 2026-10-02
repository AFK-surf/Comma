defmodule SalixAgent.Tools.Peers do
  @moduledoc """
  Remote environment tools. Agent management lives in Tools.AgentManagement;
  environment target discovery lives in Tools.RuntimeTargets.
  Funs follow the SalixAgent.Tools contract: (args, ctx), returning content or
  a tool failure. Context carries the owning Agent and Session identities.

  Environment tools route through the `SalixAgent.EnvDispatch` seam
  (configured via `Application.get_env(:salix_agent, :env_dispatch, ...)`,
  default `SalixAgent.EnvDispatch.None`). When the seam reports
  `{:error, :no_environment}`, tools raise willow's ToolUnavailable-shaped
  message: `tool "<name>" unavailable (not_installed): no environment
  connected`.

  ## Simplifications vs willow (per HARD-RULE doc requirement)

    * `device.list` — bounded device summaries with an opaque next_cursor.
      `device.get` reads one device including its environments and runtimes.
      VFS remains the agent-owned file target of env.copy; it is not a device.
    * `env.exec` — the tool function performs one environment RPC; runtime-level
      async conversion parks it immediately when no completion message is already
      available, without waiting in the session actor mailbox.
      `description` validation (required, ≤ 39 chars) matches the original behavior.
      `credential_env` IS ported (willow `internal/oauth/resolver.go`
      `Resolveenv.execCredentials`): entries resolve through
      `SalixAgent.OAuthCredentials` into the `"env"` map forwarded to
      `EnvDispatch.exec`, resolved values win over any caller-supplied env,
      and the `credential_env` references are STRIPPED — the connector never
      sees them. Resolution errors raise willow's per-entry format
      (`oauth credential {provider}/{alias} for {env_var}: {reason}`).
      Persistent processes and host-access permission gating are not ported.
    * `env.copy` — willow's inter-environment copy surface. VFS→VFS keeps the
      manifest-ref copy fast path; any remote side goes through
      `EnvDispatch.read_stream` / `write_stream`. This is a streaming tool, so
      it is not governed by the 10MB full-read/full-write cap used by
      `fs.read_file`/`fs.write_file`. Comma extends it with optional
      `src_agent_id` / `dst_agent_id` group-local peer qualifiers
      (vfs-only): peer VFS→VFS shares the source blob ref with zero copy
      (bodies are global, write-once), and a peer destination is committed
      through `AgentActor.commit_workspace_operation/5` under a deterministic
      operation id; peer↔remote sides stream chunked via
      `AgentWorkspace.stream` / `SalixStore.Blob.put_stream`. Group membership is
      the security boundary, so the tool stays available to all roles.
    * `env.computer_use` — `action=help` returns willow's mode overview verbatim
      and never touches the seam. Other actions forward
      `{environment, action, thinking?, args?}` and map the connector
      envelope exactly like willow's `computerUseResultFromRaw` (error →
      raise; `result` → `{"result": ...}`; else message/mode/help/text
      joined). Images return temporary device references for model input.
      The start/permission authorization flows (capability requests, waits)
      and the process-wide serialization gate are not ported.
  """

  alias SalixAgent.{
    AgentActor,
    AgentControl,
    AgentWorkspace,
    EnvDispatch,
    FileBackend,
    OAuthStore
  }

  alias SalixStore.{Blob, Ids}

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @worker_role_opts [roles: ["worker"], safety: "write"]
  @vm_lifecycle_error_classes [
    :vm_waking,
    :vm_archiving,
    :vm_rolling_update,
    :vm_service_upgrading
  ]

  @doc "Tool defs in willow registry order (`internal/tools/registry.go`)."
  @spec defs() :: [
          {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
          | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
        ]
  def defs do
    [
      {"env.exec",
       "Execute a shell command on a remote environment. Always provide a short description under 20 characters explaining what the command is for. Requires device_id and environment (the stable environment_id from device.get). Commands without an already-available completion continue as background tool calls and report completion through session notifications. " <>
         "Use credential_env to inject group-scoped OAuth credentials (e.g. GitHub, Linear, Notion) into specific environment variables for this single subprocess. " <>
         "On macOS, an authorized action can request native OS authorization with osascript's `do shell script ... with administrator privileges`. " <>
         "A permission error does not automatically request elevation. Set a bounded timeout that allows user interaction. " <>
         "Do not resubmit a running command. On cancellation, do not retry without renewed user authorization. " <>
         "completed means the process exited. Check exit_code and verify the requested outcome before reporting success.",
       &__MODULE__.exec/2, @normal_auto_wait_seconds},
      {"env.process_list", "List long-lived processes running in a connector-backed environment.",
       &__MODULE__.process_list/2, @normal_auto_wait_seconds},
      {"env.process_write",
       "Write text to stdin of a long-lived process in a connector-backed environment.",
       &__MODULE__.process_write/2, @normal_auto_wait_seconds},
      {"env.process_tail",
       "Read recent output from a long-lived process in a connector-backed environment, optionally waiting for new output.",
       &__MODULE__.process_tail/2, @normal_auto_wait_seconds},
      {"env.copy",
       "Copy a file between any two environments (VFS or remote). Use src_environment and dst_environment, with src_device_id/dst_device_id for each remote side; pass vfs for agent-owned files. Set src_agent_id or dst_agent_id (vfs only) to copy from or to a group-local peer agent's vfs; use known Agent ids supplied by the Router or Task context.",
       &__MODULE__.copy/2, @normal_auto_wait_seconds},
      {"device.list",
       "Discover one bounded page of devices in the current workspace. Use device.get with a device_id for its environments, permissions and runtime details. Known device and environment ids can be used directly without discovery.",
       &__MODULE__.list_devices/2, @normal_auto_wait_seconds},
      {"device.get",
       "Read one known device by device_id, including its current command environments, permissions, capabilities, connector health and runtime availability. Only after a successful lookup, for a permission_required environment, explain permission_message and ask the user to enable access before retrying. On a lookup error, follow its recovery guidance instead of treating previous device state as current. This query does not probe, reconnect, wake, rebind or repair.",
       &__MODULE__.get_device/2, @normal_auto_wait_seconds},
      {"env.computer_use",
       "Desktop automation for a connector-backed environment. Use a known environment with computer_use_tool capability directly; use device.get for a known device, or device.list when the device is unknown. action=help is optional guidance for the available modes, not a prerequisite.",
       &__MODULE__.computer_use/2, @normal_auto_wait_seconds},
      {"env.android",
       "Lease and operate one authorized connector-backed Android emulator. Use start, then alternate observe and bounded actions, and always end the lease.",
       &__MODULE__.android/2, @normal_auto_wait_seconds, @worker_role_opts}
    ]
  end

  # ---- env.copy (willow: internal/tools/copy.go) ----

  @doc false
  def copy(args, ctx) do
    try do
      src_env = copy_target!(args, "src")
      src_path = required_arg(args, "src_path")
      dst_env = copy_target!(args, "dst")
      dst_path = required_arg(args, "dst_path")
      src_agent_arg = arg(args, "src_agent_id")
      dst_agent_arg = arg(args, "dst_agent_id")

      validate_copy_qualifier!("src_agent_id", src_agent_arg, "src_environment", src_env)
      validate_copy_qualifier!("dst_agent_id", dst_agent_arg, "dst_environment", dst_env)

      # A supplied id equal to the caller behaves as if absent.
      src_agent_id = resolve_copy_agent!(ctx, src_agent_arg)
      dst_agent_id = resolve_copy_agent!(ctx, dst_agent_arg)
      src_peer? = src_agent_id != ctx.agent_id
      dst_peer? = dst_agent_id != ctx.agent_id

      if src_peer? or dst_peer? do
        # ANY vfs side in a cross-agent copy must be a normal workspace path —
        # not just the peer side. runtime/skill mounts are caller-local
        # (RuntimeFiles/SkillStore backed), so the cross-agent code paths talk
        # to the shared-ref manifest directly and would bypass the read-only
        # runtime guard and skill-write authorization that the equivalent local
        # copy applies via FileBackend. Reject those paths on both sides.
        ensure_cross_agent_normal_path!("src_path", src_env, src_path)
        ensure_cross_agent_normal_path!("dst_path", dst_env, dst_path)

        # Peer-destination commits are idempotent on a deterministic operation
        # id derived from tool_call_id. Require it UP FRONT (before any body
        # I/O) so a missing id never drains the source or leaves an orphan blob
        # (Case C) before failing — mirroring deterministic_worker_id.
        operation_id = if dst_peer?, do: copy_operation_id!(ctx), else: nil

        copy_cross_agent(ctx, %{
          src_env: src_env,
          src_path: src_path,
          dst_env: dst_env,
          dst_path: dst_path,
          src_agent_id: src_agent_id,
          dst_agent_id: dst_agent_id,
          dst_peer?: dst_peer?,
          operation_id: operation_id,
          src_agent_arg: src_agent_arg,
          dst_agent_arg: dst_agent_arg
        })
      else
        copy_local(ctx, src_env, src_path, dst_env, dst_path, src_agent_arg, dst_agent_arg)
      end
    catch
      {:vm_copy_error, result} -> result
    end
  end

  # Original copy behavior (no peer qualifier, or a qualifier resolving to the
  # caller). Byte-identical when neither id is supplied — `put_optional_nonblank`
  # drops the blank echoes.
  defp copy_local(ctx, src_env, src_path, dst_env, dst_path, src_agent_arg, dst_agent_arg) do
    if src_env == "vfs" and dst_env == "vfs" do
      case FileBackend.prepare_copy(ctx, src_path, dst_path) do
        {:ok, events, size} ->
          {copy_result(src_path, dst_path, size, src_agent_arg, dst_agent_arg), events}

        {:error, :not_found} ->
          raise("copy: no such file: #{src_path}")

        {:error, reason} ->
          raise("copy: #{inspect(reason)}")
      end
    else
      stream_copy(
        ctx,
        read_copy_source(ctx, src_env, src_path),
        src_path,
        dst_env,
        dst_path,
        src_agent_arg,
        dst_agent_arg
      )
    end
  end

  # Shared counted/verified streaming copy into a copy destination (remote env
  # or caller vfs). `source` is the `{stream, reported_size}` pair from a
  # copy-source reader.
  defp stream_copy(
         ctx,
         {stream, reported_size},
         src_path,
         dst_env,
         dst_path,
         src_agent_id,
         dst_agent_id
       ) do
    {stream, count_fn} = counted_stream(stream)
    {events, written_size} = write_copy_destination(ctx, dst_env, dst_path, stream)
    sent_size = count_fn.()
    size = verified_copy_size(src_path, dst_path, sent_size, written_size, reported_size)
    content = copy_result(src_path, dst_path, size, src_agent_id, dst_agent_id)

    if events == [], do: content, else: {content, events}
  end

  # Case A: peer VFS→VFS (at least one side is a peer). Zero-copy — share the
  # source blob ref; commit to a peer destination, else return a caller event.
  defp copy_cross_agent(ctx, %{src_env: "vfs", dst_env: "vfs"} = c) do
    entry =
      case AgentWorkspace.entry(c.src_agent_id, c.src_path) do
        {:ok, entry} -> entry
        {:error, :not_found} -> raise("copy: no such file: #{c.src_path}")
        {:error, reason} -> raise("copy: #{inspect(reason)}")
      end

    ensure_blob_ref!(entry, c.src_path)
    {:ok, event} = AgentWorkspace.prepare_copy_entry(c.dst_path, entry)
    size = entry["size"] || entry[:size]

    content =
      copy_result(c.src_path, c.dst_path, size, c.src_agent_arg, c.dst_agent_arg)

    if c.dst_peer? do
      commit_peer_copy!(ctx, c, event, size)
      content
    else
      {content, [event]}
    end
  end

  # Case B: peer VFS source → remote destination (caller's env). Chunked stream.
  defp copy_cross_agent(ctx, %{src_env: "vfs"} = c) do
    stream_copy(
      ctx,
      peer_vfs_source(c.src_agent_id, c.src_path),
      c.src_path,
      c.dst_env,
      c.dst_path,
      c.src_agent_arg,
      c.dst_agent_arg
    )
  end

  # Case C: remote source (caller's env) → peer VFS destination. Chunked stream
  # into a fresh blob, then a cross-agent manifest commit.
  defp copy_cross_agent(ctx, %{dst_env: "vfs"} = c) do
    {stream, reported_size} = read_copy_source(ctx, c.src_env, c.src_path)
    {stream, count_fn} = counted_stream(stream)

    ref =
      case Blob.put_stream(c.dst_agent_id, stream) do
        {:ok, ref} -> ref
        {:error, reason} -> raise("write destination: #{inspect(reason)}")
      end

    sent_size = count_fn.()
    size = verified_copy_size(c.src_path, c.dst_path, sent_size, ref.size, reported_size)
    {:ok, event} = AgentWorkspace.prepare_write_ref(c.dst_path, ref)

    content =
      copy_result(c.src_path, c.dst_path, size, c.src_agent_arg, c.dst_agent_arg)

    commit_peer_copy!(ctx, c, event, size)
    content
  end

  defp validate_copy_qualifier!(_ref_key, "", _env_key, _env), do: :ok
  defp validate_copy_qualifier!(_ref_key, _ref, _env_key, "vfs"), do: :ok

  defp validate_copy_qualifier!(ref_key, _ref, env_key, _env),
    do: raise("#{ref_key} is only valid when #{env_key} is vfs")

  defp ensure_cross_agent_normal_path!(path_key, "vfs", path) do
    unless FileBackend.normal_path?(path) do
      raise "cross-agent copy requires a normal workspace #{path_key}; runtime/skill mounts are caller-local: #{path}"
    end
  end

  defp ensure_cross_agent_normal_path!(_path_key, _env, _path), do: :ok

  defp resolve_copy_agent!(ctx, ""), do: ctx.agent_id

  defp resolve_copy_agent!(ctx, agent_id) do
    case resolve_group_agent_id(ctx.agent_id, agent_id) do
      {:ok, target} ->
        target["agent_id"]

      {:error, reason} ->
        raise "env.copy failed for agent_id #{inspect(agent_id)}: #{inspect(reason)}. Use a valid group-local agents[].agent_id value; call agent.list only if that id is unknown."
    end
  end

  defp ensure_blob_ref!(entry, path) do
    ref = entry["ref"] || entry[:ref]
    kind = if is_map(ref), do: ref["kind"] || ref[:kind]

    unless kind == "blob" do
      raise("copy: unsupported ref kind for #{path}: #{inspect(kind)}")
    end
  end

  defp peer_vfs_source(agent_id, path),
    do: copy_source_stream(AgentWorkspace.stream(agent_id, path), path)

  defp commit_peer_copy!(ctx, c, event, size) do
    billing_context =
      Map.get(ctx, :billing_context) || Map.get(ctx, "billing_context") || %{}

    result_summary = %{
      "src_path" => c.src_path,
      "dst_path" => c.dst_path,
      "size" => size,
      "copied" => true
    }

    case AgentActor.commit_workspace_operation(
           c.dst_agent_id,
           c.operation_id,
           result_summary,
           [event],
           billing_context: billing_context,
           entrypoint: "storage_write",
           actor_type: "tool"
         ) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        raise("copy: commit to #{c.dst_agent_arg} failed: #{inspect(reason)}")
    end
  end

  defp copy_operation_id!(ctx) do
    "env.copy-" <>
      deterministic_tool_digest!(
        ctx,
        "env.copy",
        [],
        "env.copy requires tool_call_id for cross-agent idempotency"
      )
  end

  defp copy_source_stream(result, path) do
    case result do
      {:ok, stream, size} -> {stream, size}
      {:error, :not_found} -> raise("read source: no such file: #{path}")
      {:error, reason} -> raise("read source: #{inspect(reason)}")
    end
  end

  defp copy_result(src_path, dst_path, size, src_agent_id, dst_agent_id) do
    %{
      "src_path" => src_path,
      "dst_path" => dst_path,
      "size" => size,
      "copied" => true
    }
    |> put_optional_nonblank("src_agent_id", src_agent_id)
    |> put_optional_nonblank("dst_agent_id", dst_agent_id)
    |> Jason.encode!()
  end

  defp read_copy_source(ctx, "vfs", path),
    do: copy_source_stream(FileBackend.stream(ctx, path), path)

  defp read_copy_source(ctx, env, path) do
    case EnvDispatch.read_stream(ctx.agent_id, env, path) do
      {:ok, stream, size} ->
        {stream, size}

      {:error, :no_environment} ->
        unavailable!("env.copy")

      {:error, %{"error_class" => _} = error} ->
        vm_copy_error!(error)

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        vm_copy_error!(vm_lifecycle_error(class, metadata))

      {:error, reason} ->
        raise("read stream: #{inspect(reason)}")
    end
  end

  defp write_copy_destination(ctx, "vfs", path, stream) do
    case FileBackend.prepare_write_stream(ctx, path, stream) do
      # The Drive mount applies its write as the tool runs and leaves no
      # journal event; its size is the source's.
      {:ok, nil} -> {[], nil}
      {:ok, event} -> {[event], event["size"]}
      {:error, reason} -> raise("write destination: #{inspect(reason)}")
    end
  end

  defp write_copy_destination(ctx, env, path, stream) do
    case EnvDispatch.write_stream(ctx.agent_id, env, path, stream) do
      {:ok, result} ->
        {[], write_stream_result_size(result)}

      {:error, :no_environment} ->
        unavailable!("env.copy")

      {:error, %{"error_class" => _} = error} ->
        vm_copy_error!(error)

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        vm_copy_error!(vm_lifecycle_error(class, metadata))

      {:error, reason} ->
        raise("write stream: #{inspect(reason)}")
    end
  end

  defp verified_copy_size(src_path, dst_path, sent_size, written_size, reported_size) do
    if is_integer(written_size) and written_size != sent_size do
      raise(
        "copy: wrote #{written_size} bytes to #{dst_path}, but read #{sent_size} bytes from #{src_path}"
      )
    end

    written_size || sent_size || reported_size
  end

  defp write_stream_result_size(%{"size" => size}) when is_integer(size), do: size

  defp write_stream_result_size(%{"size" => size}) when is_binary(size) do
    case Integer.parse(size) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp write_stream_result_size(_result), do: nil

  defp counted_stream(stream) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    counted =
      Stream.map(stream, fn chunk ->
        chunk = IO.iodata_to_binary(chunk)

        Agent.get_and_update(counter, fn size ->
          next = size + byte_size(chunk)
          {next, next}
        end)

        chunk
      end)

    {counted,
     fn ->
       size = Agent.get(counter, & &1)
       Agent.stop(counter)
       size
     end}
  end

  defp list_agents_group_id(agent_id) do
    case OAuthStore.agent_oauth_context(agent_id) do
      {:ok, %{group_id: group_id}} when is_binary(group_id) and group_id != "" ->
        {:ok, group_id}

      {:ok, %{"group_id" => group_id}} when is_binary(group_id) and group_id != "" ->
        {:ok, group_id}

      _ ->
        list_agents_group_id_from_record(agent_id)
    end
  end

  defp list_agents_group_id_from_record(agent_id) do
    with {:ok, %{"group_id" => group_id}} when is_binary(group_id) and group_id != "" <-
           AgentControl.get_record(agent_id) do
      {:ok, group_id}
    else
      _ -> {:error, :group_scope_unavailable}
    end
  end

  defp resolve_group_agent_id(caller_agent_id, target_agent_id) do
    target_agent_id = String.trim(to_string(target_agent_id || ""))

    with {:ok, group_id} <- list_agents_group_id(caller_agent_id),
         true <- Ids.valid_agent_id_for_group?(target_agent_id, group_id),
         {:ok, record} <- AgentControl.get_record(target_agent_id) do
      if record["agent_id"] == target_agent_id and record["group_id"] == group_id and
           not AgentControl.archived?(record) and
           record["status"] not in ["cancelled", "failed"] do
        {:ok, record}
      else
        {:error, :not_found}
      end
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # ---- device discovery ----

  @doc false
  def list_devices(args, ctx) do
    limit = raw(args, "limit") || 20

    unless is_integer(limit) and limit >= 1 and limit <= 100,
      do: raise("limit must be an integer between 1 and 100")

    cursor = arg(args, "cursor")
    opts = if cursor == "", do: [limit: limit], else: [limit: limit, cursor: cursor]

    case EnvDispatch.list_devices(ctx.agent_id, opts) do
      {:ok, page} -> Jason.encode!(page)
      {:error, reason} -> raise "device.list failed: #{inspect(reason)}"
    end
  end

  @doc false
  def get_device(args, ctx) do
    device_id = required_arg(args, "device_id")

    case EnvDispatch.get_device(ctx.agent_id, device_id) do
      {:ok, entry} ->
        Jason.encode!(entry)

      {:error, :not_found} ->
        device_lookup_failure(
          device_id,
          "device_not_found",
          "This device was not found in the current workspace. " <>
            "Tell the user it is no longer available here. " <>
            "This is a missing device record, not an offline connection or a read-only permission issue. " <>
            "Use device.list to find current devices and confirm the intended target. " <>
            "Do not use its previous status or ask the user to change permissions on this missing device."
        )

      {:error, _reason} ->
        device_lookup_failure(
          device_id,
          "device_lookup_failed",
          "The device lookup failed. Its current state is unknown. " <>
            "Retry the lookup before giving device-specific instructions. " <>
            "Do not report the device as disconnected, missing, or permission-blocked from this error."
        )
    end
  end

  defp device_lookup_failure(device_id, code, message) do
    content = Jason.encode!(%{"device_id" => device_id, "code" => code, "message" => message})
    {:tool_failure, content, code, "user_reportable", message, []}
  end

  # Deterministic 24-hex digest over the calling tool invocation
  # (`tool:extra…:agent:session:tool_call_id`), for idempotent tool-created
  # resources. Raises `missing_message` when ctx carries no tool_call_id.
  defp deterministic_tool_digest!(ctx, tool, extra_parts, missing_message) do
    tool_call_id =
      ctx
      |> Map.get(:tool_call_id, Map.get(ctx, "tool_call_id", ""))
      |> to_string()
      |> String.trim()

    if tool_call_id == "" do
      raise(missing_message)
    end

    raw =
      ([tool] ++
         extra_parts ++
         [
           Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id"),
           Map.get(ctx, :session_id) || Map.get(ctx, "session_id"),
           tool_call_id
         ])
      |> Enum.map(&to_string/1)
      |> Enum.join(":")

    :sha256
    |> :crypto.hash(raw)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  # ---- env.exec (willow: internal/tools/exec.go) ----

  @doc false
  def exec(args, ctx) do
    environment = arg(args, "environment")
    command = arg(args, "command")
    description = normalize_exec_description(arg(args, "description"))

    if environment == "" or environment == "vfs", do: raise("exec requires a remote environment")
    if command == "", do: raise("'command' is required")
    target = environment_target!(args, environment)

    opts =
      %{
        "description" => description,
        "timeout" => raw(args, "timeout") || 120,
        "wait_for_vm" => true
      }
      |> then(fn m ->
        wd = arg(args, "working_dir")
        if wd == "", do: m, else: Map.put(m, "working_dir", wd)
      end)
      |> merge_credential_env(args, ctx)

    case EnvDispatch.exec(ctx.agent_id, target, command, opts) do
      {:ok, result} when is_map(result) ->
        Jason.encode!(result)

      {:ok, result} when is_binary(result) ->
        result

      {:error, %{"error_class" => _} = error} ->
        Jason.encode!(vm_error_result(error))

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        Jason.encode!(vm_error_result(vm_lifecycle_error(class, metadata)))

      {:error, :no_environment} ->
        unavailable!("env.exec")

      {:error, {:permission_required, message}} when is_binary(message) ->
        raise message

      {:error, reason} ->
        raise "exec failed: #{inspect(reason)}"
    end
  end

  # ---- env.process_* ----

  @doc false
  def process_list(args, ctx) do
    environment = arg(args, "environment")

    if environment == "" or environment == "vfs",
      do: raise("process_list requires a remote environment")

    case EnvDispatch.process_list(ctx.agent_id, environment_target!(args, environment)) do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, %{"error_class" => _} = error} ->
        Jason.encode!(vm_error_result(error))

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        Jason.encode!(vm_error_result(vm_lifecycle_error(class, metadata)))

      {:error, :no_environment} ->
        unavailable!("env.process_list")

      {:error, reason} ->
        raise "process_list failed: #{inspect(reason)}"
    end
  end

  @doc false
  def process_write(args, ctx) do
    environment = arg(args, "environment")
    process_name = arg(args, "process_name")
    data = arg(args, "data")

    if environment == "" or environment == "vfs",
      do: raise("process_write requires a remote environment")

    if process_name == "", do: raise("'process_name' is required")

    opts =
      %{}
      |> put_optional("append_newline", bool_opt(raw(args, "append_newline")))

    case EnvDispatch.process_write(
           ctx.agent_id,
           environment_target!(args, environment),
           process_name,
           data,
           opts
         ) do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, %{"error_class" => _} = error} ->
        Jason.encode!(vm_error_result(error))

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        Jason.encode!(vm_error_result(vm_lifecycle_error(class, metadata)))

      {:error, :no_environment} ->
        unavailable!("env.process_write")

      {:error, reason} ->
        raise "process_write failed: #{inspect(reason)}"
    end
  end

  @doc false
  def process_tail(args, ctx) do
    environment = arg(args, "environment")
    process_name = arg(args, "process_name")

    if environment == "" or environment == "vfs",
      do: raise("process_tail requires a remote environment")

    if process_name == "", do: raise("'process_name' is required")

    opts =
      %{}
      |> put_optional("from_offset", int_opt(raw(args, "from_offset")))
      |> put_optional("max_bytes", int_opt(raw(args, "max_bytes")))
      |> put_optional("tail_bytes", int_opt(raw(args, "tail_bytes")))
      |> put_optional("wait_seconds", int_opt(raw(args, "wait_seconds")))

    case EnvDispatch.process_tail(
           ctx.agent_id,
           environment_target!(args, environment),
           process_name,
           opts
         ) do
      {:ok, result} ->
        Jason.encode!(result)

      {:error, %{"error_class" => _} = error} ->
        Jason.encode!(vm_error_result(error))

      {:error, {class, metadata}} when class in @vm_lifecycle_error_classes ->
        Jason.encode!(vm_error_result(vm_lifecycle_error(class, metadata)))

      {:error, :no_environment} ->
        unavailable!("env.process_tail")

      {:error, reason} ->
        raise "process_tail failed: #{inspect(reason)}"
    end
  end

  defp vm_lifecycle_error(class, metadata) do
    metadata = if is_map(metadata), do: metadata, else: %{"reason" => inspect(metadata)}

    metadata
    |> Map.put("error_class", Atom.to_string(class))
    |> Map.put_new("message", Atom.to_string(class))
    |> Map.put_new("retryable", true)
  end

  defp vm_error_result(error) do
    %{
      "ok" => false,
      "error_class" => error["error_class"],
      "reason" => error["reason"],
      "message" => error["message"] || error["error_class"],
      "retryable" => error["retryable"] == true,
      "env_id" => error["env_id"],
      "sandbox_id" => error["sandbox_id"],
      "connection_generation" => error["connection_generation"]
    }
  end

  defp vm_copy_error!(error), do: throw({:vm_copy_error, Jason.encode!(vm_error_result(error))})

  # willow oauth.Resolveenv.execCredentials: resolve credential_env references into
  # the env map forwarded to the connector and STRIP credential_env from the
  # forwarded params (the connector never sees the references). Absent
  # credential_env → params pass through unchanged; an explicitly empty array
  # is a no-op. Resolved values win over any caller-supplied env entries.
  defp merge_credential_env(opts, args, ctx) do
    case raw(args, "credential_env") do
      nil ->
        opts

      entries ->
        case SalixAgent.OAuthCredentials.resolve(ctx.agent_id, entries) do
          {:ok, resolved} when map_size(resolved) == 0 ->
            opts

          {:ok, resolved} ->
            Map.put(opts, "env", Map.merge(base_env(args), resolved))

          {:error, message} ->
            raise message
        end
    end
  end

  # Willow merges resolved values into the request's existing env map; the
  # env.exec schema declares no env property, so this is normally empty.
  defp base_env(args) do
    case raw(args, "env") do
      env when is_map(env) -> Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)
      _ -> %{}
    end
  end

  defp normalize_exec_description(raw) do
    case SalixAgent.Tools.Schemas.normalize_exec_description(raw) do
      "" -> raise "'description' is required"
      desc -> desc
    end
  end

  # ---- env.computer_use (willow: internal/tools/computer_use.go) ----

  @doc false
  def computer_use(args, ctx) do
    action = String.trim(arg(args, "action"))
    if action == "", do: raise("'action' is required")

    if action == "help" do
      Jason.encode!(%{"result" => computer_use_mode_overview()})
    else
      environment = String.trim(arg(args, "environment"))
      if environment == "", do: raise("computer_use requires a remote environment")

      payload =
        %{"environment" => environment, "action" => action}
        |> then(fn m ->
          thinking = String.trim(arg(args, "thinking"))
          if thinking == "", do: m, else: Map.put(m, "thinking", thinking)
        end)
        |> then(fn m ->
          case raw(args, "args") do
            nil -> m
            inner -> Map.put(m, "args", inner)
          end
        end)

      case EnvDispatch.computer_use(ctx.agent_id, environment_target!(args, environment), payload) do
        {:ok, response} when is_map(response) ->
          computer_use_result(action, response, environment_target!(args, environment), ctx)

        {:error, :no_environment} ->
          unavailable!("env.computer_use")

        {:error, reason} ->
          raise "computer_use failed: #{inspect(reason)}"
      end
    end
  end

  # Mirrors willow's computerUseResultFromRaw: typed error → raise; image →
  # temporary device reference; result → {"result": ...};
  # else join message/mode/help/text; else echo the raw payload.
  defp computer_use_result(_action, payload, target, ctx) do
    cond do
      payload["ok"] == false and present?(payload["error"]) ->
        raise String.trim(payload["error"])

      present?(payload["image_path"]) ->
        if !SalixAgent.MediaResolver.supports_images?(ctx.agent_id, ctx),
          do: raise("computer_use screenshot requires an image-capable model")

        Jason.encode!([
          %{
            "type" => "image",
            "file_ref" => %{
              "device_id" => target.device_id,
              "environment_id" => target.environment_id,
              "path" => payload["image_path"]
            },
            "mime_type" => payload["image_content_type"],
            "size_bytes" => payload["image_size_bytes"],
            "width" => payload["image_width"],
            "height" => payload["image_height"]
          }
        ])

      present?(payload["image_data_url"]) ->
        raise "computer_use connector requires an update for device screenshot references"

      present?(payload["result"]) ->
        Jason.encode!(%{"result" => String.trim(payload["result"])})

      true ->
        parts =
          [
            trimmed(payload["message"]),
            if(present?(payload["mode"]), do: "Mode: #{payload["mode"]}"),
            if(present?(payload["help"]), do: "Help:\n" <> String.trim(payload["help"])),
            trimmed(payload["text"])
          ]
          |> Enum.reject(&is_nil/1)

        case parts do
          [] -> Jason.encode!(payload)
          parts -> Jason.encode!(%{"result" => Enum.join(parts, "\n\n")})
        end
    end
  end

  # ---- env.android ----

  @doc false
  def android(args, ctx) do
    environment = String.trim(arg(args, "environment"))
    action = String.trim(arg(args, "action"))
    if environment == "", do: raise("android requires a remote environment")
    if action == "", do: raise("'action' is required")

    payload =
      args
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("environment", environment)
      |> Map.put("action", action)

    case EnvDispatch.android(ctx.agent_id, environment_target!(args, environment), payload) do
      {:ok, %{"ok" => false} = response} ->
        raise android_error(response)

      {:ok, response} when is_map(response) ->
        response
        |> Map.drop(["image_data"])
        |> then(&Jason.encode!(%{"result" => &1}))

      {:error, reason} ->
        raise android_dispatch_error(reason)
    end
  end

  defp android_error(response) do
    code = response["error_code"] || "android_action_failed"
    message = response["error"] || "Android action failed"
    "#{code}: #{message}"
  end

  defp android_dispatch_error(reason)
       when reason in [
              :android_not_authorized,
              :android_policy_unavailable,
              :android_plugin_disabled,
              :android_environment_unavailable,
              :android_capability_missing,
              :android_profile_required,
              :android_profile_not_allowed,
              :android_profile_unavailable
            ],
       do: Atom.to_string(reason)

  defp android_dispatch_error(:no_environment), do: "android_environment_unavailable"
  defp android_dispatch_error(:timeout), do: "android_transport_ambiguous: timeout"
  defp android_dispatch_error(:disconnected), do: "android_transport_ambiguous: disconnected"
  defp android_dispatch_error(_reason), do: "android_environment_unavailable"

  defp computer_use_mode_overview do
    String.trim("""
    env.computer_use modes

    Two independent automation modes. The user picks one at session start; the
    choice is enforced by the connector, and the user can cancel at any time.

    background
    - Accessibility-tree driven, per-window automation.
    - User keeps using their computer; agent snapshots a window and drives it
      by element reference (snapshot_id + element_index).
    - Preferred when the target app has good accessibility coverage — resilient
      to pixel shifts, doesn't take over the display.

    foreground
    - Direct manipulation with raw screenshot-space coordinates.
    - Non-target apps are hidden, a dim HUD and repositioned cursor indicate
      the agent is driving. The user can pause by moving the mouse or pressing
      a key; the agent resumes once they stop.
    - Preferred for pixel-exact work, multi-window drag-drop, or UIs that lack
      accessibility.

    Workflow
    1. Use device.list to discover devices, then device.get to select an environment
       with capabilities.computer_use_tool=true. Reuse known device_id/environment ids.
    2. For app-specific tasks, call env.computer_use(device_id=..., environment=...,
       action="list-apps") and verify the target app appears. Use env.exec
       on that same environment to launch or activate it; if it was missing
       before, re-run list-applications and copy the exact listed name into
       args.apps.
    3. Call env.computer_use(device_id=..., environment=..., action="permissions-status") before
       starting. If any required permission is missing, call
       env.computer_use(device_id=..., environment=..., action="open-permission-flow") and wait for
       the user to grant it. These actions do not start a env.computer_use session.
    4. env.computer_use(device_id=..., environment=..., action="start", args={apps?: [string]}).
       The user picks the mode; do not include a mode hint — the decision is
       theirs. Response includes {mode, help, message}; "help" is the
       authoritative (action, args) reference for the chosen mode and your
       subsequent calls follow it verbatim.
    5. For each step: env.computer_use(device_id=..., environment=..., action=<name>,
       thinking="<short immediate next step>", args={...}). Pass thinking in the
       same tool call as the action so connector UIs can show progress before
       running it. get_screenshot / screenshot actions return temporary device images for model input.
    6. env.computer_use(device_id=..., environment=..., action="end") when done to tear the session
       down and restore hidden apps / overlays.

    The tool schema on this surface is intentionally free-form: don't try to
    infer arg shapes from this overview. Use the help returned from start.
    """)
  end

  defp environment_target!(args, environment) do
    %{device_id: required_arg(args, "device_id"), environment_id: environment}
  end

  defp copy_target!(args, side) do
    environment = required_arg(args, side <> "_environment")
    device_id = arg(args, side <> "_device_id")

    if environment == "vfs" do
      if device_id != "", do: raise(side <> "_device_id is only valid for a remote environment")
      "vfs"
    else
      %{device_id: required_arg(args, side <> "_device_id"), environment_id: environment}
    end
  end

  # ---- helpers ----

  # willow's ToolUnavailable pattern (internal/tools/tool_unavailable_error.go):
  # the raised message keeps the `tool "X" unavailable (state): reason` shape.
  @spec unavailable!(String.t()) :: no_return()
  defp unavailable!(tool) do
    raise ~s|tool "#{tool}" unavailable (not_installed): no environment connected|
  end

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
  defp trimmed(v), do: if(present?(v), do: String.trim(v))

  defp put_optional_nonblank(map, _key, value) when value in [nil, ""], do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp int_opt(nil), do: nil
  defp int_opt(""), do: nil
  defp int_opt(v) when is_integer(v), do: v

  defp int_opt(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp int_opt(_), do: nil

  defp bool_opt(nil), do: nil
  defp bool_opt(v) when is_boolean(v), do: v
  defp bool_opt(v) when is_binary(v), do: String.downcase(String.trim(v)) in ["1", "true", "yes"]
  defp bool_opt(_), do: nil

  defp arg(args, key), do: to_string(raw(args, key) || "")
  defp raw(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))

  defp required_arg(args, key) do
    case String.trim(arg(args, key)) do
      "" -> raise("'#{key}' is required")
      value -> value
    end
  end
end
