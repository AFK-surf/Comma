defmodule CommaWeb.Proactive do
  @moduledoc """
  Comma's proactive capability for the Router: reminder state, owner-requested
  watches and replies. Automatic reminders come from `CommaWeb.ProactiveCheck`,
  the consumer of the member source item pool. Facts stay in existing tools and
  owners.

  Automatic messages are on by default. The owner can turn them off in Routine
  settings; the Home Conversation owns that switch beside their budget.
  """

  require Logger
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}
  alias CommaWeb.{HomeMail, MemberSourceIngest, ProactiveWatch}

  @doc "The owner's automatic message switch for Routine settings."
  def settings(user, session, group) do
    with {:ok, workspace, _ctx, home} <- HomeMail.context(user, session, group),
         true <- workspace["owner_user_id"] == user["id"],
         {:ok, conversation} <- Conversations.get_group_conversation_record(group, home) do
      {:ok, %{"enabled" => MailInteraction.enabled?(conversation, user["id"])}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  @doc """
  Turns the owner's automatic messages on or off. While they are off, source
  collection for them stops. Turning them on again starts from now: what
  arrived while they were off stays in the Routine briefing.
  """
  def configure(user, session, group, %{"enabled" => enabled, "request_id" => request_id})
      when is_boolean(enabled) and is_binary(request_id) do
    with {:ok, workspace, _ctx, home} <- HomeMail.context(user, session, group),
         true <- workspace["owner_user_id"] == user["id"],
         {:ok, saved} <-
           ConversationServer.configure_proactive(group, home, user["id"], enabled, request_id) do
      if saved["enabled"], do: resume(saved, workspace, user, session, group)
      CommaWeb.ProactiveNotebook.enqueue(group, user["id"])
      {:ok, %{"enabled" => saved["enabled"]}}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def configure(_user, _session, _group, _args),
    do: {:error, {:bad_request, "invalid proactive settings"}}

  # The pool records a new baseline, so items that arrived while automatic
  # messages were off never interrupt. Then the collection chain starts again.
  defp resume(saved, workspace, user, session, group) do
    with false <- saved["was_enabled"],
         {:ok, profile} <- Comma.Recommendations.get_runtime_profile(workspace["id"], user["id"]),
         do: Comma.MemberSourceItems.reset(profile.id)

    case MemberSourceIngest.enqueue(user, session, group) do
      :ok -> :ok
      {:error, _} -> Logger.warning("member source collection could not be queued")
    end
  end

  @doc """
  Whether the owner's automatic messages are on. A Home Conversation that does
  not exist yet has no preference, so they are on.
  """
  def automatic?(group, owner) do
    with {:ok, record} <- SalixIM.GroupDirectory.get_group(group),
         {:ok, home} <- SalixIM.ConversationIds.group_router(record) do
      case Conversations.get_group_conversation_record(group, home) do
        {:ok, conversation} -> {:ok, MailInteraction.enabled?(conversation, owner)}
        {:error, :not_found} -> {:ok, true}
        error -> error
      end
    end
  end

  @doc """
  A reminder as a chat message: the model's text, then its source link. Text
  that already names the link keeps it once.
  """
  def message(text, title, url) when is_binary(url) and url != "" do
    if String.contains?(text, url),
      do: text,
      else: text <> "\n\n" <> link(title, url)
  end

  def message(text, _title, _url), do: text

  @doc "A Markdown link to a source, or its escaped title when it has no URL."
  def link(title, url) when is_binary(url) and url != "",
    do: "[" <> link_label(title) <> "](" <> link_target(url) <> ")"

  def link(title, _url), do: link_label(title)

  defp link_label(title) do
    label =
      (title || "")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> String.slice(0, 80)

    label = if label == "", do: "Source", else: label
    Regex.replace(~r/[\\\[\]]/u, label, fn mark -> "\\" <> mark end)
  end

  defp link_target(url), do: url |> String.replace(" ", "%20") |> String.replace(")", "%29")

  def scope(ctx) do
    principal = SalixAgent.IFC.principal(ctx[:trusted_origin])

    with true <- not is_nil(principal),
         {:ok, user_id} <- principal_owner(SalixIFC.Principal.key(principal), ctx),
         {:ok, workspace} <-
           Comma.Workspaces.authorize_group(%{"id" => user_id}, %{}, ctx[:group_id]),
         true <- workspace["salix_tenant_id"] == ctx[:tenant_id] do
      {:ok, workspace, user_id}
    else
      _ -> {:error, :comma_owner_authority_required}
    end
  end

  defp principal_owner({:comma_user, user}, _ctx), do: {:ok, user}

  defp principal_owner({:provider_user, connect, subject}, ctx),
    do: CommaWeb.ProactiveDelivery.principal_owner(ctx[:group_id], connect, subject)

  defp principal_owner(_, _), do: {:error, :comma_owner_authority_required}

  def state(_args, ctx) do
    with {:ok, _, owner} <- scope(ctx),
         do: HomeMail.status(%{"id" => owner}, %{}, ctx.group_id)
  end

  def watch(args, ctx), do: ProactiveWatch.install(args, ctx)

  def act(%{"action" => "track"} = args, ctx) do
    with {:ok, _, owner} <- scope(ctx),
         {:ok, _, authorized, home} <- HomeMail.context(%{"id" => owner}, %{}, ctx.group_id),
         true <- authorized.agent_id == ctx.agent_id and authorized.session_id == ctx.session_id,
         true <- valid_reference?(args),
         {:ok, data} <- ProactiveWatch.read(args["read"], ctx),
         :ok <- CommaWeb.ProactiveRoutine.validate_reference(args, data),
         {:ok, read, task_id} <- CommaWeb.ProactiveRoutine.continuation(args["read"], data, ctx) do
      key = source_key(args["read"], args["source_ref"])

      # Tracking updates the source receipt. The Router sends any reply
      # separately through its ordinary authorized reply tools.
      command = %{
        "action" => "track",
        "key" => key,
        "request_id" => args["request_id"],
        "generation" => args["generation"],
        "account_id" => source_account(args["read"]),
        "thread_id" => args["source_ref"],
        "message_id" => args["observation_id"],
        "subject" => args["title"],
        "source_url" => args["url"] || "",
        "read" => read,
        "task_id" => task_id
      }

      with {:ok, command} <- HomeMail.retire_completed_task(command, ctx, home),
           {:ok, result} <-
             ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, command) do
        CommaWeb.ProactiveNotebook.enqueue(ctx.group_id, owner)
        {:ok, Map.put(result, "key", key)}
      end
    else
      false -> {:error, :invalid_proactive_reference}
      error -> error
    end
  end

  def act(%{"action" => "remind"} = args, ctx) do
    with {:ok, _, owner} <- scope(ctx),
         {:ok, _, authorized, home} <- HomeMail.context(%{"id" => owner}, %{}, ctx.group_id),
         true <- authorized.agent_id == ctx.agent_id and authorized.session_id == ctx.session_id,
         true <- valid_reference?(args),
         true <- is_integer(args["run_at"]) and args["run_at"] > System.system_time(:millisecond),
         {:ok, data} <- ProactiveWatch.read(args["read"], ctx),
         :ok <- CommaWeb.ProactiveRoutine.validate_reference(args, data),
         {:ok, read, task_id} <- CommaWeb.ProactiveRoutine.continuation(args["read"], data, ctx),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      key = source_key(args["read"], args["source_ref"])
      value = MailInteraction.entries(conversation)[key]

      tracked =
        if is_map(value) do
          {:ok, value}
        else
          ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, %{
            "action" => "track",
            "key" => key,
            "request_id" => args["request_id"],
            "account_id" => source_account(args["read"]),
            "thread_id" => args["source_ref"],
            "message_id" => args["observation_id"],
            "subject" => args["title"],
            "source_url" => args["url"] || "",
            "read" => read,
            "task_id" => task_id
          })
        end

      with {:ok, value} <- tracked do
        request = "remind:" <> args["request_id"]

        HomeMail.action(%{"id" => owner}, %{}, ctx.group_id, %{
          "action" => "snooze",
          "key" => key,
          "generation" => action_generation(value, request),
          "request_id" => request,
          "run_at" => args["run_at"],
          "reason" => args["reason"]
        })
      end
    else
      false -> {:error, :invalid_proactive_reminder}
      error -> error
    end
  end

  def act(args, ctx) do
    with {:ok, _, owner} <- scope(ctx),
         {:ok, _, _, home} <- HomeMail.context(%{"id" => owner}, %{}, ctx.group_id),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home),
         {:ok, key} <- resolve(conversation, owner, args) do
      value = MailInteraction.entries(conversation)[key]

      args =
        args
        |> Map.put("key", key)
        |> Map.put_new("generation", action_generation(value, args["request_id"]))

      HomeMail.action(%{"id" => owner}, %{}, ctx.group_id, args)
    end
  end

  defp action_generation(value, request) do
    if value["request_id"] == request,
      do: get_in(value, ["last_command", "generation"]),
      else: value["generation"]
  end

  defp resolve(conversation, owner, %{"key" => key}) when is_binary(key) do
    if get_in(MailInteraction.entries(conversation), [key, "owner_id"]) == owner,
      do: {:ok, key},
      else: {:error, :mail_source_not_found}
  end

  defp resolve(conversation, owner, _args) do
    candidates =
      Enum.filter(MailInteraction.entries(conversation), fn {_key, value} ->
        value["owner_id"] == owner and value["state"] not in ~w(handled quiet)
      end)

    case candidates do
      [{key, _}] -> {:ok, key}
      [] -> {:error, :mail_source_not_found}
      _ -> {:error, :proactive_reference_ambiguous}
    end
  end

  defp valid_reference?(args) do
    Enum.all?(
      ~w(source_ref observation_id title request_id),
      &(is_binary(args[&1]) and byte_size(args[&1]) > 0)
    ) and
      byte_size(args["source_ref"]) <= 500 and byte_size(args["observation_id"]) <= 256 and
      byte_size(args["title"]) <= 500 and
      byte_size(args["request_id"]) <= 128 and is_map(args["read"])
  end

  defp source_key(read, ref),
    do: MailInteraction.key(source_account(read), ref)

  @doc "The account part of a matter key for a read recipe, shared with watch wakes."
  def source_account(%{"tool" => "recommendation.read", "arguments" => args}),
    do: args["source_id"] || "internal"

  def source_account(read),
    do: get_in(read, ["arguments", "connected_account_id"]) || "internal"
end
