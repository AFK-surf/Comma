defmodule CommaWeb.RecommendationMailTasks do
  @moduledoc """
  Links selected mail to its existing Task. Mail with a confirmed Task shows
  that Task, and its row opens the mail. Other mail keeps its pre-task prompt,
  which the member must confirm, as rows from every other source do. Search
  absence never creates a Task.
  """

  alias SalixIM.Conversations
  alias SalixStore.ConversationSearch

  # A member's Gmail source has at most 40 records. Canonical reads are capped
  # across this generation, not per card or render. No polling is introduced.
  def prepare(collection, workspace) do
    deadline = System.monotonic_time(:millisecond) + 1_500

    stopped = stopped_sources(workspace)

    {facts, _budget} =
      Enum.map_reduce(collection.facts, 40, fn fact, budget ->
        if fact["toolkit"] == "gmail" do
          {prepare_fact(fact, workspace, budget, deadline, stopped), 0}
        else
          {fact, budget}
        end
      end)

    %{collection | facts: facts}
  end

  defp stopped_sources(workspace) do
    with {:ok, group} <- SalixIM.GroupDirectory.get_group(workspace["default_group_id"]),
         {:ok, home} <- SalixIM.ConversationIds.group_router(group),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(workspace["default_group_id"], home) do
      SalixIM.MailInteraction.entries(conversation)
    else
      _ -> %{}
    end
  end

  defp prepare_fact(fact, workspace, budget, deadline, stopped) do
    original = fact["data"] || %{}

    data =
      if is_map(original["value"]) and is_map(original["_comma"]),
        do: original["value"],
        else: original

    messages = Enum.take(data["messages"] || [], 40)
    account = fact["sourceId"]
    threads = messages |> Enum.map(& &1["threadId"]) |> Enum.filter(&is_binary/1) |> Enum.uniq()
    group = workspace["default_group_id"]

    tasks =
      case if(budget > 0,
             do: ConversationSearch.mail_tasks(group, account, threads),
             else: {:error, :budget}
           ) do
        {:ok, hits} ->
          hits
          |> Enum.take(budget)
          |> Task.async_stream(
            fn hit ->
              with {:ok, task} <-
                     Conversations.get_group_conversation_record(group, hit.conversation_id),
                   "agent_task" <- task["kind"],
                   true <- task["created_by_agent_id"] == workspace["router_agent_id"],
                   %{"connection_id" => ^account, "thread_id" => thread} <-
                     get_in(task, ["source_refs", "comma_mail"]),
                   true <- thread == hit.thread_id do
                [{thread, task}]
              else
                _ -> []
              end
            end,
            max_concurrency: 4,
            timeout: max(div(deadline - System.monotonic_time(:millisecond), 10), 1),
            on_timeout: :kill_task
          )
          |> Enum.flat_map(fn
            {:ok, rows} -> rows
            _ -> []
          end)
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        _ ->
          %{}
      end

    messages =
      Enum.reject(messages, fn message ->
        value = stopped[SalixIM.MailInteraction.key(account, message["threadId"])]

        handled =
          is_map(value) and value["state"] == "handled" and
            value["message_id"] == message["messageId"]

        handled or
          case tasks[message["threadId"]] do
            [task] ->
              closed?(task) and
                get_in(task, ["source_refs", "comma_mail", "message_id"]) == message["messageId"]

            _ ->
              false
          end
      end)

    links =
      Map.new(messages, fn message ->
        task =
          case tasks[message["threadId"]] do
            [task] ->
              if closed?(task), do: nil, else: Map.take(task, ~w(conversation_id title status))

            _ ->
              nil
          end

        {message["webUrl"], task}
      end)

    fact
    |> Map.put(
      "data",
      if(is_map(original["_comma"]),
        do: Map.put(original, "value", Map.put(data, "messages", messages)),
        else: Map.put(data, "messages", messages)
      )
    )
    |> Map.put("mailTasks", links)
  end

  defp closed?(task), do: task["status"] in ~w(completed cancelled archived ready_for_review)

  def project(snapshot, facts) do
    links =
      facts
      |> Enum.filter(&(&1["toolkit"] == "gmail"))
      |> Enum.flat_map(fn fact ->
        for {url, %{} = task} <- fact["mailTasks"] || %{}, do: {{fact["sourceId"], url}, task}
      end)
      |> Map.new()

    snapshot = rewrite(snapshot, links)
    ids = prompt_ids(Map.delete(snapshot, "prompts"))

    if Map.has_key?(snapshot, "prompts"),
      do: Map.update!(snapshot, "prompts", &Map.take(&1, ids)),
      else: snapshot
  end

  defp rewrite(%{"parts" => parts, "action" => _} = item, links) do
    case Enum.find(parts, &mail_link?(&1, links)) do
      %{"link" => link} ->
        item
        |> Map.put("parts", Enum.map(parts, &rewrite(&1, links)))
        |> Map.put("action", %{
          "type" => "open_url",
          "label" => String.slice(link["label"], 0, 80),
          "href" => link["href"],
          "requiresConfirmation" => false
        })

      _ ->
        Map.new(item, fn {key, value} -> {key, rewrite(value, links)} end)
    end
  end

  defp rewrite(%{"kind" => "inline-link", "link" => link} = part, links) do
    case Map.fetch(links, {link["sourceId"], link["href"]}) do
      {:ok, %{"conversation_id" => id} = task} ->
        %{
          "kind" => "inline-task",
          "task" => %{
            "conversationId" => id,
            "label" => String.slice(task["title"] || link["label"], 0, 120),
            "sourceId" => link["sourceId"],
            "status" => task["status"]
          }
        }

      :error ->
        part
    end
  end

  defp rewrite(value, links) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, rewrite(child, links)} end)

  defp rewrite(value, links) when is_list(value), do: Enum.map(value, &rewrite(&1, links))
  defp rewrite(value, _links), do: value

  defp mail_link?(%{"kind" => "inline-link", "link" => link}, links),
    do: Map.has_key?(links, {link["sourceId"], link["href"]})

  defp mail_link?(_, _), do: false

  defp prompt_ids(map) when is_map(map),
    do:
      List.wrap(map["promptId"]) ++
        Enum.flat_map(Map.values(Map.delete(map, "promptId")), &prompt_ids/1)

  defp prompt_ids(list) when is_list(list), do: Enum.flat_map(list, &prompt_ids/1)
  defp prompt_ids(_), do: []
end
