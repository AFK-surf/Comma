defmodule CommaWeb.MiniAppPublishing do
  @moduledoc """
  Publishes a deployed Mini App through its Task review and GitHub merge.
  Both the user API and the Router use this path.
  """

  alias Comma.MiniApps

  def publish(user, session, ws, id, body, opts \\ []) do
    with {:ok, workspace, app} <- MiniApps.owner_app(user, session, ws, id),
         {:ok, params} <- publish_params(body),
         :ok <-
           if(params.group_id == workspace.salix_group_id, do: :ok, else: {:error, :not_found}),
         {:ok, version} <- MiniApps.ready_version(app, params.version),
         {:ok, task} <- app_task(workspace, app, params.conversation_id),
         {:ok, pr} <-
           CommaWeb.Coding.Endpoints.ensure_pull_request(workspace, params.conversation_id),
         :ok <- head_is(app, pr, version),
         :ok <- accept_review(user, session, task, params, opts),
         {:ok, _merged} <-
           CommaWeb.Coding.Endpoints.merge(
             workspace,
             params.conversation_id,
             pr.number,
             version.commit
           ),
         {:ok, view} <- MiniApps.set_live(app, version, body["visibility"], workspace.id),
         do: {:ok, view}
  end

  defp publish_params(%{
         "group_id" => group,
         "conversation_id" => conversation,
         "review_version" => review,
         "version" => version
       })
       when is_binary(group) and is_binary(conversation) and is_integer(review) and
              is_integer(version) and version > 0 do
    {:ok,
     %{
       group_id: group,
       conversation_id: conversation,
       review_version: review,
       version: version
     }}
  end

  defp publish_params(_body),
    do:
      {:error,
       {:bad_request, "publish names group_id, conversation_id, review_version and version"}}

  # What merges is what the viewer previewed: the pull request head is the Version's commit.
  defp head_is(_app, %{head_sha: sha}, %{commit: sha}), do: :ok

  defp head_is(app, %{head_sha: head}, _version) do
    case MiniApps.version_for_commit(app, head) do
      {:ok, newer} ->
        {:error, {:conflict, "The Task has a newer version (v#{newer.number}): publish that one"}}

      error ->
        error
    end
  end

  # The Task is a coding Task of this app.
  defp app_task(workspace, app, conversation_id) do
    case SalixIM.Conversations.get_group_conversation(workspace.salix_group_id, conversation_id) do
      {:ok, %{"kind" => "agent_task", "mini_app" => %{"app_id" => app_id}} = task}
      when app_id == app.id ->
        {:ok, task}

      _ ->
        {:error, :not_found}
    end
  end

  # The review is accepted through the product path (`Comma.Conversations`),
  # which also checks that this member may act on the Task. A Task that path
  # reads as `completed` was accepted by an earlier Publish whose merge GitHub
  # refused: it is not accepted again.
  defp accept_review(user, session, _task, params, opts) do
    case Comma.Conversations.get(user, session, params.group_id, params.conversation_id,
           message_limit: 1
         ) do
      {:ok, %{"status" => "completed"}} ->
        :ok

      {:ok, _task} ->
        case Comma.Conversations.accept_task_review(
               user,
               session,
               params.group_id,
               params.conversation_id,
               %{"review_version" => params.review_version},
               Keyword.put(opts, :message_limit, 1)
             ) do
          {:ok, _task} -> :ok
          error -> error
        end

      error ->
        error
    end
  end
end
