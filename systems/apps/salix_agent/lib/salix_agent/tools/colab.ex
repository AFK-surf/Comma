defmodule SalixAgent.Tools.Colab do
  @moduledoc """
  `colab.*`: Google Colab GPU compute tools (`colab.status`, `colab.exec`,
  `colab.upload`, `colab.download`, `colab.stop`).

  - Uses `SalixAgent.Colab.Pool` for serialized lease admission and warm reuse.
  - Uses `SalixAgent.Colab.LocalExec` for strict single-owner execution.
  - Labels `status`, `exec`, `upload`, and `download` results with `{group}`
    audience via `SalixAgent.SSH.Audience.label/3`.
  - Pre-verifies `StationToolCalls` requester clearance for `{group}` before
    opening a remote download stream destined for `/drive/...`.
  - No `credential_env` injection in v1.
  """

  require Logger

  defmodule InputError do
    @moduledoc false
    defexception [:message]
  end

  alias SalixAgent.Colab.{LocalExec, Pool}
  alias SalixAgent.{DriveMount, IFC}
  alias SalixAgent.SSH.Audience
  alias SalixIFC.{Codec, Label}

  @short_wait SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @default_exec_seconds 120
  @max_exec_seconds 600
  @default_transfer_seconds 600
  @max_transfer_seconds 600
  @dispatch_grace_ms 15_000
  @max_command_bytes 16_384
  @max_stdin_bytes 1_048_576
  @max_hold_minutes 720
  @gpus ~w(G4 L4 T4 A100 H100 CPU)
  @vm_id_pattern ~S"^colab_[0-9a-fA-F-]{36}$"

  def defs do
    [
      {"colab.status",
       "Return connected Google Colab account summaries (masked email, status, compute units remaining, hourly rate, active VMs) and this session's or Task's own active Colab VM leases.",
       schema(%{}), &__MODULE__.status/2, @short_wait, [safety: "read"]},
      {"colab.exec",
       "Run a command on a Google Colab GPU/CPU VM (default G4 GPU, cwd /content). Omits vm_id to reuse a warm matching VM or allocate one automatically; pass vm_id to target a specific VM. Use hold_minutes (1..720) to keep a VM alive past the 180s idle timeout for background jobs (e.g. nohup ... &). Pass stop_after: true to release the VM immediately after the command finishes.",
       schema(
         %{
           "command" => %{
             "type" => "string",
             "minLength" => 1,
             "maxLength" => @max_command_bytes
           },
           "gpu" => %{"type" => "string", "enum" => @gpus},
           "high_mem" => %{"type" => "boolean"},
           "vm_id" => vm_id_schema(),
           "cwd" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "stdin" => %{"type" => "string", "maxLength" => @max_stdin_bytes},
           "timeout_seconds" => %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => @max_exec_seconds
           },
           "hold_minutes" => %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => @max_hold_minutes
           },
           "stop_after" => %{"type" => "boolean"}
         },
         ["command"]
       ), &__MODULE__.exec/2, @short_wait, [safety: "write"]},
      {"colab.upload",
       "Stream one file (up to 1 GiB) from the Agent workspace or /drive/... (source) to a Google Colab VM (destination, default /content/<basename>). Atomic commit with remote byte-count verification; overwrite defaults to false.",
       schema(
         %{
           "source" => %{"type" => "string", "minLength" => 1},
           "destination" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "vm_id" => vm_id_schema(),
           "gpu" => %{"type" => "string", "enum" => @gpus},
           "high_mem" => %{"type" => "boolean"},
           "overwrite" => %{"type" => "boolean"},
           "timeout_seconds" => %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => @max_transfer_seconds
           }
         },
         ["source"]
       ), &__MODULE__.upload/2, @short_wait, [safety: "write"]},
      {"colab.download",
       "Stream one regular file (up to 1 GiB) from a Google Colab VM (vm_id, source) into the Agent workspace or /drive/... (destination). Fails cleanly with zero partial file persisted if the remote command fails; overwrite defaults to false.",
       schema(
         %{
           "vm_id" => vm_id_schema(),
           "source" => %{"type" => "string", "minLength" => 1, "maxLength" => 4096},
           "destination" => %{"type" => "string", "minLength" => 1},
           "overwrite" => %{"type" => "boolean"},
           "timeout_seconds" => %{
             "type" => "integer",
             "minimum" => 1,
             "maximum" => @max_transfer_seconds
           }
         },
         ["vm_id", "source", "destination"]
       ), &__MODULE__.download/2, @short_wait, [safety: "write"]},
      {"colab.stop",
       "Stop and unassign a Google Colab VM by vm_id so compute-unit billing ends. Always callable even if the backing Colab account was disabled.",
       schema(%{"vm_id" => vm_id_schema()}, ["vm_id"]), &__MODULE__.stop/2, @short_wait,
       [safety: "write"]}
    ]
  end

  @doc "Dispatcher timeout for one `colab.*` call."
  @spec dispatch_timeout_ms(String.t(), map()) :: pos_integer()
  def dispatch_timeout_ms("colab.exec", args) do
    bounded(args, "timeout_seconds", @default_exec_seconds, @max_exec_seconds) * 1_000 +
      @dispatch_grace_ms
  end

  def dispatch_timeout_ms(name, args) when name in ["colab.upload", "colab.download"] do
    bounded(args, "timeout_seconds", @default_transfer_seconds, @max_transfer_seconds) * 1_000 +
      @dispatch_grace_ms
  end

  def dispatch_timeout_ms(_name, _args), do: 45_000 + @dispatch_grace_ms

  # ---- handlers ----

  def status(_args, ctx) do
    ctx = with_group_id(ctx)

    case Pool.status(ctx) do
      {:ok, result} -> Audience.label(ok(result), ctx, nil)
      {:error, reason} -> failure(reason)
    end
  end

  def exec(args, ctx) do
    ctx = with_group_id(ctx)

    try do
      command = string!(args, "command")
      stdin = Map.get(args, "stdin") || ""
      cwd = Map.get(args, "cwd") || "/content"
      seconds = bounded(args, "timeout_seconds", @default_exec_seconds, @max_exec_seconds)
      hold_minutes = optional_bounded(args, "hold_minutes", 1, @max_hold_minutes)
      stop_after? = Map.get(args, "stop_after") == true

      if byte_size(command) > @max_command_bytes,
        do: raise(InputError, "colab.exec command is too long")

      if String.contains?(command, <<0>>),
        do: raise(InputError, "colab.exec command contains a NUL byte")

      if byte_size(stdin) > @max_stdin_bytes,
        do: raise(InputError, "colab.exec stdin exceeds 1 MiB")

      if String.contains?(cwd, <<0>>),
        do: raise(InputError, "colab.exec cwd contains a NUL byte")

      acquire_opts = %{
        tool_name: "colab.exec",
        vm_id: optional_vm_id!(args),
        gpu: gpu!(args),
        high_mem: Map.get(args, "high_mem") == true
      }

      with {:ok, lease} <- Pool.acquire(ctx, acquire_opts),
           op_spec = %{
             op: :exec,
             vm_id: lease.vm_id,
             tenant_id: lease.tenant_id,
             group_id: lease.group_id,
             owner_scope: lease.owner_scope,
             command: command,
             cwd: cwd,
             stdin: stdin,
             timeout_ms: seconds * 1_000,
             hold_minutes: hold_minutes
           },
           {:ok, exec_result} <- LocalExec.execute(lease, op_spec) do
        payload =
          exec_result
          |> Map.put("vm_id", lease.vm_id)
          |> Map.put("accelerator", lease.accelerator)
          |> maybe_stop_after(ctx, lease.vm_id, stop_after?)

        Audience.label(ok(payload), ctx, nil)
      else
        {:error, reason} -> Audience.label(failure(reason), ctx, nil)
      end
    rescue
      e in InputError ->
        Audience.label(failure({:invalid_argument, e.message}), ctx, nil)

      e ->
        Logger.warning("colab_tool_exception",
          tool: "colab.exec",
          exception: inspect(e.__struct__)
        )

        Audience.label(failure(:operation_failed), ctx, nil)
    end
  end

  def upload(args, ctx) do
    ctx = with_group_id(ctx)

    try do
      source = string!(args, "source")
      destination = Map.get(args, "destination") || default_upload_destination(source)
      overwrite? = Map.get(args, "overwrite") == true
      seconds = bounded(args, "timeout_seconds", @default_transfer_seconds, @max_transfer_seconds)

      acquire_opts = %{
        tool_name: "colab.upload",
        vm_id: optional_vm_id!(args),
        gpu: gpu!(args),
        high_mem: Map.get(args, "high_mem") == true
      }

      with {:ok, lease} <- Pool.acquire(ctx, acquire_opts),
           op_spec = %{
             op: :upload,
             vm_id: lease.vm_id,
             tenant_id: lease.tenant_id,
             group_id: lease.group_id,
             owner_scope: lease.owner_scope,
             ctx: ctx,
             source: source,
             destination: destination,
             overwrite: overwrite?,
             timeout_ms: seconds * 1_000
           },
           {:ok, result} <- LocalExec.execute(lease, op_spec) do
        Audience.label(ok(Map.put(result, "vm_id", lease.vm_id)), ctx, nil)
      else
        {:error, reason} -> Audience.label(failure(reason), ctx, nil)
      end
    rescue
      e in InputError ->
        Audience.label(failure({:invalid_argument, e.message}), ctx, nil)

      e ->
        Logger.warning("colab_tool_exception",
          tool: "colab.upload",
          exception: inspect(e.__struct__)
        )

        Audience.label(failure(:operation_failed), ctx, nil)
    end
  end

  def download(args, ctx) do
    ctx = with_group_id(ctx)

    try do
      vm_id = required_vm_id!(args)
      source = string!(args, "source")
      destination = string!(args, "destination")
      overwrite? = Map.get(args, "overwrite") == true
      seconds = bounded(args, "timeout_seconds", @default_transfer_seconds, @max_transfer_seconds)

      with :ok <- precheck_station_drive_clearance(ctx, destination),
           {:ok, lease} <- Pool.acquire(ctx, %{tool_name: "colab.download", vm_id: vm_id}),
           op_spec = %{
             op: :download,
             vm_id: lease.vm_id,
             tenant_id: lease.tenant_id,
             group_id: lease.group_id,
             owner_scope: lease.owner_scope,
             ctx: Audience.download_ctx(ctx, nil),
             source: source,
             destination: destination,
             overwrite: overwrite?,
             timeout_ms: seconds * 1_000
           },
           {:ok, value, events} <- LocalExec.execute(lease, op_spec) do
        payload = Map.put(value, "vm_id", lease.vm_id)
        Audience.label({Jason.encode!(payload), events}, ctx, nil)
      else
        {:error, reason} -> Audience.label(failure(reason), ctx, nil)
      end
    rescue
      e in InputError ->
        Audience.label(failure({:invalid_argument, e.message}), ctx, nil)

      e ->
        Logger.warning("colab_tool_exception",
          tool: "colab.download",
          exception: inspect(e.__struct__)
        )

        Audience.label(failure(:operation_failed), ctx, nil)
    end
  end

  def stop(args, ctx) do
    ctx = with_group_id(ctx)
    vm_id = required_vm_id!(args)

    case Pool.stop_vm(ctx, vm_id) do
      {:ok, result} -> ok(result)
      {:error, reason} -> failure(reason)
    end
  end

  # ---- StationToolCalls /drive/... pre-check ----

  # For `/drive/...` downloads from `StationToolCalls`, pre-verify that the
  # Task's requester is cleared for `{group}` BEFORE opening the remote stream
  # so a refused return check never leaves an unintended Drive write behind.
  defp precheck_station_drive_clearance(ctx, destination) do
    station_id = Map.get(ctx, :station_device_id) || Map.get(ctx, "station_device_id")
    mode = IFC.mode(Map.get(ctx, :ifc_mode))

    if is_binary(station_id) and station_id != "" and DriveMount.matches?(destination) and
         mode in [:enforce, :easy] do
      verify_group_reader(ctx, mode)
    else
      :ok
    end
  end

  defp verify_group_reader(ctx, mode) do
    group_id = to_string(Map.get(ctx, :group_id) || "")
    tenant_id = to_string(Map.get(ctx, :tenant_id) || "")
    origin = Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin")

    case IFC.principal(origin) do
      nil ->
        {:error, :label_not_this_task}

      person ->
        label = Label.new([{:group, group_id}])
        encoded = Codec.encode_label(label)

        if mode == :easy and
             not SalixIFC.easy_protected?(
               [%SalixIFC.Item{ref: "result", label: label, integrity: :data}],
               :context
             ) do
          :ok
        else
          request = %{
            "tenant_id" => tenant_id,
            "group_id" => group_id,
            "agent_id" => to_string(Map.get(ctx, :agent_id) || ""),
            "requester" => Codec.encode_principal!(person),
            "destination" => %{"kind" => "agent_private"},
            "atoms" => encoded,
            "trusted_origin" => origin,
            "now" => SystemsClock.system_time(:millisecond)
          }

          case IFC.resolve(request) do
            {:ok, reply} ->
              facts = Codec.decode_facts(reply)

              allowed? =
                if mode == :easy,
                  do: SalixIFC.easy_reader?(person, label, facts) == true,
                  else: SalixIFC.reader?(person, label, facts) == true

              if allowed?, do: :ok, else: {:error, :label_not_this_task}

            {:error, _} ->
              {:error, :label_not_this_task}
          end
        end
    end
  rescue
    _ -> {:error, :label_not_this_task}
  end

  # ---- helpers ----

  defp maybe_stop_after(payload, _ctx, _vm_id, false), do: payload

  defp maybe_stop_after(payload, ctx, vm_id, true) do
    case Pool.stop_vm(ctx, vm_id) do
      {:ok, stop_info} ->
        Map.put(payload, "stop_result", stop_info)

      {:error, reason} ->
        {code, _msg, _details} = diagnostic(reason)
        Map.put(payload, "stop_error", code)
    end
  end

  defp default_upload_destination(source) do
    base =
      source
      |> Path.basename()
      |> case do
        "" -> "upload.bin"
        name -> name
      end

    "/content/" <> base
  end

  defp with_group_id(ctx) do
    case Map.get(ctx, :group_id) do
      g when is_binary(g) and g != "" ->
        ctx

      _ ->
        case Map.get(ctx, :agent_id) do
          agent_id when is_binary(agent_id) and agent_id != "" ->
            Map.put(ctx, :group_id, SalixStore.Ids.group_id_from_agent!(agent_id))

          _ ->
            ctx
        end
    end
  rescue
    _ -> ctx
  end

  defp gpu!(args) do
    case Map.get(args, "gpu") do
      nil ->
        "G4"

      gpu when gpu in @gpus ->
        gpu

      other ->
        raise InputError,
              "colab: unsupported gpu #{inspect(other)}; expected one of #{Enum.join(@gpus, ", ")}"
    end
  end

  defp optional_vm_id!(args) do
    case Map.get(args, "vm_id") do
      nil -> nil
      "" -> nil
      id -> validate_vm_id!(id)
    end
  end

  defp required_vm_id!(args) do
    args |> string!("vm_id") |> validate_vm_id!()
  end

  defp validate_vm_id!(id) when is_binary(id) do
    if Regex.match?(~r/^colab_[0-9a-fA-F-]{36}$/, id),
      do: id,
      else: raise(InputError, "colab: invalid vm_id")
  end

  defp string!(args, key) do
    case Map.get(args, key) do
      val when is_binary(val) and val != "" -> val
      _ -> raise InputError, "colab: #{key} is required"
    end
  end

  defp int(args, key, default) do
    case Map.get(args, key) do
      v when is_integer(v) -> v
      _ -> default
    end
  end

  defp bounded(args, key, default, max_val),
    do: args |> int(key, default) |> max(1) |> min(max_val)

  defp optional_bounded(args, key, min_val, max_val) do
    case Map.get(args, key) do
      v when is_integer(v) -> v |> max(min_val) |> min(max_val)
      _ -> nil
    end
  end

  defp ok(value), do: Jason.encode!(value)

  defp failure(reason) do
    {code, message, details} = diagnostic(reason)

    payload =
      Map.merge(%{"code" => code, "message" => message}, details)

    {:tool_failure, Jason.encode!(%{"ok" => false, "error" => payload}), code, "user_reportable",
     message, []}
  end

  defp diagnostic(:no_colab_accounts) do
    {"no_colab_accounts",
     "No active Google Colab account is connected for this workspace. Install and connect the Google Colab plugin (or call plugin.request_install with plugin_id: \"google-colab\").",
     %{}}
  end

  defp diagnostic(:plugin_disabled) do
    {"plugin_disabled",
     "The Google Colab plugin is not enabled in this workspace. Call plugin.request_install with plugin_id: \"google-colab\" or ask the user to enable it in Plugins.",
     %{}}
  end

  defp diagnostic(:account_not_active) do
    {"account_unavailable",
     "The Google Colab account backing this workspace is not active. Reconnect it in Plugins.",
     %{}}
  end

  defp diagnostic(:colab_capacity) do
    {"colab_capacity",
     "No Google Colab GPU capacity is currently available across connected accounts. Try a different GPU type or retry shortly.",
     %{}}
  end

  defp diagnostic(:owner_vm_limit) do
    {"owner_vm_limit",
     "This session/Task already holds the maximum of 4 concurrent Colab VMs. Stop an unused VM with colab.stop first.",
     %{}}
  end

  defp diagnostic(:vm_not_found) do
    {"vm_not_found", "No Colab VM with that vm_id exists in this session or Task scope.", %{}}
  end

  defp diagnostic(:vm_not_active) do
    {"vm_not_active", "That Colab VM is not in an active state.", %{}}
  end

  defp diagnostic(:account_unavailable) do
    {"account_unavailable",
     "The Google Colab account backing this VM is disabled or requires re-authentication. You may still call colab.stop to release the VM.",
     %{}}
  end

  defp diagnostic(:guest_restricted) do
    {"guest_restricted",
     "Google Colab tools are not available in guest or router-only workspaces.", %{}}
  end

  defp diagnostic(:invalid_owner_scope) do
    {"invalid_owner_scope", "Colab tools require a valid Agent session or Task context.", %{}}
  end

  defp diagnostic(:ssh_session_limit) do
    {"ssh_session_limit",
     "Google Colab returned HTTP 429 (SSH session limit reached on this runtime). Wait briefly and retry.",
     %{}}
  end

  defp diagnostic({:host_key_mismatch, stored, presented}) do
    {"host_key_mismatch",
     "The Colab runtime presented a different SSH host key than pinned on first connect. Call colab.stop and acquire a new VM.",
     %{"pinned_fingerprint" => stored, "presented_fingerprint" => presented}}
  end

  defp diagnostic(:owner_unavailable) do
    {"owner_unavailable",
     "The node owning this Colab VM tunnel is currently unavailable. Call colab.stop to terminate this VM or omit vm_id to acquire a new one.",
     %{}}
  end

  defp diagnostic(:result_unknown) do
    {"result_unknown",
     "The cross-node request to the VM's owning node failed after dispatch; the remote operation outcome is unknown and was not replayed.",
     %{}}
  end

  defp diagnostic(:vm_terminated_externally) do
    {"vm_terminated_externally",
     "This Colab VM was terminated externally by Google Colab and has been cleaned up. Omit vm_id to acquire a new VM.",
     %{}}
  end

  defp diagnostic(:platform_unavailable) do
    {"platform_unavailable",
     "Google Colab OAuth client is currently unavailable on this platform.", %{}}
  end

  defp diagnostic(:label_not_this_task) do
    {"label_not_this_task",
     "This Task's requester is not cleared to read Group-labelled content from Colab into Drive.",
     %{}}
  end

  defp diagnostic({:remote_exists, path}) do
    {"remote_exists",
     "#{path} already exists on the Colab VM. Pass overwrite: true to replace it.",
     %{"path" => path}}
  end

  defp diagnostic({:remote_is_directory, path}) do
    {"remote_is_directory", "#{path} is a directory on the Colab VM.", %{"path" => path}}
  end

  defp diagnostic({:remote_not_found, path}) do
    {"remote_not_found", "Remote regular file not found: #{path}.", %{"path" => path}}
  end

  defp diagnostic({:destination_exists, path}) do
    {"destination_exists", "#{path} already exists. Pass overwrite: true to replace it.",
     %{"path" => path}}
  end

  defp diagnostic({:vfs_not_found, path}) do
    {"vfs_not_found", "No such file: #{path}.", %{"path" => path}}
  end

  defp diagnostic({:too_large, max}) do
    {"too_large", "File exceeds the #{max}-byte transfer limit.", %{"max_bytes" => max}}
  end

  defp diagnostic({:size_mismatch, expected}) do
    {"size_mismatch",
     "Remote upload size verification failed (expected #{expected} bytes); partial file was discarded.",
     %{"expected_bytes" => expected}}
  end

  defp diagnostic({:size_mismatch, expected, sent}) do
    {"size_mismatch",
     "Upload stream ended after #{sent} bytes (expected #{expected}); partial file was discarded.",
     %{"expected_bytes" => expected, "sent_bytes" => sent}}
  end

  defp diagnostic(:timeout) do
    {"timeout", "The Colab operation timed out.", %{}}
  end

  defp diagnostic(:unassign_failed) do
    {"unassign_failed",
     "Google Colab could not confirm VM unassignment right now. Retry colab.stop shortly.", %{}}
  end

  defp diagnostic(:assign_in_progress) do
    {"assign_in_progress",
     "This Colab VM is still being allocated. Wait briefly and retry colab.stop.", %{}}
  end

  defp diagnostic({:http_error, status, _body}) when is_integer(status) do
    {"colab_http_error", "Google Colab returned HTTP #{status}.", %{"status" => status}}
  end

  defp diagnostic({:remote_exit, status, signal, err_text}) do
    details =
      %{"exit_status" => status, "exit_signal" => signal, "stderr" => err_text}
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    {"remote_exit", "The remote Colab command exited with an error.", details}
  end

  defp diagnostic({:remote_write_failed, status_or_sig, err_text})
       when is_integer(status_or_sig) or is_binary(status_or_sig) do
    details =
      %{"reason" => status_or_sig, "stderr" => err_text}
      |> Map.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    {"remote_write_failed", "Failed to write file on the Colab VM.", details}
  end

  defp diagnostic({:remote_write_failed, _reason}) do
    {"remote_write_failed", "Failed to write file on the Colab VM.", %{}}
  end

  defp diagnostic({:remote_read_failed, _reason}) do
    {"remote_read_failed", "Failed to read file from the Colab VM.", %{}}
  end

  defp diagnostic({:vfs_read_failed, _reason}) do
    {"vfs_read_failed", "Failed to read the source file.", %{}}
  end

  defp diagnostic({:vfs_write_failed, _reason}) do
    {"vfs_write_failed", "Failed to write the destination file.", %{}}
  end

  defp diagnostic(:invalid_remote_path) do
    {"invalid_remote_path", "The remote file path is invalid.", %{}}
  end

  defp diagnostic(:invalid_response) do
    {"invalid_response", "Google Colab returned an unexpected response.", %{}}
  end

  defp diagnostic(:invalid_proxy_url) do
    {"invalid_proxy_url", "Google Colab returned an invalid runtime proxy URL.", %{}}
  end

  defp diagnostic(:exec_refused) do
    {"exec_refused", "The Colab runtime refused to start the command.", %{}}
  end

  defp diagnostic(:tunnel_timeout) do
    {"tunnel_timeout", "Timed out connecting to the Colab runtime.", %{}}
  end

  defp diagnostic(:tunnel_closed) do
    {"tunnel_closed", "The connection to the Colab runtime was closed.", %{}}
  end

  defp diagnostic(:refresh_in_progress) do
    {"refresh_in_progress", "Google Colab credentials are refreshing. Retry shortly.", %{}}
  end

  defp diagnostic(reason) when reason in [:invalid_grant, :authorization_unavailable] do
    {"authorization_unavailable",
     "The Google Colab account requires re-authentication in Settings.", %{}}
  end

  defp diagnostic(:token_refresh_failed) do
    {"token_refresh_failed", "Failed to refresh Google Colab credentials. Retry shortly.", %{}}
  end

  defp diagnostic({:invalid_argument, message}) when is_binary(message) do
    {"invalid_argument", message, %{}}
  end

  defp diagnostic(:unassign_tracking_failed) do
    {"unassign_tracking_failed",
     "Failed to record a late Google Colab runtime assignment for cleanup.", %{}}
  end

  defp diagnostic(_reason) do
    {"colab_error", "Colab operation failed", %{}}
  end

  defp vm_id_schema, do: %{"type" => "string", "pattern" => @vm_id_pattern}

  defp schema(properties, required \\ []) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }
  end
end
