defmodule SalixAgent.Tools.Stations do
  @moduledoc """
  Station tools: discover the Comma stations of the agent's workspace,
  inspect their files, start and stop their processes, and delegate a task to
  a station chat on behalf of the requesting member.

  Commands, process I/O and file copies use the existing environment tools
  with `device_id` `"station:<id>"` and environment `"station"`
  (`SalixAgent.Stations.Env`). These tools cover the station ops that have no
  environment-tool equivalent. All calls go through the `SalixAgent.Stations`
  port, which resolves the workspace and requester from the ctx; the model
  never supplies either.
  """

  alias SalixAgent.Stations
  alias SalixAgent.Tools.AsyncPolicy

  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @write_opts [safety: "write"]
  # Text returned inline to the model; larger or binary files go through env.copy.
  @max_inline_read 256 * 1024

  def defs do
    [
      {"station.list",
       "List this workspace's Stations, including managed VMM Stations. Router and Worker use the same member-authorized tools. The still.fail stations below are for anyone who asked, member or not: list them, read their chats and usage, write in their chats and give them Tasks. Use a station's device_id with environment \"station\" in env.exec, env.process_list, env.process_write, env.process_tail and env.copy; use station.fs, station.process and station.session for station files, processes and chats. Commands and relative files default to this Agent conversation's own working directory. Stations share resources with other Tasks: keep your files there, use a new session for delegated work, and stop only processes you started. Do not change shared logins or kill other Tasks. It also lists, as stillfail_stations, the still.fail stations connected through Comma's still.fail plugin, each a whole still.fail workspace (workspace_id, task_models) that takes no env.* or station.* call, with how to see what their workspace is doing and give one a Task.",
       &__MODULE__.list/2, @normal_auto_wait_seconds},
      {"station.fs",
       "Inspect files on a station. Relative paths use this Agent conversation's working directory, as env.exec does without working_dir. Absolute paths address shared files. action=list (directory entries), stat (one path) or read (text up to 256 KiB, optionally from offset). Copy larger or binary files with env.copy and write files with env.copy from vfs.",
       &__MODULE__.fs/2, @normal_auto_wait_seconds},
      {"station.process",
       "Start or stop a long-lived process on a station. action=start defaults to this Agent conversation's working directory and returns a process_id; pass it as process_name to env.process_tail and env.process_write with the station's device_id and environment \"station\". action=stop ends it.",
       &__MODULE__.process/2, @normal_auto_wait_seconds, @write_opts},
      {"station.session",
       "Delegate work to a station's own agent chat on behalf of the member who asked. action=start creates a chat from a prompt and returns its thread; action=say adds a message to that thread; action=status reports running, waiting, need_human, all_done or idle with a summary. Start a new chat for independent work. Its workspace is separate from other Task and chat workspaces. Do not send into another Task's thread. The chat runs on the station and continues after this call.",
       &__MODULE__.session/2, @normal_auto_wait_seconds, @write_opts}
    ]
  end

  @stillfail_note "Each still.fail station (device_kind stillfail) is a whole connected still.fail " <>
                    "workspace, connected through Comma's still.fail plugin. It is not a Station: it " <>
                    "runs no command and serves no file, so do not address it with env.*, station.fs, " <>
                    "station.process or station.session, and do not hand that to a Worker. See what its " <>
                    "workspace is doing (its chats, who each waits for and why) with " <>
                    "im_api.internal.station_task.list, source stillfail and its device_id (query finds " <>
                    "a chat by words of its title or note), and its usage with " <>
                    "im_api.internal.usage.query, source stillfail and its device_id. Read a chat with " <>
                    "im_api.internal.read_conversation and its task_id as conversation_id; the Router " <>
                    "writes in one with im_api.internal.send_message. To have it do work, such as reading " <>
                    "its own projects or files, create a Task with im_api.internal.task.create and runs_on " <>
                    "{\"kind\":\"station\",\"device_id\":<its device_id>}, and omit model: an agent of " <>
                    "that workspace does the work there on the workspace's own default model. Give model " <>
                    "{\"kind\":\"runtime\",\"provider\":\"claude\"|\"codex\"} only to choose a runtime " <>
                    "its task_models lists, with a model id only from that list. It must be " <>
                    "connected. When several are connected and the request does not say which, ask which " <>
                    "with a question card."

  @doc "How to reach a still.fail station, for a tool that was pointed at one."
  def stillfail_note, do: @stillfail_note

  @doc false
  def list(_args, ctx) do
    case Stations.list(ctx) do
      {:ok, stations} ->
        %{
          "stations" =>
            Enum.map(stations, fn station ->
              station
              |> Map.take(["name", "online", "version"])
              |> Map.put("station_id", station["id"])
              |> Map.put("device_id", Stations.target_prefix() <> station["id"])
              |> Map.put("environment", "station")
            end)
        }
        |> put_stillfail(ctx)
        |> Jason.encode!()

      # The still.fail stations are listed for whoever asked, even when the
      # roster is not theirs to use.
      {:error, reason} ->
        case put_stillfail(%{}, ctx) do
          %{"stillfail_stations" => _} = result ->
            result
            |> Map.put("stations", [])
            |> Map.put("stations_unavailable", Stations.describe_error(reason))
            |> Jason.encode!()

          _none ->
            raise Stations.describe_error(reason)
        end
    end
  end

  # The Group's still.fail stations, which are Devices, not Stations of the
  # roster. A workspace without one gets neither key; a failed read of them
  # leaves the roster's answer as it is.
  defp put_stillfail(result, ctx) do
    case Stations.stillfail_stations(ctx) do
      {:ok, [_ | _] = stillfail} ->
        result
        |> Map.put(
          "stillfail_stations",
          Enum.map(stillfail, fn station ->
            base = %{
              "device_id" => station["id"],
              "name" => station["name"],
              "workspace_id" => station["workspace_id"],
              "connected" => station["connected"],
              "connected_at" => station["connected_at"],
              "task_models" => station["task_models"]
            }

            if is_binary(station["owner_email"]),
              do: Map.put(base, "owner_email", station["owner_email"]),
              else: base
          end)
        )
        |> Map.put("stillfail_note", @stillfail_note)

      _none ->
        result
    end
  end

  @doc false
  def fs(args, ctx) do
    station = station_id!(args)
    path = required!(args, "path")

    case arg(args, "action") do
      "list" ->
        Jason.encode!(call!(ctx, station, "fs.list", %{"path" => path}))

      "stat" ->
        Jason.encode!(call!(ctx, station, "fs.stat", %{"path" => path}))

      "read" ->
        offset = non_negative!(args, "offset", 0)
        length = min(non_negative!(args, "length", @max_inline_read), @max_inline_read)

        result =
          call!(ctx, station, "fs.read", %{"path" => path, "offset" => offset, "length" => length})

        content =
          case Base.decode64(result["content_base64"] || "") do
            {:ok, content} -> content
            :error -> raise "station returned invalid base64 data"
          end

        unless String.valid?(content),
          do: raise("#{path} is not UTF-8 text; copy it with env.copy instead")

        Jason.encode!(%{
          "path" => path,
          "offset" => offset,
          "content" => content,
          "size" => result["size"],
          "eof" => result["eof"] == true
        })

      _ ->
        raise "action must be list, stat or read"
    end
  end

  @doc false
  def process(args, ctx) do
    station = station_id!(args)

    case arg(args, "action") do
      "start" ->
        call_args =
          %{"command" => required!(args, "command")}
          |> put_present("cwd", arg(args, "cwd"))

        result = call!(ctx, station, "process.start", call_args)

        Jason.encode!(%{
          "process_id" => result["process_id"],
          "device_id" => Stations.target_prefix() <> station,
          "environment" => "station"
        })

      "stop" ->
        Jason.encode!(
          call!(ctx, station, "process.stop", %{"process_id" => required!(args, "process_id")})
        )

      _ ->
        raise "action must be start or stop"
    end
  end

  @doc false
  def session(args, ctx) do
    station = station_id!(args)

    {op, call_args} =
      case arg(args, "action") do
        "start" ->
          {"session.start",
           %{"prompt" => required!(args, "prompt")}
           |> put_present("title", arg(args, "title"))
           |> put_present("runtime", arg(args, "runtime"))}

        "say" ->
          {"session.say",
           %{"thread" => required!(args, "thread"), "text" => required!(args, "text")}}

        "status" ->
          {"session.status", %{"thread" => required!(args, "thread")}}

        _ ->
          raise "action must be start, say or status"
      end

    Jason.encode!(call!(ctx, station, op, call_args))
  end

  # A still.fail station's device id is no Station: say what reaches it
  # instead of the roster's refusal. Read only on a failed call.
  defp call!(ctx, station, op, args) do
    case Stations.call(ctx, station, op, args) do
      {:ok, result} ->
        result

      {:error, reason} ->
        if stillfail_station?(ctx, station),
          do: raise("#{station} is a connected still.fail workspace. " <> @stillfail_note),
          else: raise(Stations.describe_error(reason))
    end
  end

  defp stillfail_station?(ctx, device_id) do
    case Stations.stillfail_stations(ctx) do
      {:ok, stations} -> Enum.any?(stations, &(&1["id"] == device_id))
      _ -> false
    end
  end

  # Accepts the bare station id or its `station:<id>` device id.
  defp station_id!(args) do
    raw = required!(args, "station_id")
    Stations.station_id(raw) || raw
  end

  defp non_negative!(args, key, default) do
    case raw(args, key) do
      nil -> default
      n when is_integer(n) and n >= 0 -> n
      _ -> raise "#{key} must be a non-negative integer"
    end
  end

  defp required!(args, key) do
    case String.trim(arg(args, key)) do
      "" -> raise "'#{key}' is required"
      value -> value
    end
  end

  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp arg(args, key), do: to_string(raw(args, key) || "")
  defp raw(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))
end
