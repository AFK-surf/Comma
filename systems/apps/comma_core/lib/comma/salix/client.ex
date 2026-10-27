defmodule Comma.Salix.Client do
  @moduledoc """
  Anti-corruption boundary between Comma product contexts and Salix.

  Comma conversations use Salix IM/group conversations as their visible message
  surface. Read-only execution history is addressed through an exact
  Conversation Participant; runtime Session identities remain private.
  """

  require Logger

  @callback provision_workspace_scope(workspace :: map()) :: :ok | {:error, term()}
  @callback verify_workspace_scope(workspace :: map()) :: :ok | {:error, term()}
  @callback resolve_workspace_scope(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback conversation_uses_private_model?(map(), map()) :: boolean()

  @callback get_workspace_agent_models(workspace :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback update_workspace_agent_model(
              workspace :: map(),
              role :: String.t(),
              model :: map() | nil
            ) :: {:ok, map()} | {:error, term()}

  @callback update_workspace_vm(workspace :: map(), vm :: map()) :: :ok | {:error, term()}
  @callback ensure_guest_tenant(tenant_id :: String.t(), dependency_max_children :: pos_integer()) ::
              :ok | {:error, term()}
  @optional_callbacks ensure_guest_tenant: 2
  @callback create_group_conversation(workspace :: map(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback enter_meeting_task(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback update_meeting_task(map(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}

  @callback ensure_group_router_conversation(workspace :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback ensure_group_router_conversation(workspace :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback append_group_router_conversation_message(workspace :: map(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback list_group_conversations(workspace :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback list_group_activity_tasks(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback search_group_tasks(
              workspace :: map(),
              query :: String.t(),
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, term()}
  @callback get_group_conversation(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback get_group_conversation_participant_history(map(), String.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @optional_callbacks enter_meeting_task: 3,
                      update_meeting_task: 4,
                      get_group_conversation_participant_history: 4
  @callback list_group_conversation_pins(workspace :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback pin_group_conversation(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback unpin_group_conversation(workspace :: map(), conversation_id :: String.t()) ::
              :ok | {:error, term()}
  @callback get_group_task_order(workspace :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback put_group_task_order(
              workspace :: map(),
              bucket :: String.t(),
              conversation_ids :: [String.t()]
            ) ::
              {:ok, map()} | {:error, term()}
  @callback update_group_conversation(
              workspace :: map(),
              conversation_id :: String.t(),
              attrs :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_group_conversation_with_messages(
              workspace :: map(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
  @callback list_group_conversation_message_page(
              workspace :: map(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
  @callback subscribe_group_conversation(
              workspace :: map(),
              conversation_id :: String.t(),
              subscriber :: pid()
            ) :: {:ok, map()} | {:error, term()}
  @callback subscribe_group_conversation_list(
              workspace :: map(),
              kind :: String.t(),
              subscriber :: pid()
            ) :: {:ok, map()} | {:error, term()}
  @callback subscribe_group_conversation_mutations(
              workspace :: map(),
              subscriber :: pid()
            ) :: {:ok, map()} | {:error, term()}
  @callback list_station_tasks(workspace :: map()) :: {:ok, [map()]} | {:error, term()}
  @callback subscribe_station_tasks(workspace :: map(), subscriber :: pid()) ::
              :ok | {:error, term()}

  @doc """
  The Messages of a Task a station of the Group hosts (`station:<station_id>:<thread>`) after `after` (a seq of its
  station's), at most `limit`, read from its station over its Connector, as the Router reads one:
  `{:ok, %{"title", "messages", "through"}}`; `{:error, :not_found}` when the Group's Task index has no such Task,
  `{:error, :device_offline}` while its station is not connected.
  """
  @callback read_station_task(
              workspace :: map(),
              station_id :: String.t(),
              thread :: String.t(),
              opts :: map()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks read_station_task: 4
  @callback subscribe_group_conversation_participant(
              workspace :: map(),
              conversation_id :: String.t(),
              participant_id :: String.t(),
              subscriber :: pid()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_group_conversation_participant_status(
              workspace :: map(),
              conversation_id :: String.t(),
              participant_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback ensure_group_conversation_user_participant(
              workspace :: map(),
              conversation_id :: String.t(),
              user_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback reconcile_group_conversation_router_participant(
              workspace :: map(),
              conversation_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback list_group_conversation_participants(
              workspace :: map(),
              conversation_id :: String.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}
  @callback get_group_conversation_messages(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @doc "One message of a Group Conversation, by its id, at any depth of the history."
  @callback get_group_conversation_message(
              workspace :: map(),
              conversation_id :: String.t(),
              message_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @optional_callbacks get_group_conversation_message: 3
  @callback append_group_conversation_message(
              workspace :: map(),
              conversation_id :: String.t(),
              attrs :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback set_task_archived(map(), String.t(), :archive | :unarchive, pos_integer()) ::
              {:ok, map()} | {:error, term()}

  @callback set_task_status(
              workspace :: map(),
              conversation_id :: String.t(),
              status :: String.t(),
              expected_updated_at :: pos_integer(),
              user_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Runs a Task that exists elsewhere, on another model (`SalixIM.TaskRun`):
  `run` carries `runs_on` and `model`. `{:task_run_refused, reason, message}`
  when the place or model is not usable, or its station did not take it.
  """
  @callback switch_task_run(
              workspace :: map(),
              conversation_id :: String.t(),
              run :: map(),
              user_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @optional_callbacks switch_task_run: 4

  @callback accept_task_review(
              workspace :: map(),
              conversation_id :: String.t(),
              review_version :: pos_integer()
            ) :: {:ok, map()} | {:error, term()}
  @callback reserve_group_conversation_message(
              workspace :: map(),
              conversation_id :: String.t(),
              attrs :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback task_activity_participants(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}
  @optional_callbacks task_activity_participants: 2

  @doc """
  Where a Task runs and the model it runs (`place`, `model`), which Task
  panels show instead of its Agent.
  """
  @callback task_run(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @optional_callbacks task_run: 2

  @doc """
  The Background Loops of at most 50 Tasks of the Workspace's default Group,
  in one indexed read: `%{conversation_id => view}` (`SalixIM.Ports.TaskLoops`).
  A Task without a Loop is absent.
  """
  @callback task_loops(workspace :: map(), conversation_ids :: [String.t()]) ::
              {:ok, %{String.t() => map()}} | {:error, term()}
  @optional_callbacks task_loops: 2

  @doc """
  The pull requests of at most 50 coding Tasks, as the Tasks last read them from
  GitHub, in one read: `%{conversation_id => %{"number", "state", "url"}}`. A
  Task without a pull request, or with none known yet, is absent.
  """
  @callback task_pull_requests(workspace :: map(), conversation_ids :: [String.t()]) ::
              {:ok, %{String.t() => map()}} | {:error, term()}
  @optional_callbacks task_pull_requests: 2

  @callback conversation_activity_context(workspace :: map(), conversation_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback list_agent_skills(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback read_agent_skill_file(
              workspace :: map(),
              skill_id :: String.t(),
              path :: String.t(),
              max_bytes :: pos_integer()
            ) ::
              {:ok, binary()} | {:error, term()}
  @optional_callbacks read_agent_skill_file: 4
  @callback write_agent_file(workspace :: map(), path :: String.t(), body :: binary()) ::
              {:ok, map()} | {:error, term()}
  @callback read_agent_file(
              workspace :: map(),
              path :: String.t(),
              max_bytes :: pos_integer()
            ) ::
              {:ok, binary()} | {:error, term()}
  @callback read_agent_blob(
              workspace :: map(),
              agent_id :: String.t(),
              ref :: map(),
              max_bytes :: pos_integer()
            ) ::
              {:ok, binary()} | {:error, term()}
  @doc """
  An Agent's immutable blob as it is read, in bounded chunks, under the same
  Group + Agent authorization as `read_agent_blob/4`: all of it (`nil`), or
  `length` bytes from `offset`. The size returned is the whole blob's.
  """
  @callback stream_agent_blob(
              workspace :: map(),
              agent_id :: String.t(),
              ref :: map(),
              range :: {non_neg_integer(), non_neg_integer()} | nil
            ) ::
              {:ok, Enumerable.t(), non_neg_integer()} | {:error, term()}
  @optional_callbacks stream_agent_blob: 4

  @doc """
  A URL anyone holding it reads an Agent's immutable blob from, straight from
  the blob store and in any byte ranges, until it expires: authorized as
  `stream_agent_blob/4` when it is signed, and by nothing after. `opts` are
  `SalixStore.S3.presign_opt()`. `{:error, :unsupported}` from a store that
  cannot sign one.
  """
  @callback presign_agent_blob(
              workspace :: map(),
              agent_id :: String.t(),
              ref :: map(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  One page of the Router VFS files under `dir` (a `/`-terminated prefix), in
  path order, as seen by the Comma user `opts[:reader]`: a file the user may
  not read is left out. `opts[:cursor]` is the last path of the previous page.
  Answers `%{"files" => [%{"path", "size", "hash", "modified_at"}], "next_cursor" => path | nil}`.
  """
  @callback list_agent_files(workspace :: map(), dir :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Reads one Router VFS file as the Comma user `reader`, as
  `%{"content" => binary, "hash" => hash}`; `:not_found` when they may not read it.
  """
  @callback read_agent_file_as(
              workspace :: map(),
              path :: String.t(),
              max_bytes :: pos_integer(),
              reader :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Replaces (or creates) one Router VFS file for the Comma user `opts[:reader]`.
  The file keeps the audience it already had. With `opts[:expected_hash]`, a
  file whose content changed (or is absent) answers `{:conflict, _}`. The
  result carries the new `"hash"`.
  """
  @callback write_agent_file_as(
              workspace :: map(),
              path :: String.t(),
              body :: binary(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Deletes one Router VFS file for the Comma user `opts[:reader]`, with the same
  `opts[:expected_hash]` precondition; `:not_found` when they may not read it.
  """
  @callback delete_agent_file(workspace :: map(), path :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  The Router's effective instructions: its `router_system_prompt`, else its
  `system_prompt`, else `""`.
  """
  @callback get_router_instructions(workspace :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Replaces the Router's own instructions (`router_system_prompt`) with
  `content`. With `opts[:expected_hash]`, the effective instructions must still
  hash to it, otherwise `{:conflict, _}`. Clearing them while the shared
  `system_prompt` would take over is refused with `{:bad_request, _}`.
  """
  @callback set_router_instructions(workspace :: map(), content :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Writes one Router VFS file from `stream`, a sequence of binary chunks read
  as they are stored, so the body is never held whole.
  """
  @callback write_agent_file_stream(
              workspace :: map(),
              path :: String.t(),
              stream :: Enumerable.t()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Maps Router VFS `path` to an Agent's immutable blob `ref`, under the same
  Group + Agent authorization as `stream_agent_blob/4`, without copying it.
  """
  @callback link_agent_blob(
              workspace :: map(),
              agent_id :: String.t(),
              ref :: map(),
              path :: String.t()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks list_agent_files: 3,
                      read_agent_file_as: 4,
                      write_agent_file_as: 4,
                      write_agent_file_stream: 3,
                      link_agent_blob: 4,
                      presign_agent_blob: 4,
                      delete_agent_file: 3,
                      get_router_instructions: 1,
                      set_router_instructions: 3

  @callback get_group_condensed_workspace(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback set_group_condensed_workspace_enabled(workspace :: map(), enabled :: boolean()) ::
              {:ok, map()} | {:error, term()}
  @callback update_group_condensed_workspace(
              workspace :: map(),
              operations :: list(),
              user_id :: String.t()
            ) :: {:ok, map()} | {:error, term()}
  @callback list_group_task_labels(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback update_group_task_label_policy(workspace :: map(), policy :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_group_task_label(workspace :: map(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback update_group_task_label(workspace :: map(), label_id :: String.t(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback delete_group_task_label(workspace :: map(), label_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback resolve_group_task_label_proposal(
              workspace :: map(),
              proposal_id :: String.t(),
              resolution :: map()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks conversation_uses_private_model?: 2,
                      verify_workspace_scope: 1,
                      get_group_condensed_workspace: 1,
                      set_group_condensed_workspace_enabled: 2,
                      update_group_condensed_workspace: 3,
                      list_group_task_labels: 1,
                      create_group_task_label: 2,
                      update_group_task_label_policy: 2,
                      update_group_task_label: 3,
                      delete_group_task_label: 2,
                      resolve_group_task_label_proposal: 3,
                      get_workspace_agent_models: 1,
                      update_workspace_agent_model: 3,
                      ensure_group_router_conversation: 1,
                      ensure_group_router_conversation: 2,
                      append_group_router_conversation_message: 2,
                      reserve_group_conversation_message: 3,
                      list_group_conversations: 2,
                      list_group_activity_tasks: 1,
                      search_group_tasks: 3,
                      get_group_conversation: 2,
                      list_group_conversation_pins: 1,
                      pin_group_conversation: 2,
                      unpin_group_conversation: 2,
                      get_group_task_order: 1,
                      put_group_task_order: 3,
                      update_group_conversation: 3,
                      get_group_conversation_with_messages: 3,
                      list_group_conversation_message_page: 3,
                      subscribe_group_conversation: 3,
                      subscribe_group_conversation_list: 3,
                      subscribe_group_conversation_mutations: 2,
                      list_station_tasks: 1,
                      subscribe_station_tasks: 2,
                      subscribe_group_conversation_participant: 4,
                      get_group_conversation_participant_status: 3,
                      accept_task_review: 3,
                      set_task_status: 5,
                      set_task_archived: 4,
                      ensure_group_conversation_user_participant: 3,
                      reconcile_group_conversation_router_participant: 2,
                      list_group_conversation_participants: 3

  @doc """
  The Salix Drive binding of the Workspace's default group
  (`Salix.Control.DriveBindings`) as stored: the org slug, network, space and
  key its agents reach `/drive` with, its `source`, `enabled` flag and
  `retired_key_ids`. A disabled or incomplete row is still `{:ok, row}`: the
  caller decides what to do with a row that exists. `{:error, :not_found}`
  when there is none.
  """
  @callback drive_binding(workspace :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  Create or update that binding; `attrs` follow
  `Salix.Control.DriveBindings.put/2`, and a field left out keeps its stored
  value.
  """
  @callback put_drive_binding(workspace :: map(), attrs :: map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks drive_binding: 1, put_drive_binding: 2

  def impl, do: SystemsRuntime.get_env(:comma_core, :salix_client, Comma.Salix.Runtime)

  def conversation_uses_private_model?(workspace, conversation) do
    module = impl()

    Code.ensure_loaded?(module) and
      function_exported?(module, :conversation_uses_private_model?, 2) and
      module.conversation_uses_private_model?(workspace, conversation)
  end

  # A client without the Loop runtime has no Loops, as `SalixIM.Ports.TaskLoops` without a binding.
  def task_loops(workspace, conversation_ids) do
    case call_optional(:task_loops, [workspace, conversation_ids]) do
      {:error, :salix_client_not_configured} -> {:ok, %{}}
      result -> result
    end
  end

  # A pull request only decorates a Task's card: a client that cannot read them, or a read that fails or raises,
  # leaves the cards without and never fails the list.
  def task_pull_requests(workspace, conversation_ids) do
    case call_optional(:task_pull_requests, [workspace, conversation_ids]) do
      {:ok, %{} = pull_requests} -> {:ok, pull_requests}
      _unavailable -> {:ok, %{}}
    end
  rescue
    error ->
      Logger.warning("task pull requests not read: #{Exception.message(error)}")
      {:ok, %{}}
  end

  def drive_binding(workspace), do: call_optional(:drive_binding, [workspace])

  def read_station_task(workspace, station_id, thread, opts),
    do: call_optional(:read_station_task, [workspace, station_id, thread, opts])

  def put_drive_binding(workspace, attrs),
    do: call_optional(:put_drive_binding, [workspace, attrs])

  def get_workspace_agent_models(workspace) do
    call_optional(:get_workspace_agent_models, [workspace])
  end

  def update_workspace_agent_model(workspace, role, model) do
    call_optional(:update_workspace_agent_model, [workspace, role, model])
  end

  def list_agent_files(workspace, dir, opts),
    do: call_optional(:list_agent_files, [workspace, dir, opts])

  def read_agent_file_as(workspace, path, max_bytes, reader),
    do: call_optional(:read_agent_file_as, [workspace, path, max_bytes, reader])

  def write_agent_file_as(workspace, path, body, opts),
    do: call_optional(:write_agent_file_as, [workspace, path, body, opts])

  def write_agent_file_stream(workspace, path, stream),
    do: call_optional(:write_agent_file_stream, [workspace, path, stream])

  def get_group_conversation_message(workspace, conversation_id, message_id),
    do: call_optional(:get_group_conversation_message, [workspace, conversation_id, message_id])

  def presign_agent_blob(workspace, agent_id, ref, opts),
    do: call_optional(:presign_agent_blob, [workspace, agent_id, ref, opts])

  def link_agent_blob(workspace, agent_id, ref, path),
    do: call_optional(:link_agent_blob, [workspace, agent_id, ref, path])

  def delete_agent_file(workspace, path, opts),
    do: call_optional(:delete_agent_file, [workspace, path, opts])

  def get_router_instructions(workspace),
    do: call_optional(:get_router_instructions, [workspace])

  def set_router_instructions(workspace, content, opts),
    do: call_optional(:set_router_instructions, [workspace, content, opts])

  def get_group_condensed_workspace(workspace),
    do: call_optional(:get_group_condensed_workspace, [workspace])

  def set_group_condensed_workspace_enabled(workspace, enabled),
    do: call_optional(:set_group_condensed_workspace_enabled, [workspace, enabled])

  def update_group_condensed_workspace(workspace, operations, user_id),
    do: call_optional(:update_group_condensed_workspace, [workspace, operations, user_id])

  def list_group_task_labels(workspace) do
    call_optional(:list_group_task_labels, [workspace])
  end

  def update_group_task_label_policy(workspace, policy) do
    call_optional(:update_group_task_label_policy, [workspace, policy])
  end

  def create_group_task_label(workspace, attrs) do
    call_optional(:create_group_task_label, [workspace, attrs])
  end

  def update_group_task_label(workspace, label_id, attrs) do
    call_optional(:update_group_task_label, [workspace, label_id, attrs])
  end

  def delete_group_task_label(workspace, label_id) do
    call_optional(:delete_group_task_label, [workspace, label_id])
  end

  def resolve_group_task_label_proposal(workspace, proposal_id, decision) do
    call_optional(:resolve_group_task_label_proposal, [workspace, proposal_id, decision])
  end

  defp call_optional(function, arguments) do
    module = impl()

    if Code.ensure_loaded?(module) and function_exported?(module, function, length(arguments)) do
      apply(module, function, arguments)
    else
      {:error, :salix_client_not_configured}
    end
  end
end
