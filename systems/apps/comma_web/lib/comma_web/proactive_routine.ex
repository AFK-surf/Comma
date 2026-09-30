defmodule CommaWeb.ProactiveRoutine do
  @moduledoc "Reads selected Routine matters through their existing member projection."

  alias SalixIM.{Conversations, MailInteraction}

  def valid_args?(args) do
    args == %{} or args == %{"scope" => "status"} or
      (Enum.sort(Map.keys(args)) == ~w(source_id source_url) and
         is_binary(args["source_id"]) and byte_size(args["source_id"]) in 1..128 and
         is_binary(args["source_url"]) and byte_size(args["source_url"]) in 1..65_536)
  end

  def read(args, ctx) do
    with true <- valid_args?(args),
         {:ok, workspace, owner} <- CommaWeb.Proactive.scope(ctx),
         true <- workspace["router_agent_id"] == ctx[:agent_id],
         {:ok, agent} <- SalixAgent.Control.get(ctx[:agent_id]),
         true <- agent["router_session_id"] == ctx[:session_id],
         {:ok, envelope} <-
           Comma.Recommendations.read_existing(%{"id" => owner}, %{}, workspace["id"]) do
      select(args, if(args == %{}, do: project(envelope, workspace), else: envelope))
    else
      false -> {:error, :comma_home_router_required}
      error -> error
    end
  end

  defp select(args, envelope) when args == %{} do
    selected = if envelope["state"] == "fresh", do: items(envelope["snapshot"] || %{}), else: []

    status =
      case select(%{"scope" => "status"}, envelope) do
        {:ok, item} -> [item]
        _ -> []
      end

    {:ok, Map.put(envelope, "attention_items", selected ++ status)}
  end

  defp select(%{"scope" => "status"}, envelope) do
    warnings = get_in(envelope, ["snapshot", "warnings"]) || []
    failure = if envelope["state"] in ~w(error stale), do: envelope["lastError"]

    if is_binary(failure) or warnings != [] do
      observation =
        if failure,
          do: envelope["errorObservation"] || failure,
          else: "snapshot:#{envelope["snapshot"]["generation"]}:#{fingerprint(warnings)}"

      body =
        if failure,
          do: "Routine could not refresh: " <> failure,
          else: "Routine source warnings: " <> Enum.map_join(warnings, "; ", & &1["message"])

      {:ok,
       %{
         "source_ref" => "routine:status",
         "observation_id" => observation,
         "title" => "Routine needs attention",
         "body" => body,
         "state" => envelope["state"],
         "url" => "",
         "read" => %{"tool" => "recommendation.read", "arguments" => %{"scope" => "status"}}
       }}
    else
      {:error, :routine_failure_no_longer_current}
    end
  end

  defp select(args, %{"state" => "fresh", "snapshot" => snapshot}) when is_map(snapshot) do
    case Enum.find(items(snapshot), fn item ->
           item["source_id"] == args["source_id"] and item["url"] == args["source_url"]
         end) do
      nil -> {:error, :routine_source_not_current}
      item -> {:ok, item}
    end
  end

  defp select(_, _), do: {:error, :routine_result_not_fresh}

  # Store only selected matters, before the UI replaces mail links with Tasks.
  # This value shares snapshot publication/invalidation, not reminder ownership.
  def attach(snapshot, facts) do
    facts = Map.new(facts, &{&1["sourceId"], &1})

    selected =
      for card <- snapshot["cards"],
          row <- card["items"],
          %{"kind" => "inline-link", "link" => link} <- row["parts"] || [],
          prompt = (snapshot["prompts"] || %{})[link["promptId"]],
          is_map(prompt),
          do: selected(link, prompt, facts[link["sourceId"]] || %{})

    Map.put(
      snapshot,
      "attentionItems",
      selected |> Enum.reject(&is_nil/1) |> Enum.uniq_by(&{&1["sourceId"], &1["sourceUrl"]})
    )
  end

  defp selected(link, prompt, fact) do
    item = %{
      "sourceId" => link["sourceId"],
      "sourceUrl" => link["href"],
      "title" => prompt["objective"],
      "context" => prompt["context"]
    }

    pooled = Enum.find(fact["items"] || [], &(&1["url"] == link["href"])) || %{}

    item =
      if pooled["sourceVersion"],
        do: Map.put(item, "sourceVersion", pooled["sourceVersion"]),
        else: item

    if fact["toolkit"] == "gmail" do
      original = fact["data"] || %{}
      data = if is_map(original["_comma"]), do: original["value"] || %{}, else: original

      case Enum.find(data["messages"] || [], &(&1["webUrl"] == link["href"])) do
        %{"threadId" => thread, "messageId" => message}
        when is_binary(thread) and is_binary(message) ->
          Map.merge(item, %{
            "threadId" => thread,
            "messageId" => message,
            "taskId" => get_in(fact, ["mailTasks", link["href"], "conversation_id"])
          })

        _ ->
          nil
      end
    else
      item
    end
  end

  # Older snapshots remain readable, but need a Routine refresh before they
  # supply structured attention recipes. Never infer mail identity from a URL.
  def items(snapshot) do
    Enum.map(snapshot["attentionItems"] || [], fn item ->
      %{
        "evidence" => %{
          "kind" => "published_routine_snapshot",
          "generated_at" => snapshot["generatedAt"],
          "generation" => snapshot["generation"]
        },
        "source_id" => item["sourceId"],
        "title" => item["title"],
        "body" => item["context"],
        "url" => item["sourceUrl"],
        "task_id" => item["taskId"]
      }
      |> Map.merge(
        reference(
          item["sourceId"],
          item["sourceUrl"],
          item["context"],
          item["threadId"],
          item["messageId"],
          item["sourceVersion"]
        )
      )
    end)
  end

  @doc """
  The matter reference of one source item. Mail is its thread, observed at a
  message. Other items are their URL, observed at the pool's complete evidence
  version. A rewritten suggestion never starts new attention. Older snapshots
  without a pool version use their quoted source excerpt.
  Routine and the proactive check share these keys.
  """
  def reference(source_id, url, context, thread, message, version \\ nil)

  def reference(source_id, url, _context, thread, message, _version)
      when is_binary(thread) and is_binary(message),
      do: %{
        "source_ref" => thread,
        "observation_id" => message,
        "live_read" => %{
          "tool" => "composio.execute",
          "arguments" => %{
            "tool_slug" => "GMAIL_FETCH_MESSAGE_BY_THREAD_ID",
            "connected_account_id" => source_id,
            "arguments" => %{"user_id" => "me", "thread_id" => thread}
          }
        },
        "read" => routine_read(source_id, url)
      }

  def reference(source_id, url, context, _thread, _message, version),
    do: %{
      "source_ref" => "routine:" <> fingerprint([source_id, url]),
      "observation_id" => version || fingerprint([source_id, url, context]),
      "live_read" => nil,
      "read" => routine_read(source_id, url)
    }

  defp routine_read(source_id, url),
    do: %{
      "tool" => "recommendation.read",
      "arguments" => %{"source_id" => source_id, "source_url" => url}
    }

  # Comparison/compact references only, never provenance or authorization.
  # Source bindings authorize reads; generations and model titles are excluded.
  defp fingerprint(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  # A published association is a hint. The canonical Task and source relationship
  # still decide whether continuation is allowed; this never creates a Task.
  def continuation(%{"tool" => "recommendation.read"} = read, data, ctx) do
    with :ok <- current_task(data, ctx) do
      {:ok, data["live_read"] || read, data["task_id"]}
    end
  end

  def continuation(read, _data, _ctx), do: {:ok, read, nil}

  defp current_task(%{"task_id" => id} = item, ctx) when is_binary(id) do
    with {:ok, task} <- Conversations.get_group_conversation_record(ctx.group_id, id),
         true <- task["kind"] == "agent_task" and task["created_by_agent_id"] == ctx.agent_id,
         %{"connection_id" => account, "thread_id" => thread} <-
           get_in(task, ["source_refs", "comma_mail"]),
         true <- account == item["source_id"] and thread == item["source_ref"],
         true <- task["status"] not in ~w(completed cancelled archived ready_for_review),
         do: :ok,
         else: (_ -> {:error, :mail_task_stopped})
  end

  defp current_task(_, _), do: :ok

  def validate_reference(%{"read" => %{"tool" => "recommendation.read"}} = args, data) do
    if is_binary(data["source_ref"]) and args["source_ref"] == data["source_ref"] and
         args["observation_id"] == data["observation_id"],
       do: :ok,
       else: {:error, :routine_source_changed}
  end

  def validate_reference(_, _), do: :ok

  def project(envelope, workspace) do
    with %{"state" => "fresh", "snapshot" => snapshot} when is_map(snapshot) <- envelope,
         {:ok, group} <- SalixIM.GroupDirectory.get_group(workspace["default_group_id"]),
         {:ok, home} <- SalixIM.ConversationIds.group_router(group),
         {:ok, conversation} <-
           Conversations.get_group_conversation_record(workspace["default_group_id"], home) do
      stopped =
        items(snapshot)
        |> Enum.filter(fn item ->
          value =
            MailInteraction.entries(conversation)[
              MailInteraction.key(item["source_id"], item["source_ref"])
            ]

          is_map(value) and value["owner_id"] == workspace["owner_user_id"] and
            value["state"] == "handled" and value["message_id"] == item["observation_id"]
        end)
        |> MapSet.new(&{&1["source_id"], &1["url"]})

      if MapSet.size(stopped) == 0,
        do: envelope,
        else: Map.put(envelope, "snapshot", hide(snapshot, stopped))
    else
      _ -> envelope
    end
  end

  defp hide(snapshot, stopped) do
    hidden_tasks =
      (snapshot["attentionItems"] || [])
      |> Enum.filter(&MapSet.member?(stopped, {&1["sourceId"], &1["sourceUrl"]}))
      |> Enum.map(& &1["taskId"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    cards =
      Enum.flat_map(snapshot["cards"], fn card ->
        rows =
          Enum.reject(card["items"], fn row ->
            Enum.any?(row["parts"] || [], fn
              %{"kind" => "inline-link", "link" => link} ->
                MapSet.member?(stopped, {link["sourceId"], link["href"]})

              %{"kind" => "inline-task", "task" => task} ->
                MapSet.member?(hidden_tasks, task["conversationId"])

              _ ->
                false
            end)
          end)

        if rows == [], do: [], else: [Map.put(card, "items", rows)]
      end)

    # Summary prose can refer to removed rows without a link. Keep its greeting
    # instead of claiming that handled work still needs attention.
    snapshot =
      snapshot
      |> Map.put("cards", cards)
      |> Map.put("summary", greeting(snapshot["summary"]))
      |> Map.update(
        "attentionItems",
        [],
        &Enum.reject(&1, fn item ->
          MapSet.member?(stopped, {item["sourceId"], item["sourceUrl"]})
        end)
      )

    referenced = prompt_ids(Map.delete(snapshot, "prompts"))
    Map.update(snapshot, "prompts", %{}, &Map.take(&1, referenced))
  end

  defp greeting([%{"kind" => "markdown", "text" => text} | _]) do
    # Compiled summaries merge the greeting and the first paragraph in one part.
    # Without that separator, no prose can safely be attributed to a greeting.
    first =
      case String.split(text, "\n\n", parts: 2) do
        [title, _body] -> title
        _ -> ""
      end

    [%{"kind" => "markdown", "text" => first}]
  end

  defp greeting(_), do: [%{"kind" => "markdown", "text" => ""}]

  defp prompt_ids(map) when is_map(map),
    do:
      List.wrap(map["promptId"]) ++
        Enum.flat_map(Map.values(Map.delete(map, "promptId")), &prompt_ids/1)

  defp prompt_ids(list) when is_list(list), do: Enum.flat_map(list, &prompt_ids/1)
  defp prompt_ids(_), do: []
end
