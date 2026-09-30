defmodule Comma.Salix.Runtime do
  @moduledoc """
  Default Comma Salix client.

  Comma core does not know how to wire Salix control/IM. Runtime hosts such as
  CommaWeb must install a concrete `Comma.Salix.Client` implementation.
  """

  @behaviour Comma.Salix.Client

  @impl true
  def provision_workspace_scope(_workspace), do: {:error, :salix_client_not_configured}

  @impl true
  def resolve_workspace_scope(_workspace), do: {:error, :salix_client_not_configured}

  @impl true
  def get_workspace_agent_models(_workspace), do: {:error, :salix_client_not_configured}

  @impl true
  def update_workspace_agent_model(_workspace, _role, _template_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def update_workspace_vm(_workspace, _vm), do: {:error, :salix_client_not_configured}

  @impl true
  def create_group_conversation(_workspace, _attrs), do: {:error, :salix_client_not_configured}

  @impl true
  def ensure_group_router_conversation(_workspace),
    do: {:error, :salix_client_not_configured}

  @impl true
  def append_group_router_conversation_message(_workspace, _attrs),
    do: {:error, :salix_client_not_configured}

  @impl true
  def list_group_conversations(_workspace, _opts), do: {:error, :salix_client_not_configured}

  @impl true
  def search_group_tasks(_workspace, _query, _opts),
    do: {:error, :salix_client_not_configured}

  @impl true
  def get_group_conversation(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def list_group_conversation_pins(_workspace),
    do: {:error, :salix_client_not_configured}

  @impl true
  def pin_group_conversation(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def unpin_group_conversation(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def get_group_task_order(_workspace),
    do: {:error, :salix_client_not_configured}

  @impl true
  def put_group_task_order(_workspace, _bucket, _conversation_ids),
    do: {:error, :salix_client_not_configured}

  @impl true
  def update_group_conversation(_workspace, _conversation_id, _attrs),
    do: {:error, :salix_client_not_configured}

  @impl true
  def get_group_conversation_with_messages(_workspace, _conversation_id, _opts),
    do: {:error, :salix_client_not_configured}

  @impl true
  def list_group_conversation_message_page(_workspace, _conversation_id, _opts),
    do: {:error, :salix_client_not_configured}

  @impl true
  def subscribe_group_conversation(_workspace, _conversation_id, _subscriber),
    do: {:error, :salix_client_not_configured}

  @impl true
  def subscribe_group_conversation_list(_workspace, _kind, _subscriber),
    do: {:error, :salix_client_not_configured}

  @impl true
  def subscribe_group_conversation_participant(
        _workspace,
        _conversation_id,
        _participant_id,
        _subscriber
      ),
      do: {:error, :salix_client_not_configured}

  @impl true
  def get_group_conversation_participant_status(
        _workspace,
        _conversation_id,
        _participant_id
      ),
      do: {:error, :salix_client_not_configured}

  @impl true
  def ensure_group_conversation_user_participant(_workspace, _conversation_id, _user_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def reconcile_group_conversation_router_participant(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def list_group_conversation_participants(_workspace, _conversation_id, _opts),
    do: {:error, :salix_client_not_configured}

  @impl true
  def get_group_conversation_messages(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def append_group_conversation_message(_workspace, _conversation_id, _attrs),
    do: {:error, :salix_client_not_configured}

  @impl true
  def set_task_archived(_, _, _, _), do: {:error, :salix_client_not_configured}

  @impl true
  def accept_task_review(_workspace, _conversation_id, _review_version),
    do: {:error, :salix_client_not_configured}

  @impl true
  def reserve_group_conversation_message(_workspace, _conversation_id, _attrs),
    do: {:error, :salix_client_not_configured}

  @impl true
  def task_activity_participants(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def conversation_activity_context(_workspace, _conversation_id),
    do: {:error, :salix_client_not_configured}

  @impl true
  def list_agent_skills(_workspace), do: {:error, :salix_client_not_configured}

  @impl true
  def write_agent_file(_workspace, _path, _body), do: {:error, :salix_client_not_configured}

  @impl true
  def read_agent_file(_workspace, _path, _max_bytes),
    do: {:error, :salix_client_not_configured}

  @impl true
  def read_agent_blob(_workspace, _agent_id, _ref, _max_bytes),
    do: {:error, :salix_client_not_configured}
end
