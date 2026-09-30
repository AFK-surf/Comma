defmodule SalixAgent.Tools.Loops do
  @moduledoc """
  Background Loop tools for the calling Agent
  (docs/salix/tasks-background-execution.md, "Background loops").

  A Loop is a small C program the Agent writes itself, compiled by the
  compiler embedded in spinfoam on this node (`loop.build`), then created
  from the built artifact (`loop.create`) and run for as long as the Agent
  exists. It waits on timers, events and host capabilities and wakes the
  current Session through `agent.notify` only when its condition holds, so
  no model round is spent while nothing happens. There is no grant step: the
  program is the Agent's own, so it may call the whole Loop allowlist under
  the Agent's authorization (`SalixAgent.Loops.Capabilities`).

  Registry shape follows `SalixAgent.Tools.InboundApi`: each entry carries
  its own input schema. Tool functions receive `(args, ctx)` with
  `ctx = %{agent_id, session_id, ...}`; every target is the calling Agent
  and the current Session, never an argument.
  """

  alias SalixAgent.Loops

  @default_artifact_path "/loops/main.elf"

  @normal_auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()
  @build_auto_wait_seconds 60
  @write [safety: "write"]
  @read [safety: "read"]

  @max_source_files 32
  @max_source_bytes 128 * 1024

  @sdk_description "Read this before writing a background loop: the exact spinfoam.h header loop.build compiles against, the eBPF target constraints (4 KiB stack, no heap or libc, handle limits), the handle and error model, and the host capability contract with argument and result shapes, plus a minimal example."

  @build_description "Compile a C background loop with spinfoam's embedded compiler (integer C only: no floating point, no signed division or modulo) and write the ELF into your workspace at `path` (default /loops/main.elf); pass that path to loop.create. Read loop.sdk first for the header and constraints. The program includes \"spinfoam.h\" and defines `SF_MAIN sf_i64 main(void)`; it loops with sf_sleep_ms / sf_event_next, reads its JSON config with sf_config / sf_json_get, calls host capabilities with sf_host_call(name, args_json_handle, timeout_ms), and returns to stop. Host capabilities every loop may call, with no grant step: agent.notify {content, dedup_key} to wake this session (rate limited, use a stable dedup_key per condition), loop.state.put {state} / loop.state.get to checkpoint across restarts (the last checkpoint is passed back as config.state), loop.ack {event_id}, loop.log {message}, plus read-only Salix tools, the external environment tools (env.exec, env.copy, env.process_*, device.*, ssh.*) and decide (classify runtime data), and composio.execute (read or write through a connected provider), and web.http_request (poll or post to an HTTP JSON API) by their canonical name, under your own tool authorization. Use this only when a condition must be watched for a long time without spending model turns; do not use it to run a one-off task."

  @create_description "Create a background loop from an ELF file loop.build wrote into your workspace (`path`) and start it. The loop records the file's path and hash; keep the file as long as the loop exists. Give it a name and a JSON config the program reads. The program may call every loop capability by name with no grant step: agent.notify (the only way it wakes this session), the loop.* checkpoint and ack calls, read tools, the external environment tools (env.exec and the other env.*/device.* tools) to act on a connected device, ssh.* tools for remote SSH hosts, decide for typed runtime judgments, composio.execute for connected provider reads and writes, and web.http_request to poll or post to an HTTP JSON API, each under your own tool authorization; never Salix messaging, memory, workspace or schedule writes. It persists across restarts and node moves, resuming from its last loop.state.put checkpoint. Limits: 20 active loops per agent, 100 per group."

  @list_description "List the background loops owned by this agent with their status (active, paused with a reason, failed), node and secret webhook URL when enabled. Treat webhook URLs as credentials."

  @get_description "Show one background loop: its config, capabilities, checkpoint, runtime state and last failure."

  @pause_description "Pause one background loop: it is stopped and stays paused until loop.resume."

  @resume_description "Resume a paused or failed background loop; it restarts from its last checkpoint."

  @delete_description "Stop and delete one background loop."

  @send_description "Deliver an event to one of this agent's background loops (the program receives it through sf_event_next). Use event_id for idempotent retries."

  @doc "Tool defs in stable registration order."
  def defs do
    [
      {"loop.sdk", @sdk_description, empty_schema(), &__MODULE__.sdk/2, @normal_auto_wait_seconds,
       @read},
      {"loop.build", @build_description, build_schema(), &__MODULE__.build/2,
       @build_auto_wait_seconds, @write},
      {"loop.create", @create_description, create_schema(), &__MODULE__.create/2,
       @normal_auto_wait_seconds, @write},
      {"loop.list", @list_description, empty_schema(), &__MODULE__.list/2,
       @normal_auto_wait_seconds, @read},
      {"loop.get", @get_description, loop_id_schema(), &__MODULE__.get/2,
       @normal_auto_wait_seconds, @read},
      {"loop.pause", @pause_description, loop_id_schema(), &__MODULE__.pause/2,
       @normal_auto_wait_seconds, @write},
      {"loop.resume", @resume_description, loop_id_schema(), &__MODULE__.resume/2,
       @normal_auto_wait_seconds, @write},
      {"loop.delete", @delete_description, loop_id_schema(), &__MODULE__.delete/2,
       @normal_auto_wait_seconds, @write},
      {"loop.webhook",
       "Enable, rotate or revoke this loop's secret inbound URL. Anyone with the URL can POST a JSON object on topic webhook without an Authorization header. Enable preserves an existing URL. loop.list and loop.get return the saved URL.",
       webhook_schema(), &__MODULE__.webhook/2, @normal_auto_wait_seconds, @write},
      {"loop.send", @send_description, send_schema(), &__MODULE__.send_event/2,
       @normal_auto_wait_seconds, @write}
    ]
  end

  # ---- schemas ---------------------------------------------------------------

  def build_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "source" => %{
          "type" => "string",
          "description" =>
            "The C source of the entry translation unit (main.c). Include \"spinfoam.h\"."
        },
        "files" => %{
          "type" => "object",
          "description" =>
            "Optional additional headers: a map of relative file name to UTF-8 content (at most 32 files, 128 KiB in total). Never name a file spinfoam.h.",
          "additionalProperties" => %{"type" => "string"}
        },
        "path" => %{
          "type" => "string",
          "description" =>
            "Workspace path to write the compiled ELF to (default /loops/main.elf). Use one path per loop."
        }
      },
      "required" => ["source"]
    }
  end

  def create_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Workspace path of the ELF written by loop.build (its `path`)."
        },
        "name" => %{
          "type" => "string",
          "description" => "A short name for the loop (at most 80 characters)."
        },
        "config" => %{
          "type" => "object",
          "description" =>
            "JSON the program reads through sf_config (at most 16 KiB). The runtime adds loop_id, incarnation and state (the last checkpoint)."
        }
      },
      "required" => ["path"]
    }
  end

  def empty_schema,
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{},
      "required" => []
    }

  def loop_id_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "loop_id" => %{"type" => "string", "description" => "Loop ID from loop.list."}
      },
      "required" => ["loop_id"]
    }
  end

  def webhook_schema do
    loop_id_schema()
    |> put_in(["properties", "action"], %{
      "type" => "string",
      "enum" => ["enable", "rotate", "revoke"]
    })
    |> Map.put("required", ["loop_id", "action"])
  end

  def send_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "loop_id" => %{"type" => "string", "description" => "Loop ID from loop.list."},
        "topic" => %{
          "type" => "string",
          "description" => "Event topic the program matches on (at most 128 bytes)."
        },
        "payload" => %{"description" => "JSON payload (at most 16 KiB encoded)."},
        "event_id" => %{
          "type" => "string",
          "description" =>
            "Optional idempotency key (at most 128 bytes); defaults to a hash of the payload."
        }
      },
      "required" => ["loop_id", "topic"]
    }
  end

  # ---- actions --------------------------------------------------------------

  @doc false
  def build(args, ctx) do
    source = arg(args, "source")
    if source == "", do: raise("'source' is required")

    extra = args["files"] || args[:files] || %{}
    unless is_map(extra), do: raise("'files' must be an object of file name to content")

    files =
      Map.put(Map.new(extra, fn {k, v} -> {to_string(k), to_string(v)} end), "main.c", source)

    if map_size(files) > @max_source_files, do: raise("at most #{@max_source_files} source files")

    total = files |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()
    if total > @max_source_bytes, do: raise("sources exceed #{@max_source_bytes} bytes")

    path = args["path"] || args[:path] || @default_artifact_path

    case Loops.build(ctx, files, "main.c", path) do
      {:ok, report, nil} ->
        Jason.encode!(report)

      {:ok, report, event} ->
        {Jason.encode!(report), [event]}

      {:error, {:invalid, "path"}} ->
        raise "path must be an absolute workspace path (not a runtime, skill or mount path)"

      {:error, {:host_unavailable, reason}} ->
        raise "background loops unavailable on this node: #{inspect(reason)}"

      {:error, :host_unavailable} ->
        raise "background loops unavailable on this node"

      {:error, :build_timeout} ->
        raise "build did not finish within the budget"

      {:error, reason} ->
        raise "loop.build failed: #{inspect(reason)}"
    end
  end

  @doc false
  def create(args, ctx) do
    path = arg(args, "path")

    attrs = %{
      "path" => path,
      "name" => args["name"] || args[:name],
      "config" => args["config"] || args[:config]
    }

    case Loops.create(ctx, attrs) do
      {:ok, loop} ->
        SalixAgent.IFC.FileLabels.one(Jason.encode!(loop), path, ctx)

      {:error, :artifact_not_found} ->
        raise "no file at #{path} in the workspace; run loop.build with that path first (a file written this turn is visible from the next tool call once its write has landed)"

      {:error, :invalid_artifact} ->
        raise "#{path} is not an ELF object loop.build produced (or exceeds 64 KiB)"

      {:error, {:quota, :agent, limit}} ->
        raise "this agent already has #{limit} active loops; delete or pause one first"

      {:error, {:quota, :group, limit}} ->
        raise "this group already has #{limit} active loops"

      {:error, {:invalid, field}} ->
        raise "invalid #{field}"

      {:error, {:missing, field}} ->
        raise "'#{field}' is required"

      {:error, :missing_session_id} ->
        raise "ctx.session_id is required"

      {:error, reason} ->
        raise "loop.create failed: #{inspect(reason)}"
    end
  end

  @doc false
  def sdk(_args, _ctx) do
    case Loops.Sdk.document() do
      {:ok, document} -> document
      {:error, reason} -> raise "loop.sdk unavailable on this node: #{inspect(reason)}"
    end
  end

  @doc false
  def list(_args, ctx) do
    case Loops.list(ctx.agent_id) do
      {:ok, loops} -> Jason.encode!(loops)
      {:error, reason} -> raise "loop.list failed: #{inspect(reason)}"
    end
  end

  @doc false
  def get(args, ctx) do
    case Loops.get(ctx.agent_id, loop_id!(args)) do
      {:ok, loop} -> Jason.encode!(loop)
      {:error, :not_found} -> raise "loop not found"
      {:error, reason} -> raise "loop.get failed: #{inspect(reason)}"
    end
  end

  @doc false
  def pause(args, ctx) do
    case Loops.pause(ctx.agent_id, loop_id!(args)) do
      {:ok, loop} -> Jason.encode!(loop)
      {:error, :not_found} -> raise "loop not found"
      {:error, reason} -> raise "loop.pause failed: #{inspect(reason)}"
    end
  end

  @doc false
  def resume(args, ctx) do
    case Loops.resume(ctx.agent_id, loop_id!(args)) do
      {:ok, loop} -> Jason.encode!(loop)
      {:error, :not_found} -> raise "loop not found"
      {:error, :already_active} -> raise "loop is already active"
      {:error, :agent_archived} -> raise "loop is paused by archive; unarchive the agent instead"
      {:error, reason} -> raise "loop.resume failed: #{inspect(reason)}"
    end
  end

  @doc false
  def delete(args, ctx) do
    loop_id = loop_id!(args)

    case Loops.delete(ctx.agent_id, loop_id) do
      :ok -> Jason.encode!(%{"status" => "deleted", "loop_id" => loop_id})
      {:error, :not_found} -> raise "loop not found"
      {:error, reason} -> raise "loop.delete failed: #{inspect(reason)}"
    end
  end

  @doc false
  def webhook(args, ctx) do
    unless arg(args, "action") == "revoke" or
             is_function(Application.get_env(:salix_agent, :loop_webhook_url_builder), 1),
           do: raise("loop webhook URL is not configured")

    case Loops.configure_webhook(ctx.agent_id, loop_id!(args), arg(args, "action")) do
      {:ok, loop} -> Jason.encode!(loop)
      {:error, :not_found} -> raise "loop not found"
      {:error, reason} -> raise "loop.webhook failed: #{inspect(reason)}"
    end
  end

  @doc false
  def send_event(args, ctx) do
    event = %{
      "topic" => arg(args, "topic"),
      "payload" => args["payload"] || args[:payload] || %{},
      "event_id" => arg(args, "event_id")
    }

    case Loops.send_event(ctx.agent_id, loop_id!(args), event) do
      {:ok, reply} ->
        Jason.encode!(%{"status" => "accepted", "duplicate" => reply["duplicate"] == true})

      {:error, :not_found} ->
        raise "loop not found"

      {:error, :not_resident} ->
        raise "loop is not running on its owner node yet; retry shortly"

      {:error, :mailbox_full} ->
        raise "loop mailbox is full; retry later"

      {:error, {:not_active, status}} ->
        raise "loop is #{status}"

      {:error, {:invalid_event, field}} ->
        raise "invalid event #{field}"

      {:error, reason} ->
        raise "loop.send failed: #{inspect(reason)}"
    end
  end

  # ---- helpers ---------------------------------------------------------------

  defp loop_id!(args) do
    case arg(args, "loop_id") do
      "" -> raise "'loop_id' is required"
      id -> id
    end
  end

  defp arg(args, key), do: to_string(args[key] || args[String.to_atom(key)] || "")
end
