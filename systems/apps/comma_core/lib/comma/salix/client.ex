defmodule Comma.Salix.Client do
  @moduledoc """
  Anti-corruption boundary between Comma product contexts and Salix.

  Comma conversations use Salix IM/group conversations as their visible message
  surface. Read-only execution history is addressed through an exact
  Conversation Participant; runtime Session identities remain private.
  """

  @callback provision_workspace_scope(workspace :: map()) :: :ok | {:error, term()}
  @callback verify_workspace_scope(workspace :: map()) :: :ok | {:error, term()}
  @callback resolve_workspace_scope(workspace :: map()) :: {:ok, map()} | {:error, term()}
  @callback conversation_uses_private_model?(map(), map()) :: boolean()

  @callback get_workspace_agent_models(workspace :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback update_workspace_agent_model(
              workspace :: map(),
              role :: String.t(),
              template_id :: String.t() | nil
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
  @callback append_group_conversation_message(
              workspace :: map(),
              conversation_id :: String.t(),
              attrs :: map()
            ) :: {:ok, map()} | {:error, term()}
  @callback set_task_archived(map(), String.t(), :archive | :unarchive, pos_integer()) ::
              {:ok, map()} | {:error, term()}

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
                      subscribe_group_conversation_participant: 4,
                      get_group_conversation_participant_status: 3,
                      accept_task_review: 3,
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

  def impl, do: Application.get_env(:comma_core, :salix_client, Comma.Salix.Runtime)

  def conversation_uses_private_model?(workspace, conversation) do
    module = impl()

    Code.ensure_loaded?(module) and
      function_exported?(module, :conversation_uses_private_model?, 2) and
      module.conversation_uses_private_model?(workspace, conversation)
  end

  def drive_binding(workspace), do: call_optional(:drive_binding, [workspace])

  def put_drive_binding(workspace, attrs),
    do: call_optional(:put_drive_binding, [workspace, attrs])

  def get_workspace_agent_models(workspace) do
    call_optional(:get_workspace_agent_models, [workspace])
  end

  def update_workspace_agent_model(workspace, role, template_id) do
    call_optional(:update_workspace_agent_model, [workspace, role, template_id])
  end

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
