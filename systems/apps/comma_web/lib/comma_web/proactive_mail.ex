defmodule CommaWeb.ProactiveMail do
  @moduledoc "Reads and Task correlation for existing Gmail-backed Home values."

  alias Comma.MemberSourceConsents
  alias SalixStore.Loops, as: Store

  def receive_schedule(payload, opts), do: CommaWeb.HomeMail.receive_schedule(payload, opts)

  def read(%{"message_id" => message_id}, ctx) do
    with {:ok, workspace, user_id} <- scope(ctx),
         {:ok, consent, settings} <- consent(workspace, user_id),
         :ok <- loop_consent(ctx, workspace, consent),
         {:ok, result} <-
           CommaWeb.ProactiveMailSource.read(
             settings,
             workspace["default_group_id"],
             consent["connection_id"],
             message_id
           ),
         ^consent <- MemberSourceConsents.binding(workspace["id"], user_id, "gmail"),
         {:ok, current_workspace, ^user_id} <- scope(ctx),
         true <- current_workspace["id"] == workspace["id"],
         :ok <- loop_consent(ctx, workspace, consent) do
      CommaWeb.HomeMail.decorate_read(
        Map.put(result, "source", Map.merge(consent, %{"toolkit" => "gmail"})),
        ctx
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :mail_consent_changed}
    end
  end

  def read(_, _), do: {:error, :message_id_required}

  def schedule(args, ctx), do: CommaWeb.HomeMail.schedule(args, ctx)
  def handle(args, ctx), do: CommaWeb.HomeMail.handle(args, ctx)

  # This is Task correlation metadata, not source authority. Every read below
  # still authorizes the current owner/account independently.
  def link_task(%{"conversation_id" => id, "message_id" => message_id}, ctx) do
    with {:ok, workspace, _user} <- scope(ctx),
         true <- ctx.agent_id == workspace["router_agent_id"],
         {:ok, _task} <- owned_task(workspace, id),
         {:ok, mail} <- read(%{"message_id" => message_id}, ctx),
         ref =
           Map.take(mail, ~w(message_id thread_id url))
           |> Map.put("connection_id", mail["source"]["connection_id"]),
         {:ok, _updated} <-
           SalixIM.ConversationServer.link_task_mail(
             workspace["default_group_id"],
             id,
             workspace["router_agent_id"],
             ref
           ),
         {:ok, _} <- CommaWeb.HomeMail.attach_task(mail, id, ctx) do
      {:ok, %{"conversation_id" => id, "source" => ref}}
    else
      false -> {:error, :comma_home_router_required}
      {:error, _} = error -> error
    end
  end

  def link_task(_, _), do: {:error, :task_and_message_required}

  def followup(%{"conversation_id" => id}, ctx) do
    with {:ok, workspace, _user} <- scope(ctx),
         {:ok, task} <- owned_task(workspace, id),
         true <- ctx.agent_id in [workspace["router_agent_id"], task["task_worker_agent_id"]] do
      if task["status"] in ~w(completed cancelled archived ready_for_review) do
        {:ok, %{"conversation_id" => id, "state" => "stopped", "task_status" => task["status"]}}
      else
        with %{"message_id" => message_id, "thread_id" => thread, "connection_id" => account} <-
               get_in(task, ["source_refs", "comma_mail"]),
             {:ok, receipt, _settings} <- consent(workspace, workspace["owner_user_id"]),
             true <- receipt["connection_id"] == account,
             {:ok, mail} <- read(%{"message_id" => message_id}, ctx),
             true <- mail["thread_id"] == thread do
          finish_followup(workspace, task, mail)
        else
          {:error, _} = error -> error
          _ -> {:error, :mail_task_source_changed}
        end
      end
    else
      false -> {:error, :task_agent_required}
      {:error, _} = error -> error
    end
  end

  def followup(_, _), do: {:error, :conversation_id_required}

  defp finish_followup(workspace, before, mail) do
    with {:ok, current} <- owned_task(workspace, before["conversation_id"]) do
      cond do
        current["status"] in ~w(completed cancelled archived ready_for_review) ->
          {:ok,
           %{
             "conversation_id" => current["conversation_id"],
             "state" => "stopped",
             "task_status" => current["status"]
           }}

        get_in(current, ["source_refs", "comma_mail"]) !=
            get_in(before, ["source_refs", "comma_mail"]) ->
          {:error, :mail_task_source_changed}

        true ->
          {:ok,
           %{
             "conversation_id" => current["conversation_id"],
             "state" => "needs_decision",
             "task_status" => current["status"],
             "mail" => mail
           }}
      end
    end
  end

  defp owned_task(workspace, id) do
    with {:ok, task} <-
           SalixIM.Conversations.get_group_conversation_record(workspace["default_group_id"], id),
         "agent_task" <- task["kind"],
         true <- task["created_by_agent_id"] == workspace["router_agent_id"] do
      {:ok, task}
    else
      _ -> {:error, :workspace_task_required}
    end
  end

  def scope(ctx), do: CommaWeb.Proactive.scope(ctx)

  defp consent(workspace, user_id) do
    with %{"connection_id" => id} = receipt <-
           MemberSourceConsents.binding(workspace["id"], user_id, "gmail"),
         {:ok, settings} <- settings().get(workspace["salix_tenant_id"]),
         {:ok, account} <- client().get_connected_account(settings, id, error_mode: :structured),
         true <-
           account["id"] == id and account["user_id"] == workspace["default_group_id"] and
             account["status"] == "ACTIVE" and get_in(account, ["toolkit", "slug"]) == "gmail" do
      {:ok, receipt, settings}
    else
      {:error, _} = error -> error
      _ -> {:error, :consented_gmail_account_required}
    end
  end

  defp loop_consent(%{loop_id: id}, _workspace, _consent) do
    with {:ok, row} <- Store.get(id),
         do: CommaWeb.ProactiveWatch.authorize(row, "agent.notify", %{})
  end

  defp loop_consent(_ctx, _workspace, _consent), do: :ok

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)

  defp settings,
    do: Application.get_env(:salix_web, :composio_settings_mod, Salix.Control.ComposioSettings)
end
