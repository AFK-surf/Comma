defmodule SalixAgent.CollaborationPolicy do
  @moduledoc """
  Fail-closed tool allowlist for the Worker of a Collaborative Task.

  A Collaborative Task is hosted in one person's Group and shared with people
  who are not members of it. Its Worker is an Agent of its own (`purpose`
  `collaboration_worker`), not the Group's Task agent: it has no memory of the
  host's other work, and it reaches nothing of the Group. It cannot read or
  write the Group's files, memory, Drive, browser sign-ins, connected accounts,
  MCP servers, stations or other conversations, and it cannot address other
  Agents. It works with what the members write in the Task and with the public
  web, and replies in its own Task (`im_api.internal.send_message` takes only
  a Conversation the Agent is a participant of). New tools stay unavailable to it until this list names them.

  `SalixAgent.AgentControl` keeps the purpose immutable, so the purpose selects
  this policy for every round and every tool call of the Agent.
  """

  @purpose "collaboration_worker"
  @sandbox_purpose "collaboration_sandbox_worker"

  @allowed ~w(
    help
    tool_call.get_result
    tool_call.get_status
    tool_call.cancel
    web.search
    web.read_pages
    question.request
    ui.create
    im_api.internal.send_message
    im_api.internal.task.create
    im_api.internal.apps.create
    loop.sdk
    loop.build
    loop.create
    loop.get
    loop.pause
    loop.resume
    loop.delete
    fs.read_file
    fs.write_file
    fs.edit_file
    fs.list_files
    fs.stat_file
    fs.delete_file
    fs.copy_file
    fs.move_file
  )

  # Fail-closed allowlist for the Task agent of a Collaborative Task's sandbox
  # sub-tasks (`purpose: "collaboration_sandbox_worker"`). Sandbox containers
  # receive attached files via `task.put`/`task.file` and return outputs via
  # `task.post`/`task.posted_file`; callback Salix tools stay strictly limited
  # to public web search/read and tool status helpers — no Salix VFS (`fs.*`),
  # no IM APIs (`im_api.*`), no Loops, no Memory, no MCP, no host `env.*`.
  @sandbox_allowed ~w(
    help
    tool_call.get_result
    tool_call.get_status
    tool_call.cancel
    web.search
    web.read_pages
  )

  # The Task's own folder in the Worker's workspace: the Worker is an Agent of
  # this Task alone, so its workspace holds nothing of the host's. The mounts
  # the file tools also reach (`/drive`, the host's Comma Drive, and the
  # `/.runtime` projections) stay out: writes stay in `/task/`, while
  # `/.conversation-attachments/` is read-only so the Worker can inspect and
  # copy files returned by its own sandbox sub-tasks into `/task/`.
  @task_root "/task/"
  @attachments_root "/.conversation-attachments/"
  @max_task_create_files 20
  @path_args ~w(path prefix from to)

  @doc "The purpose that marks a Collaborative Task's Worker."
  def purpose, do: @purpose

  @doc "The purpose that marks a Collaborative Task Group's sandbox sub-task Worker."
  def sandbox_purpose, do: @sandbox_purpose

  @doc "The read-only folder where incoming sub-task attachments are materialized."
  def attachments_root, do: @attachments_root

  def collaboration_purpose?(purpose), do: purpose in [@purpose, @sandbox_purpose]

  def policy_for_purpose(@purpose), do: :restricted
  def policy_for_purpose(@sandbox_purpose), do: :sandbox_restricted
  def policy_for_purpose(_purpose), do: :ordinary

  def allowed_tool?(ctx, name) do
    case policy(ctx) do
      :restricted -> to_string(name || "") in @allowed
      :sandbox_restricted -> to_string(name || "") in @sandbox_allowed
      :ordinary -> true
      :unresolved -> false
    end
  end

  @doc "The folder a Collaborative Task's Worker reads and writes files in."
  def task_root, do: @task_root

  @doc """
  Whether a call's arguments stay where the round may reach: a Collaborative
  Task's Worker keeps file writes in `task_root/0`, may read/stat or copy from
  `attachments_root/0` into `task_root/0`, may attach only `task_root/0` files
  to sandbox sub-tasks, and may send only `task_root/0` or `attachments_root/0`
  attachments. A Collaborative Task sandbox Worker stays on its minimal public
  allowlist. Any other round passes.
  """
  def allowed_call?(ctx, name, args) do
    name = to_string(name || "")

    case policy(ctx) do
      :ordinary ->
        true

      :sandbox_restricted ->
        is_map(args) and name in @sandbox_allowed

      :restricted ->
        cond do
          not is_map(args) -> false
          String.starts_with?(name, "fs.") -> task_paths?(name, args)
          name == "im_api.internal.task.create" -> allowed_task_create_args?(args)
          name == "im_api.internal.send_message" -> allowed_send_message_args?(args)
          true -> true
        end

      :unresolved ->
        false
    end
  end

  defp task_paths?("fs.read_file", args), do: readable_path?(arg_value(args, "path"))
  defp task_paths?("fs.stat_file", args), do: readable_path?(arg_value(args, "path"))

  defp task_paths?("fs.copy_file", args) do
    readable_path?(arg_value(args, "from")) and task_path?(arg_value(args, "to"))
  end

  defp task_paths?(name, args) do
    paths = for key <- @path_args, Map.has_key?(args, key), do: args[key]
    # Listing names its folder: an empty prefix would list every mount.
    required =
      case name do
        "fs.list_files" -> ["prefix"]
        "fs.move_file" -> ["from", "to"]
        _other -> []
      end

    Enum.all?(required, &Map.has_key?(args, &1)) and paths != [] and
      Enum.all?(paths, &task_path?/1)
  end

  defp allowed_task_create_args?(args) do
    case arg_value(args, "files") do
      nil ->
        true

      files when is_list(files) and length(files) <= @max_task_create_files ->
        Enum.all?(files, &task_path?/1)

      _other ->
        false
    end
  end

  defp allowed_send_message_args?(args) do
    case arg_value(args, "content") do
      blocks when is_list(blocks) -> Enum.all?(blocks, &allowed_send_block?/1)
      _other -> true
    end
  end

  defp allowed_send_block?(block) when is_map(block) do
    path =
      case arg_value(block, "path") do
        value when is_binary(value) and value != "" ->
          String.trim(value)

        _ ->
          case arg_value(block, "file_ref") do
            ref when is_map(ref) ->
              if arg_value(ref, "environment_id") == "vfs",
                do: arg_value(ref, "path") |> to_string() |> String.trim(),
                else: ""

            _ ->
              ""
          end
      end

    path == "" or readable_path?(path)
  end

  defp allowed_send_block?(_block), do: true

  defp readable_path?(path), do: task_path?(path) or attachment_path?(path)

  defp task_path?(path) when is_binary(path), do: safe_prefixed_path?(path, @task_root)
  defp task_path?(_path), do: false

  defp attachment_path?(path) when is_binary(path),
    do: safe_prefixed_path?(path, @attachments_root)

  defp attachment_path?(_path), do: false

  defp safe_prefixed_path?(path, prefix) do
    String.starts_with?(path, prefix) and not String.contains?(path, ["\\", <<0>>]) and
      not Enum.member?(String.split(path, "/"), "..")
  end

  defp arg_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  def allowed_disclosure?(ctx, candidate) when is_map(candidate),
    do: allowed_tool?(ctx, candidate["name"])

  @doc """
  Checks both the allowlist/argument rules and host-only mutations for a
  Collaborative Task's Worker:

  - Repo-less, non-Mini-App sandbox sub-tasks (`im_api.internal.task.create`
    without `repo` or `mini_app`) are allowed for all active members and guests
    (billed to the host, no GitHub credentials).
  - Coding sub-tasks with `repo`, Mini App build sub-tasks with `mini_app`,
    and `im_api.internal.apps.create` remain strictly host-only.

  Returns `:ok`, `{:error, :blocked}`, or `{:error, message}` for a polite
  host-only refusal.
  """
  def authorize_call(ctx, name, args) do
    name = to_string(name || "")

    cond do
      not allowed_tool?(ctx, name) or not allowed_call?(ctx, name, args) ->
        {:error, :blocked}

      restricted?(ctx) and not host_command?(ctx) ->
        case host_only_action(name, args) do
          nil -> :ok
          action -> {:error, host_only_message(action)}
        end

      true ->
        :ok
    end
  end

  defp host_only_action("im_api.internal.apps.create", _args), do: "create Mini Apps"

  defp host_only_action("im_api.internal.task.create", args) when is_map(args) do
    cond do
      not is_nil(arg_value(args, "repo")) ->
        "run coding tasks against a GitHub repository or open pull requests"

      not is_nil(arg_value(args, "mini_app")) ->
        "build or deploy Mini Apps"

      true ->
        nil
    end
  end

  defp host_only_action(_name, _args), do: nil

  @doc "Whether a Collaborative Task's Worker round was started by its host."
  def host_command?(ctx) do
    if restricted?(ctx) do
      mod = SystemsRuntime.get_env(:salix_agent, :collaboration_command_mod)
      is_atom(mod) and mod != nil and mod.host_command?(ctx) == true
    else
      true
    end
  end

  @doc """
  Raises unless a Collaborative Task's Worker round was started by its host:
  a Loop runs on the host's credits until stopped, so only the host starts,
  changes or ends one. Any other round passes. With no authority configured,
  a Collaborative Task's Worker changes no Loop.
  """
  def host_command!(ctx) do
    unless host_command?(ctx) do
      raise "Only the host of this Task together can start, change or stop its Loop. " <>
              "Ask the host to confirm in the Task; when the host asks you, do it then."
    end

    :ok
  end

  @doc """
  Raises with a polite host-only message naming `action` unless a Collaborative
  Task's Worker round was started by its host.
  """
  def host_command!(ctx, action) when is_binary(action) do
    unless host_command?(ctx) do
      raise host_only_message(action)
    end

    :ok
  end

  defp host_only_message(action) do
    "Only the host of this Collaborative Task can #{action}. " <>
      "Members may discuss and review results; ask the host to confirm in the Task."
  end

  @doc "Whether this round runs a Collaborative Task's Worker or sandbox sub-task Worker."
  def restricted?(ctx), do: policy(ctx) in [:restricted, :sandbox_restricted]

  defp policy(ctx) when is_map(ctx) do
    explicit = value(ctx, :collaboration_policy)
    disclosed = nested_value(ctx, :tool_disclosure, :collaboration_policy)

    case explicit || disclosed do
      value when value in [:restricted, "restricted"] -> :restricted
      value when value in [:sandbox_restricted, "sandbox_restricted"] -> :sandbox_restricted
      value when value in [:ordinary, "ordinary"] -> :ordinary
      nil -> :ordinary
      _ -> :unresolved
    end
  end

  defp policy(_ctx), do: :ordinary

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp nested_value(map, parent_key, child_key) do
    case value(map, parent_key) do
      nested when is_map(nested) -> value(nested, child_key)
      _ -> nil
    end
  end
end
