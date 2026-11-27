defmodule CommaWeb.ProactiveRoutine do
  @moduledoc "Reads selected Routine matters through their existing member projection."

  alias Comma.RecommendationContract
  alias SalixIM.{Conversations, MailInteraction}
  alias SalixIM.Ports.StationHostedTasks

  @stillfail_source "stillfail"
  @stillfail_card_id "routine-stillfail"
  @max_stillfail_items 6
  @stillfail_system_card_kinds ~w(login secret vault signin device adb rig)
  @max_total_attention_items 18
  @jev_candidate_threshold 24
  @jev_max_overflow_scored 24
  @jev_batch_size 8
  @jev_max_payload_bytes 11_000
  @direct_relations ~w(mentioned_you direct_message_to_you assigned_to_you review_requested_from_you)
  @recent_ms 7 * 24 * 60 * 60 * 1_000

  def valid_args?(args) do
    args == %{} or args == %{"scope" => "status"} or
      (Enum.sort(Map.keys(args)) == ~w(source_id source_url) and
         is_binary(args["source_id"]) and byte_size(args["source_id"]) in 1..128 and
         is_binary(args["source_url"]) and byte_size(args["source_url"]) in 1..65_536)
  end

  def read(args, ctx) do
    with true <- valid_args?(args),
         {:ok, workspace, owner} <- router_scope(ctx),
         {:ok, envelope} <-
           Comma.Recommendations.read_existing(%{"id" => owner}, %{}, workspace["id"]) do
      case select(args, if(args == %{}, do: project(envelope, workspace), else: envelope)) do
        {:error, reason}
        when reason in [:routine_source_not_current, :routine_result_not_fresh] ->
          pooled(args, workspace, owner, reason)

        {:ok, overview} when args == %{} ->
          {:ok, Map.put(overview, "added_items", added_items(workspace, owner))}

        result ->
          result
      end
    else
      false -> {:error, :comma_home_router_required}
      error -> error
    end
  end

  @doc """
  The owner's Router dismisses one Routine matter, named by an attention item's
  source and URL.
  """
  def dismiss(%{"source_id" => source_id, "source_url" => url} = args, ctx)
      when map_size(args) == 2 do
    with {:ok, workspace, owner} <- router_scope(ctx),
         {:ok, _envelope} <-
           Comma.Recommendations.dismiss(%{"id" => owner}, %{}, workspace["id"], source_id, url) do
      {:ok, %{"dismissed" => true}}
    end
  end

  def dismiss(_args, _ctx), do: {:error, :invalid_recommendation_dismissal}

  @doc "The owner's Router adds a matter the owner asked for to their Routine."
  def add(args, ctx) when is_map(args) do
    with {:ok, workspace, owner} <- router_scope(ctx),
         {:ok, %{"item" => item, "envelope" => envelope}} <-
           Comma.Recommendations.add_item(%{"id" => owner}, %{}, workspace["id"], args) do
      {:ok, %{"added" => Map.take(item, ~w(id title)), "shown" => is_map(envelope["snapshot"])}}
    end
  end

  @doc "The owner's Router removes a matter the owner added, by its id."
  def remove_added(%{"id" => id}, ctx) when is_binary(id) do
    with {:ok, workspace, owner} <- router_scope(ctx),
         {:ok, _envelope} <-
           Comma.Recommendations.remove_added(%{"id" => owner}, %{}, workspace["id"], id) do
      {:ok, %{"removed" => true}}
    end
  end

  def remove_added(_args, _ctx), do: {:error, :invalid_routine_item}

  defp added_items(workspace, owner) do
    case Comma.Recommendations.get_runtime_profile(workspace["id"], owner) do
      {:ok, profile} ->
        Enum.map(
          Comma.Recommendations.added_items(profile),
          &Map.take(&1, ~w(id title detail url))
        )

      {:error, :not_found} ->
        []
    end
  end

  defp router_scope(ctx) do
    with {:ok, workspace, owner} <- CommaWeb.Proactive.scope(ctx),
         true <- workspace["router_agent_id"] == ctx[:agent_id],
         {:ok, agent} <- SalixAgent.Control.get(ctx[:agent_id]),
         true <- agent["router_session_id"] == ctx[:session_id] do
      {:ok, workspace, owner}
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

  # The check hands pool items to the Router between briefings. Until a
  # snapshot names one, the Router reads the evidence that the check judged.
  defp pooled(%{"source_id" => @stillfail_source, "source_url" => url}, workspace, owner, reason) do
    case find_stillfail_item(workspace, owner, url) do
      {:ok, item} -> {:ok, item}
      :error -> {:error, reason}
    end
  end

  defp pooled(%{"source_id" => source_id, "source_url" => url}, workspace, owner, reason) do
    case Comma.MemberSourceItems.find(workspace["id"], owner, source_id, url) do
      %Comma.Data.MemberSourceItem{} = item -> {:ok, pool_item(item)}
      nil -> {:error, reason}
    end
  end

  defp pooled(_args, _workspace, _owner, reason), do: {:error, reason}

  defp pool_item(item) do
    body =
      [item.excerpt, get_in(item.context || %{}, ["text"])]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join("\n")

    %{
      "evidence" => %{
        "kind" => "member_source_pool",
        "changed_at" => DateTime.to_iso8601(item.changed_at)
      },
      "source_id" => item.source_id,
      "title" => item.title,
      "body" => body,
      "relationship" => item.relationship,
      "url" => item.url,
      "task_id" => nil
    }
    |> Map.merge(
      reference(
        item.source_id,
        item.url,
        item.prompt_context,
        item.provider_ids["threadId"],
        item.provider_ids["messageId"],
        item.fingerprint,
        item.toolkit
      )
    )
  end

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

    if fact["toolkit"] in ~w(gmail outlook) do
      original = fact["data"] || %{}
      data = if is_map(original["_comma"]), do: original["value"] || %{}, else: original

      case Enum.find(data["messages"] || [], &(&1["webUrl"] == link["href"])) do
        %{"threadId" => thread, "messageId" => message}
        when is_binary(thread) and is_binary(message) ->
          Map.merge(item, %{
            "threadId" => thread,
            "messageId" => message,
            "toolkit" => fact["toolkit"],
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
          item["sourceVersion"],
          item["toolkit"]
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
  def reference(source_id, url, context, thread, message, version \\ nil, toolkit \\ "gmail")

  def reference(source_id, url, _context, thread, message, _version, "outlook")
      when is_binary(thread) and is_binary(message),
      do: %{
        "source_ref" => thread,
        "observation_id" => message,
        "live_read" => %{
          "tool" => "composio.execute",
          "arguments" => %{
            "tool_slug" => "OUTLOOK_OUTLOOK_GET_MESSAGE",
            "connected_account_id" => source_id,
            "arguments" => %{"user_id" => "me", "message_id" => message}
          }
        },
        "read" => routine_read(source_id, url)
      }

  def reference(source_id, url, _context, thread, message, _version, "gmail")
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

  def reference(source_id, url, context, _thread, _message, version, _toolkit),
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
      owner = workspace["owner_user_id"]

      stopped =
        items(snapshot)
        |> Enum.filter(fn item ->
          value =
            MailInteraction.entries(conversation)[
              MailInteraction.key(item["source_id"], item["source_ref"])
            ]

          is_map(value) and value["owner_id"] == owner and
            value["state"] == "handled" and value["message_id"] == item["observation_id"]
        end)
        |> MapSet.new(&{&1["source_id"], &1["url"]})

      snapshot =
        if MapSet.size(stopped) == 0,
          do: snapshot,
          else: Comma.Recommendations.hide_items(snapshot, &MapSet.member?(stopped, {&1, &2}))

      snapshot = project_stillfail(snapshot, workspace, owner, conversation)
      Map.put(envelope, "snapshot", snapshot)
    else
      _ -> envelope
    end
  end

  defp project_stillfail(snapshot, workspace, owner, conversation) do
    if Enum.any?(snapshot["cards"] || [], &(&1["id"] == @stillfail_card_id)) do
      snapshot
    else
      existing_urls =
        MapSet.new(snapshot["attentionItems"] || [], fn item -> item["sourceUrl"] end)

      all_candidates =
        workspace
        |> live_stillfail_rows(owner, conversation)
        |> Enum.reject(fn entry -> MapSet.member?(existing_urls, entry.row.url) end)

      candidates = Enum.take(all_candidates, @max_stillfail_items)
      overflow = length(all_candidates) - length(candidates)

      if candidates == [] do
        snapshot
      else
        zh? = String.starts_with?(Comma.Accounts.locale(owner), "zh")
        card = build_stillfail_card(candidates, zh?, overflow)
        snapshot = RecommendationContract.bound_after(snapshot, card)
        referenced = prompt_ids(Map.delete(snapshot, "prompts"))

        snapshot =
          if Map.has_key?(snapshot, "prompts"),
            do: Map.update!(snapshot, "prompts", &Map.take(&1, referenced)),
            else: snapshot

        kept_urls = card_link_urls(snapshot)

        added_attention =
          for entry <- candidates,
              MapSet.member?(kept_urls, entry.row.url),
              do: stillfail_attention_item(entry, zh?)

        merged_attention =
          (added_attention ++ (snapshot["attentionItems"] || []))
          |> Enum.uniq_by(&{&1["sourceId"], &1["sourceUrl"]})
          |> Enum.take(@max_total_attention_items)

        Map.put(snapshot, "attentionItems", merged_attention)
      end
    end
  end

  defp live_stillfail_rows(workspace, owner, conversation) do
    group_id = workspace["default_group_id"]
    now = SystemsClock.system_time(:millisecond)
    since = now - @recent_ms

    profile =
      case Comma.Recommendations.get_runtime_profile(workspace["id"], owner) do
        {:ok, found} -> found
        _ -> nil
      end

    with {:ok, %{"status" => "active", "email" => email}} when is_binary(email) <-
           Comma.Accounts.get_user(owner),
         true <- is_binary(group_id) do
      norm_email = String.downcase(String.trim(email))
      device_emails = SalixEnv.StillfailDevices.owner_emails_by_device(group_id)
      entries_map = if conversation, do: MailInteraction.entries(conversation), else: %{}

      group_id
      |> SalixStore.StationTaskIndex.list_group(200)
      |> Enum.flat_map(fn row ->
        emails = CommaWeb.ProactiveStationTask.matching_emails(row, norm_email, device_emails)

        with kind when kind in ~w(need done failed) <- stillfail_kind(row, emails, since),
             true <- valid_https_url?(row.url),
             false <- dismissed_stillfail?(profile, row.url),
             observation = stillfail_observation(kind, row.last_activity_at || 0),
             false <- station_handled?(entries_map, owner, row, observation) do
          [
            %{
              row: row,
              kind: kind,
              card_kind: stillfail_card_kind(row),
              observation: observation
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.sort_by(fn %{row: row, kind: kind, card_kind: card_kind} ->
        {stillfail_priority(kind, card_kind), -(row.last_activity_at || 0), row.thread}
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp find_stillfail_item(workspace, owner, url) do
    conversation =
      with {:ok, group} <- SalixIM.GroupDirectory.get_group(workspace["default_group_id"]),
           {:ok, home} <- SalixIM.ConversationIds.group_router(group),
           {:ok, conv} <-
             Conversations.get_group_conversation_record(workspace["default_group_id"], home) do
        conv
      else
        _ -> nil
      end

    zh? = String.starts_with?(Comma.Accounts.locale(owner), "zh")

    case Enum.find(live_stillfail_rows(workspace, owner, conversation), &(&1.row.url == url)) do
      %{row: row, observation: observation} = entry ->
        attn = stillfail_attention_item(entry, zh?)

        {:ok,
         %{
           "evidence" => %{
             "kind" => "station_task_index",
             "changed_at" =>
               (row.last_activity_at || 0)
               |> DateTime.from_unix!(:millisecond)
               |> DateTime.to_iso8601()
           },
           "source_id" => @stillfail_source,
           "title" => attn["title"],
           "body" => attn["context"],
           "relationship" => "waiting_on_you",
           "url" => row.url,
           "task_id" => StationHostedTasks.ref(row.station_id, row.thread)
         }
         |> Map.merge(
           reference(@stillfail_source, row.url, attn["context"], nil, nil, observation)
         )}

      nil ->
        :error
    end
  end

  defp stillfail_kind(%{attention: "need", waits_for: people}, emails, _since)
       when is_list(people) and people != [] do
    if stillfail_emails_intersect?(people, emails), do: "need"
  end

  defp stillfail_kind(%{attention: attention} = row, emails, since)
       when attention in ~w(need done failed) do
    at = row.last_activity_at || 0

    if stillfail_owner_involved?(row, emails) and (attention != "done" or at >= since),
      do: attention
  end

  defp stillfail_kind(%{attention: nil, waits_for: people} = row, emails, since)
       when people in [nil, []] do
    if row.status == "needs_review" and (row.last_activity_at || 0) >= since and
         stillfail_owner_involved?(row, emails),
       do: "need"
  end

  defp stillfail_kind(_row, _emails, _since), do: nil

  defp stillfail_owner_involved?(row, emails) do
    row.router == true or
      stillfail_emails_intersect?(row.waits_for, emails) or
      stillfail_email_in?(row.created_by, emails) or
      stillfail_emails_intersect?(Map.get(row, :participants), emails)
  end

  defp stillfail_emails_intersect?(list, emails) when is_list(list) do
    Enum.any?(list, &stillfail_email_in?(&1, emails))
  end

  defp stillfail_emails_intersect?(_list, _emails), do: false

  defp stillfail_email_in?(value, emails) when is_binary(value) do
    String.downcase(String.trim(value)) in emails
  end

  defp stillfail_email_in?(_value, _emails), do: false

  defp stillfail_observation("need", at), do: "needs_review:" <> Integer.to_string(at)
  defp stillfail_observation(kind, at), do: kind <> ":" <> Integer.to_string(at)

  defp stillfail_card_kind(row) do
    Enum.find_value(row.labels || [], fn
      "card:" <> kind when kind != "" -> kind
      _ -> nil
    end)
  end

  defp valid_https_url?(url) when is_binary(url),
    do: String.starts_with?(url, "https://") and byte_size(url) <= 2_048

  defp valid_https_url?(_url), do: false

  defp dismissed_stillfail?(nil, _url), do: false

  defp dismissed_stillfail?(profile, url),
    do: Comma.Recommendations.dismissed?(profile, @stillfail_source, url)

  defp station_handled?(entries_map, owner, row, observation) do
    ref = StationHostedTasks.ref(row.station_id, row.thread)
    value = entries_map[MailInteraction.key("station_task", ref)]

    is_map(value) and value["owner_id"] == owner and value["state"] in ~w(handled quiet) and
      value["message_id"] == observation
  end

  defp stillfail_priority("need", card_kind) when card_kind in @stillfail_system_card_kinds, do: 0
  defp stillfail_priority("need", _card_kind), do: 1
  defp stillfail_priority("failed", _card_kind), do: 2
  defp stillfail_priority("done", _card_kind), do: 3
  defp stillfail_priority(_kind, _card_kind), do: 4

  defp build_stillfail_card(entries, zh?, overflow) do
    rows =
      Enum.map(entries, fn %{row: row, kind: kind, card_kind: card_kind} ->
        label = clean_text(row.title, 120, row.thread)
        badge = stillfail_badge(kind, card_kind, zh?)
        note = clean_text(row.note, 180, "")
        detail_body = if note == "", do: badge, else: badge <> " — " <> note

        %{
          "id" => "stillfail-" <> String.slice(fingerprint([row.station_id, row.thread]), 0, 16),
          "parts" => [
            %{
              "kind" => "inline-link",
              "link" => %{
                "label" => label,
                "href" => row.url,
                "sourceId" => @stillfail_source
              }
            },
            %{
              "kind" => "markdown",
              "text" => " · " <> String.slice(detail_body, 0, 240)
            }
          ],
          "action" => %{
            "type" => "send_to_comma",
            "label" => if(zh?, do: "查看", else: "Review"),
            "prompt" => String.slice(label <> "\n" <> row.url, 0, 500),
            "requiresConfirmation" => true
          }
        }
      end)

    overflow_rows =
      if overflow > 0 do
        summary =
          cond do
            zh? -> "还有 #{overflow} 条 Monoid 任务待关注"
            overflow == 1 -> "+1 more Monoid task needs attention"
            true -> "+#{overflow} more Monoid tasks need attention"
          end

        [
          %{
            "id" => "stillfail-overflow",
            "parts" => [%{"kind" => "markdown", "text" => summary}],
            "action" => %{
              "type" => "send_to_comma",
              "label" => if(zh?, do: "查看全部", else: "View all"),
              "prompt" =>
                if(zh?,
                  do: "列出我目前所有待关注的 Monoid 任务和状态。",
                  else: "List all my Monoid tasks that currently need attention."
                ),
              "requiresConfirmation" => true
            }
          }
        ]
      else
        []
      end

    fallback =
      entries
      |> Enum.map_join("; ", fn %{row: row} -> clean_text(row.title, 80, row.thread) end)
      |> String.slice(0, 800)

    %{
      "id" => @stillfail_card_id,
      "template" => "text-list@1",
      "title" => if(zh?, do: "Monoid 待处理与新结果", else: "Monoid Tasks"),
      "sourceIds" => [@stillfail_source],
      "fallbackText" => if(fallback == "", do: "Monoid", else: fallback),
      "items" => rows ++ overflow_rows
    }
  end

  defp stillfail_attention_item(
         %{row: row, kind: kind, card_kind: card_kind, observation: obs},
         zh?
       ) do
    title = clean_text(row.title, 110, row.thread)
    badge = stillfail_badge(kind, card_kind, zh?)
    note = clean_text(row.note, 450, "")
    context = if note == "", do: badge, else: badge <> ": " <> note

    %{
      "sourceId" => @stillfail_source,
      "sourceUrl" => row.url,
      "title" => title,
      "context" => String.slice(context, 0, 580),
      "sourceVersion" => obs
    }
  end

  defp stillfail_badge("need", card, true) when is_binary(card), do: "等你确认 (#{card})"
  defp stillfail_badge("need", _card, true), do: "等你回复"
  defp stillfail_badge("failed", _card, true), do: "执行失败"
  defp stillfail_badge("done", _card, true), do: "已完成未读"
  defp stillfail_badge("need", card, false) when is_binary(card), do: "Needs #{card} action"
  defp stillfail_badge("need", _card, false), do: "Waiting on you"
  defp stillfail_badge("failed", _card, false), do: "Failed"
  defp stillfail_badge("done", _card, false), do: "Completed (unread)"

  defp clean_text(value, max_graphemes, fallback) when is_binary(value) do
    cleaned =
      value
      |> String.replace(~r/\s+/u, " ")
      |> String.replace(~r/<\/?a[\s>]/i, "")
      |> String.trim()

    if cleaned == "", do: fallback, else: String.slice(cleaned, 0, max_graphemes)
  end

  defp clean_text(_value, _max_graphemes, fallback), do: fallback

  defp card_link_urls(snapshot) do
    for card <- snapshot["cards"] || [],
        row <- card["items"] || [],
        %{"kind" => "inline-link", "link" => %{"href" => href}} <- row["parts"] || [],
        into: MapSet.new(),
        do: href
  end

  defp prompt_ids(map) when is_map(map),
    do:
      List.wrap(map["promptId"]) ++
        Enum.flat_map(Map.values(Map.delete(map, "promptId")), &prompt_ids/1)

  defp prompt_ids(list) when is_list(list), do: Enum.flat_map(list, &prompt_ids/1)
  defp prompt_ids(_), do: []

  @doc """
  When member candidates exceed #{@jev_candidate_threshold}, uses `SalixAgent.Decide`
  (`Jev`) with `SalixStore.ProactiveKernel.gate_jev_decision/1` (`mode: :recall`)
  to promote actionable edge items ahead of low-signal overflow candidates.
  Falls back to the original candidate list if Decide is unavailable or errors.
  """
  def prioritize_candidates(%{member_candidates: candidates} = context, workspace)
      when is_list(candidates) and is_map(workspace) do
    if length(candidates) <= @jev_candidate_threshold do
      context
    else
      {direct, edge} =
        Enum.split_with(candidates, fn c ->
          c["relationship"] in @direct_relations
        end)

      {pinned, overflow} =
        if length(direct) >= @jev_candidate_threshold do
          {direct, edge}
        else
          need = @jev_candidate_threshold - length(direct)
          {kept_edge, rest_edge} = Enum.split(edge, need)
          {direct ++ kept_edge, rest_edge}
        end

      if overflow == [] do
        context
      else
        case score_overflow_recall(overflow, workspace) do
          {:ok, promoted} ->
            %{context | member_candidates: pinned ++ promoted}

          :fallback ->
            context
        end
      end
    end
  end

  def prioritize_candidates(context, _workspace), do: context

  defp score_overflow_recall(overflow, workspace) do
    with {:ok, ctx} <- jev_decide_context(workspace) do
      {to_score, tail_unscored} = Enum.split(overflow, @jev_max_overflow_scored)
      batches = Enum.chunk_every(to_score, @jev_batch_size)

      {promoted_scored, failed_items, succeeded_batches} =
        Enum.reduce(batches, {[], [], 0}, fn batch, {promoted_acc, failed_acc, ok_count} ->
          score_recall_batch(batch, ctx, promoted_acc, failed_acc, ok_count)
        end)

      if succeeded_batches == 0 do
        :fallback
      else
        promoted =
          promoted_scored
          |> Enum.sort_by(fn {prob, _c} -> -prob end)
          |> Enum.map(&elem(&1, 1))

        {:ok, promoted ++ Enum.reverse(failed_items) ++ tail_unscored}
      end
    else
      _ -> :fallback
    end
  rescue
    _ -> :fallback
  end

  defp jev_decide_context(workspace) do
    tenant_id = workspace["salix_tenant_id"]
    group_id = workspace["default_group_id"]
    agent_id = workspace["router_agent_id"]

    with true <- non_empty_string?(tenant_id),
         true <- non_empty_string?(group_id),
         true <- non_empty_string?(agent_id),
         {:ok, agent} <- SalixAgent.Control.get(agent_id),
         session_id when is_binary(session_id) and session_id != "" <- agent["router_session_id"],
         {:ok, group} <- SalixAgent.GroupContext.get(group_id, tenant_id) do
      billing_context =
        case group["billing_owner"] do
          %{} = billing -> billing
          _ -> %{}
        end

      {:ok,
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         agent_id: agent_id,
         session_id: session_id,
         billing_context: billing_context
       }}
    else
      _ -> :error
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp score_recall_batch(batch, ctx, promoted_acc, failed_acc, ok_count) do
    case build_recall_payload(batch, 240) do
      {:ok, args} ->
        deadline = SystemsClock.monotonic_time(:millisecond) + 3_000

        case SalixAgent.Decide.system_call(
               args,
               ctx,
               entrypoint: "proactive_routine_recall",
               admission_deadline: deadline
             ) do
          {:ok, %{"answers" => answers}} when is_map(answers) ->
            {next_promoted, next_failed} =
              batch
              |> Enum.with_index()
              |> Enum.reduce({promoted_acc, failed_acc}, fn {candidate, idx}, {p_acc, f_acc} ->
                case Map.get(answers, "q#{idx}") do
                  %{} = ans ->
                    prob_bp = get_in(ans, ["probabilities_bp", "promote"]) || 0

                    case SalixStore.ProactiveKernel.gate_jev_decision(%{
                           mode: :recall,
                           probability_bp: prob_bp
                         }) do
                      :promote -> {[{prob_bp, candidate} | p_acc], f_acc}
                      :drop -> {p_acc, f_acc}
                    end

                  nil ->
                    {p_acc, [candidate | f_acc]}
                end
              end)

            {next_promoted, next_failed, ok_count + 1}

          _ ->
            {promoted_acc, Enum.reverse(batch, failed_acc), ok_count}
        end

      :too_large when length(batch) > 1 ->
        mid = div(length(batch), 2)
        {left, right} = Enum.split(batch, mid)

        {p1, f1, o1} = score_recall_batch(left, ctx, promoted_acc, failed_acc, ok_count)
        score_recall_batch(right, ctx, p1, f1, o1)

      :too_large ->
        {promoted_acc, Enum.reverse(batch, failed_acc), ok_count}
    end
  end

  defp build_recall_payload(batch, excerpt_limit) do
    indexed = Enum.with_index(batch)

    items =
      Enum.map(indexed, fn {c, idx} ->
        %{
          "key" => "q#{idx}",
          "title" => String.slice(c["title"] || "", 0, 120),
          "excerpt" => String.slice(c["excerpt"] || "", 0, excerpt_limit),
          "relationship" => c["relationship"]
        }
      end)

    questions =
      Map.new(indexed, fn {_c, idx} ->
        key = "q#{idx}"

        {key,
         %{
           "type" => "choice",
           "instructions" =>
             "Decide whether candidate #{key} warrants recall into the member's daily Routine briefing.",
           "criteria" => %{
             "promote" =>
               "Requires member action, decision, review, follow-up, or awareness today",
             "drop" => "Passive background noise or unactionable notification"
           }
         }}
      end)

    args = %{"state" => %{"candidates" => items}, "questions" => questions}

    cond do
      byte_size(Jason.encode!(args)) <= @jev_max_payload_bytes ->
        {:ok, args}

      excerpt_limit > 0 ->
        build_recall_payload(batch, div(excerpt_limit, 2))

      true ->
        :too_large
    end
  end
end
