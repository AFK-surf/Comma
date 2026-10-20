defmodule CommaWeb.ProactiveWatch do
  @moduledoc "Comma consent and enrollment on existing Agent-owned Loops."
  alias SalixAgent.{AgentActor, Loops}
  alias SalixStore.Loops, as: Store
  alias SalixIM.Conversations

  @source Path.expand(
            "../../../../../resources/salix-system-files/skills/proactive/scripts/watch.c",
            __DIR__
          )
  @external_resource @source
  @program File.read!(@source)
  @reads %{
    "GMAIL_FETCH_MESSAGE_BY_MESSAGE_ID" => "gmail",
    "GMAIL_FETCH_MESSAGE_BY_THREAD_ID" => "gmail",
    "GMAIL_FETCH_EMAILS" => "gmail",
    "OUTLOOK_OUTLOOK_GET_MESSAGE" => "outlook",
    "OUTLOOK_OUTLOOK_LIST_MESSAGES" => "outlook",
    "GOOGLECALENDAR_EVENTS_LIST" => "googlecalendar",
    "GOOGLEDRIVE_LIST_FILES" => "googledrive"
  }

  # Slack, GitHub, Linear and Notion reads use the Comma plugin's MCP
  # (`mcp.<provider>.*`), never a Composio account. The watch pins the plugin's
  # managed user OAuth binding, which proves the owner's member identity; the
  # Notion MCP itself calls with the same plugin's native MCP grant.
  @managed_mcp %{
    "slack" => "Slack",
    "github" => "GitHub",
    "linear" => "Linear",
    "notion" => "Notion"
  }

  def install(args, ctx) do
    with {:ok, workspace, user} <- CommaWeb.Proactive.scope(ctx),
         :ok <- router(ctx, workspace),
         {:ok, _, _, home} <- CommaWeb.HomeMail.context(%{"id" => user}, %{}, ctx.group_id),
         :ok <- valid_args(args),
         {:ok, binding} <- source_binding(args["source"], workspace, user),
         :ok <- related_binding(args["related"], workspace, user, binding),
         :ok <- trigger_supported(args["trigger"], binding),
         {:ok, row, prior} <- program(args, ctx, workspace, user, home, binding),
         {:ok, result} <- enable(row, prior, args["trigger"], ctx) do
      {:ok, Map.take(result, ~w(loop_id status name))}
    end
  end

  # A new watch that cannot start leaves no paused Loop behind. A replaced
  # watch that cannot start returns to its earlier recipe and status, with its
  # pending events and checkpoint.
  defp enable(row, prior, trigger, ctx) do
    with {:ok, row} <- bind_trigger(row, trigger, ctx),
         {:ok, result} <- resume(ctx, row) do
      {:ok, result}
    else
      error ->
        _ = restore(prior, row, ctx)
        error
    end
  end

  defp restore(:created, row, ctx), do: Loops.delete(ctx.agent_id, row["id"])
  defp restore(:existing, _row, _ctx), do: :ok

  defp restore({:replaced, old}, row, ctx) do
    with {:ok, restored} <-
           Store.update_mail_binding(row["id"], fn current ->
             {:ok,
              Map.merge(
                current,
                Map.take(old, ~w(name elf_path elf_sha256 composio_trigger config session_id))
              )}
           end),
         true <- old["status"] == "active" do
      resume(ctx, restored)
    else
      false -> :ok
      error -> error
    end
  end

  # Composio triggers belong to Composio accounts. Plugin MCP, internal and
  # Routine reads poll; reject a trigger before an existing watch is paused.
  defp trigger_supported(nil, _binding), do: :ok

  defp trigger_supported(trigger, binding) do
    if binding["toolkit"] != "internal" and binding["kind"] != "managed_oauth" and
         is_binary(trigger["slug"]) and
         String.starts_with?(trigger["slug"], String.upcase(binding["toolkit"]) <> "_"),
       do: :ok,
       else: {:error, :proactive_trigger_unavailable}
  end

  @doc """
  Records a watch's wake as the owner's Home matter and hands it to the
  Router through the one proactive delivery path, as every other proactive
  handoff. The owner asked for the watch, so it spends no automatic budget.
  The Loop's origin and label stay on the Router input. Loops Comma does not
  own return `:default` and wake their Session directly.
  """
  def deliver(row, content, dedup, origin) do
    case get_in(row, ["config", "comma_proactive"]) do
      %{"user_id" => owner} when is_binary(owner) ->
        handoff(row, owner, content, dedup, origin, 2)

      _ ->
        :default
    end
  end

  defp handoff(row, owner, content, dedup, origin, tries) do
    config = row["config"]
    account = CommaWeb.Proactive.source_account(config["source"] || %{})
    key = SalixIM.MailInteraction.key(account, config["source_ref"])

    request =
      "loop:" <> Base.encode16(:crypto.hash(:sha256, row["id"] <> ":" <> dedup), case: :lower)

    with {:ok, _, ctx, home} <- CommaWeb.HomeMail.context(%{"id" => owner}, %{}, row["group_id"]),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      current = SalixIM.MailInteraction.entries(conversation)[key]

      command = %{
        "action" => "present",
        "automatic" => false,
        "key" => key,
        "request_id" => request,
        "generation" => if(is_map(current), do: current["generation"]),
        "account_id" => account,
        "thread_id" => config["source_ref"],
        "message_id" => "loop:" <> dedup,
        # A matter the owner already follows keeps its subject and link.
        "subject" => (is_map(current) && current["subject"]) || config["intent"] || "",
        "source_url" => (is_map(current) && current["source_url"]) || "",
        "read" => config["source"],
        "text" => bounded(content),
        "trusted_origin" => origin
      }

      cond do
        # A redelivered wake was already handed over.
        is_map(current) and is_nil(current["pending"]) and
            request in [current["request_id"] | current["loop_requests"] || []] ->
          {:ok, :duplicate}

        true ->
          with {:ok, command} <- CommaWeb.HomeMail.retire_completed_task(command, ctx, home) do
            SalixIM.ConversationServer.mail_interaction(
              ctx.group_id,
              home,
              owner,
              ctx.agent_id,
              command
            )
          end
          |> case do
            {:ok, _} ->
              {:ok, :created}

            # The same observation was already handled: the wake is a duplicate.
            {:error, :mail_source_handled} ->
              {:ok, :duplicate}

            # A concurrent change moved the matter; read it again once.
            {:error, :mail_source_changed} when tries > 1 ->
              handoff(row, owner, content, dedup, origin, tries - 1)

            error ->
              error
          end
      end
    end
  end

  # A matter value keeps a bounded text; the Loop limits content to 8 KiB.
  # Home holds every matter in one bounded value (16 watches fit at this
  # cap). The watch's evidence is JSON: over the cap, its locator and
  # instructions come first and its largest evidence fields are cut and say
  # so. The Router can reread the source.
  @wake_bytes 4_000
  @cut "[evidence truncated]"
  @first ~w(instructions source_ref intent request_id watch_id now_ms)
  @shrinkable ~w(event source context previous related_read source_read)

  defp bounded(content) when byte_size(content) <= @wake_bytes, do: content

  defp bounded(content) do
    case Jason.decode(content) do
      {:ok, %{} = evidence} -> evidence |> shrink() |> encode()
      _ -> cut_text(content, @wake_bytes - byte_size(@cut) - 1) <> "\n" <> @cut
    end
  end

  defp shrink(evidence) do
    if byte_size(encode(evidence)) <= @wake_bytes do
      evidence
    else
      case largest(evidence) do
        nil ->
          evidence

        {field, encoded} ->
          room = max(byte_size(encoded) - (byte_size(encode(evidence)) - @wake_bytes) - 64, 0)
          shrink(Map.put(evidence, field, cut_text(encoded, room) <> " " <> @cut))
      end
    end
  end

  defp largest(evidence) do
    @shrinkable
    |> Enum.filter(&Map.has_key?(evidence, &1))
    |> Enum.map(fn field ->
      value = evidence[field]
      {field, if(is_binary(value), do: value, else: Jason.encode!(value))}
    end)
    |> Enum.reject(fn {_field, encoded} -> String.ends_with?(encoded, @cut) end)
    |> Enum.max_by(fn {_field, encoded} -> byte_size(encoded) end, fn -> nil end)
  end

  # Locator and instructions first, then the rest of the evidence.
  defp encode(evidence) do
    {first, rest} = Enum.split_with(evidence, fn {key, _} -> key in @first end)

    first
    |> Enum.sort_by(fn {key, _} -> Enum.find_index(@first, &(&1 == key)) end)
    |> Kernel.++(Enum.sort(rest))
    |> Jason.OrderedObject.new()
    |> Jason.encode!()
  end

  defp cut_text(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn g, acc ->
      if byte_size(acc) + byte_size(g) > limit, do: {:halt, acc}, else: {:cont, acc <> g}
    end)
  end

  def status(ctx) do
    with {:ok, _, user} <- CommaWeb.Proactive.scope(ctx),
         {:ok, rows} <- Store.proactive_monitors(ctx.agent_id) do
      {:ok,
       Enum.filter(
         rows,
         &((get_in(&1, ["config", "comma_proactive", "user_id"]) ||
              get_in(&1, ["config", "comma_mail", "user_id"])) == user)
       )}
    end
  end

  # Earlier releases enrolled these Loops for every owner. The proactive check
  # reads the same sources through official APIs, so the product retires them.
  # Loop deletion discards their pending events; the check reads those items.
  @retired_defaults ~w(/loops/proactive/home.elf /loops/proactive/gmail.elf /loops/comma-mail-v1.elf)

  def retire_defaults(ctx, owner) do
    Enum.reduce_while(@retired_defaults, :ok, fn path, :ok ->
      with {:ok, row} <- Store.get_by_agent_path(ctx.agent_id, path),
           binding =
             get_in(row, ["config", "comma_proactive"]) || get_in(row, ["config", "comma_mail"]),
           true <- is_map(binding) and binding["user_id"] == owner,
           :ok <- Loops.delete(ctx.agent_id, row["id"]) do
        {:cont, :ok}
      else
        {:error, :not_found} -> {:cont, :ok}
        false -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp resume(_ctx, %{"status" => "active"} = row), do: {:ok, Loops.public(row)}
  defp resume(ctx, row), do: Loops.resume(ctx.agent_id, row["id"])

  # This is the existing product-authorization hook. Ordinary authored Loops
  # retain their current capabilities; product enrollment cannot grant a source.
  def authorize(row, capability, args) do
    case get_in(row, ["config", "comma_proactive"]) do
      nil ->
        if is_map(get_in(row, ["config", "comma_mail"])),
          do: {:error, :proactive_watch_upgrade_required},
          else: :ok

      binding ->
        with {:ok, workspace} <-
               Comma.Workspaces.authorize_group(
                 %{"id" => binding["user_id"]},
                 %{},
                 row["group_id"]
               ),
             true <- workspace["id"] == binding["workspace_id"],
             true <- row["agent_id"] == workspace["router_agent_id"],
             true <-
               get_in(row, ["ifc", "creator"]) ==
                 SalixIFC.Codec.encode_principal!({:comma_user, binding["user_id"]}),
             {:ok, agent} <- SalixAgent.Control.get(row["agent_id"]),
             true <- row["session_id"] == agent["router_session_id"],
             :ok <- current_consent(binding),
             :ok <- allowed_call(row["config"], capability, args) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, :proactive_source_revoked}
        end
    end
  end

  # The plugin MCP reads a watch pinned: the Loop may load and call only these
  # dynamic tools, each with its exact pinned arguments (`authorize/3`).
  def pinned_tools(row) do
    config = row["config"] || %{}

    if is_map(config["comma_proactive"]) do
      for %{"tool" => tool} <- [config["source"], config["related"]],
          match?({:ok, _}, managed_toolkit(tool)),
          uniq: true,
          do: tool
    else
      []
    end
  end

  def current_consent(%{"toolkit" => "internal"}), do: :ok

  # The managed grant is current while the same connection still backs
  # the Group's active binding. A reconnect or removal retires the watch.
  def current_consent(%{"kind" => "managed_oauth"} = binding) do
    expected = Map.take(binding, ~w(binding_id connection_id))

    case managed_binding(binding["group_id"], binding["toolkit"]) do
      {:ok, current} when map_size(expected) == 2 ->
        if Map.take(current, ~w(binding_id connection_id)) == expected,
          do: :ok,
          else: {:error, :proactive_source_revoked}

      _ ->
        {:error, :proactive_source_revoked}
    end
  end

  def current_consent(binding) do
    if Comma.MemberSourceConsents.binding(
         binding["workspace_id"],
         binding["user_id"],
         binding["toolkit"]
       ) == Map.take(binding, ~w(connection_id consent_revision)),
       do: :ok,
       else: {:error, :proactive_source_revoked}
  end

  def source_binding(%{"tool" => "recommendation.read", "arguments" => args}, workspace, user)
      when is_map(args) do
    if CommaWeb.ProactiveRoutine.valid_args?(args),
      do: {:ok, %{"toolkit" => "internal", "workspace_id" => workspace["id"], "user_id" => user}},
      else: {:error, :proactive_source_required}
  end

  def source_binding(
        %{"tool" => "im_api.internal.read_conversation", "arguments" => args},
        workspace,
        user
      ) do
    with true <-
           args["connect_id"] == "internal" and is_binary(args["conversation_id"]) and
             is_integer(args["tail"]) and args["tail"] in 1..20,
         {:ok, _} <-
           Conversations.get_group_conversation_record(
             workspace["default_group_id"],
             args["conversation_id"]
           ) do
      {:ok, %{"toolkit" => "internal", "workspace_id" => workspace["id"], "user_id" => user}}
    else
      _ -> {:error, :proactive_source_required}
    end
  end

  def source_binding(%{"tool" => "composio.execute", "arguments" => args}, workspace, user) do
    toolkit = @reads[args["tool_slug"]]
    account = args["connected_account_id"]

    with true <- is_binary(toolkit) and is_binary(account) and is_map(args["arguments"]),
         true <- bounded_read?(args),
         %{"connection_id" => ^account} = receipt <-
           Comma.MemberSourceConsents.binding(workspace["id"], user, toolkit),
         {:ok, settings} <- settings().get(workspace["salix_tenant_id"]),
         {:ok, connected} <-
           client().get_connected_account(settings, account, error_mode: :structured),
         true <-
           connected["id"] == account and connected["user_id"] == workspace["default_group_id"] and
             connected["status"] == "ACTIVE" and get_in(connected, ["toolkit", "slug"]) == toolkit do
      {:ok,
       Map.merge(receipt, %{
         "toolkit" => toolkit,
         "workspace_id" => workspace["id"],
         "user_id" => user
       })}
    else
      _ -> {:error, :consented_source_required}
    end
  end

  # A managed MCP watch reads through the plugin's MCP with the owner's managed
  # user token. The binding pins the Group's active grant and the owner's member
  # identity on it; the Loop may call only this exact tool and arguments.
  def source_binding(%{"tool" => "mcp." <> _ = tool, "arguments" => args}, workspace, user)
      when is_map(args) do
    group = workspace["default_group_id"]

    with {:ok, toolkit} <- managed_toolkit(tool),
         {:ok, binding} <- managed_binding(group, toolkit),
         source = %{
           "kind" => "managed_oauth",
           "appId" => toolkit,
           "connectionId" => binding["binding_id"]
         },
         {:ok, identity} <- CommaWeb.RecommendationMemberIdentity.resolve(workspace, user, source),
         true <- identity["connection_id"] == binding["connection_id"] do
      {:ok,
       %{
         "kind" => "managed_oauth",
         "toolkit" => toolkit,
         "binding_id" => binding["binding_id"],
         "connection_id" => binding["connection_id"],
         "group_id" => group,
         "workspace_id" => workspace["id"],
         "user_id" => user
       }}
    else
      {:error, :proactive_source_required} = error -> error
      _ -> {:error, :consented_source_required}
    end
  end

  def source_binding(_, _, _), do: {:error, :proactive_source_required}

  defp managed_toolkit("mcp." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [toolkit, tool] when is_map_key(@managed_mcp, toolkit) and tool != "" -> {:ok, toolkit}
      _ -> {:error, :proactive_source_required}
    end
  end

  defp managed_toolkit(_tool), do: {:error, :proactive_source_required}

  defp managed_binding(group, provider) when is_binary(group) and is_binary(provider) do
    group
    |> Salix.Control.OAuthBindings.list()
    |> Enum.find(fn binding ->
      binding["provider"] == provider and binding["alias"] == provider and
        binding["status"] == "active" and binding["enabled"] != false and
        is_binary(binding["connection_id"]) and binding["connection_id"] != ""
    end)
    |> case do
      nil -> {:error, :consented_source_required}
      binding -> {:ok, binding}
    end
  end

  defp managed_binding(_group, _provider), do: {:error, :consented_source_required}

  def read(spec, ctx) do
    with {:ok, workspace, user} <- CommaWeb.Proactive.scope(ctx),
         {:ok, binding} <- source_binding(spec, workspace, user),
         {:ok, data} <- execute(spec, ctx),
         :ok <- current_consent(binding) do
      {:ok, data}
    end
  end

  # Use the same disclosure, IFC, archive and provider implementation as an
  # ordinary Agent call. Product enrollment adds consent; it does not fork tools.
  defp execute(spec, ctx) do
    ctx = Map.merge(ctx, %{role: "router", runtime_kind: :internal, llm_tool_envelope: false})

    # The pinned managed MCP read is the one dynamic MCP tool this read may use.
    mcp_entries =
      case managed_toolkit(spec["tool"]) do
        {:ok, _toolkit} ->
          name = spec["tool"]
          Enum.filter(SalixAgent.Tools.MCP.dynamic_disclosure_entries(ctx), &(&1["name"] == name))

        _ ->
          []
      end

    ctx =
      Map.put_new_lazy(ctx, :tool_disclosure, fn ->
        SalixAgent.ToolDisclosure.materialize_prepared(
          "router",
          :internal,
          ctx,
          SalixAgent.Tools.ImRouter.internal_read_disclosure_entries(ctx),
          mcp_entries
        )
      end)

    with [result] <-
           SalixAgent.SessionToolDispatch.execute(
             [
               %{
                 id: "proactive:" <> SalixStore.Ids.new_message_id(),
                 name: spec["tool"],
                 args: spec["arguments"]
               }
             ],
             ctx
           ),
         false <- result[:error] == true or result["error"] == true,
         {:ok, data} <- decode_read(spec["tool"], result[:content] || result["content"] || ""),
         true <- is_map(data),
         true <-
           data["successful"] != false and data["error"] in [nil, false] and
             data["truncated"] != true do
      {:ok, data}
    else
      _ -> {:error, :proactive_tool_unavailable}
    end
  end

  defp decode_read(tool, content) do
    case managed_toolkit(tool) do
      {:ok, _} -> {:ok, CommaWeb.ProactiveSourceProjection.project(content)}
      _ -> Jason.decode(content)
    end
  end

  @doc """
  The Loop host's result hook: a pinned plugin MCP read reaches the watch
  program as one bounded JSON object. Other results pass unchanged.
  """
  def project_result(row, tool, content) do
    if tool in pinned_tools(row),
      do: Jason.encode!(CommaWeb.ProactiveSourceProjection.project(content)),
      else: content
  end

  def provider(%{"tool" => "recommendation.read"}), do: "Routine"
  def provider(nil), do: "Gmail"
  def provider(%{"tool" => "im_api.internal.read_conversation"}), do: "Comma"

  def provider(%{"tool" => "mcp." <> _ = tool}) do
    case managed_toolkit(tool) do
      {:ok, toolkit} -> @managed_mcp[toolkit]
      _ -> "Comma"
    end
  end

  def provider(spec) do
    case @reads[get_in(spec, ["arguments", "tool_slug"])] do
      "gmail" -> "Gmail"
      "outlook" -> "Microsoft Outlook"
      "googlecalendar" -> "Google Calendar"
      "googledrive" -> "Google Drive"
      _ -> "Comma"
    end
  end

  # Bound the source shown in Home and used by follow-up decisions.
  def preview(result, spec) do
    data = if is_map(result["data"]), do: result["data"], else: result
    internal? = spec["tool"] == "im_api.internal.read_conversation"

    rows =
      if is_list(data["messages"]), do: data["messages"], else: [data]

    rows =
      if internal?,
        do:
          Enum.filter(rows, fn row ->
            is_map(row) and row["kind"] == "message" and row["actor_type"] in ~w(user agent)
          end),
        else: rows

    rows = Enum.take(rows, -20)

    messages =
      Enum.map(rows, fn row ->
        body =
          Enum.find_value(~w(body messageText description text), fn key ->
            if is_binary(row[key]), do: row[key]
          end)

        body =
          body || mime_preview(row) ||
            List.wrap(row["content"])
            |> Enum.filter(&is_map/1)
            |> Enum.map_join("\n", &(&1["text"] || ""))

        message = %{
          "message_id" => to_string(row["message_id"] || row["id"] || "source"),
          "body" => headline(row, body),
          "from" => author(row)
        }

        if internal? do
          Map.put(
            message,
            "has_attachments",
            Enum.any?(List.wrap(row["content"]), fn
              %{"type" => type} when type in ~w(file image local_file dynamic_ui) -> true
              _ -> false
            end)
          )
        else
          message
        end
      end)

    result = if internal?, do: Map.take(result, ~w(conversation_id)), else: result
    Map.put(result, "messages", messages)
  end

  # A pull request, issue or page names its title and state above its text.
  defp headline(row, body) do
    title = Enum.find(List.wrap(row["title"]) ++ List.wrap(row["name"]), &is_binary/1)

    state =
      Enum.find_value([row["state"], dig(row, ["state", "name"]), row["status"]], fn
        value when is_binary(value) -> value
        _ -> nil
      end)

    head =
      case {title, state} do
        {nil, _} -> nil
        {title, nil} -> title
        {title, state} -> "#{title} (#{state})"
      end

    Enum.join(Enum.reject([head, body], &(&1 in [nil, ""])), "\n\n")
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | rest]), do: dig(map[key], rest)
  defp dig(_value, _keys), do: nil

  defp author(row) do
    Enum.find_value(
      [row["from"], dig(row, ["user", "login"]), dig(row, ["creator", "name"])],
      "",
      fn value -> if is_binary(value), do: value end
    )
  end

  defp mime_preview(%{"payload" => %{}, "threadId" => thread} = message) do
    case CommaWeb.ProactiveMailSource.normalize(
           message,
           %{"id" => thread, "messages" => [message]},
           ""
         ) do
      {:ok, %{"messages" => [value]}} -> value["body"]
      _ -> nil
    end
  end

  defp mime_preview(_), do: nil

  defp program(args, ctx, _workspace, user, home, binding) do
    path = "/loops/proactive/" <> args["key"] <> ".elf"

    existing =
      case Store.get_by_agent_path(ctx.agent_id, path) do
        {:error, :not_found} ->
          if args["key"] == "gmail",
            do: Store.get_by_agent_path(ctx.agent_id, "/loops/comma-mail-v1.elf"),
            else: {:error, :not_found}

        result ->
          result
      end

    with {:ok, old} <- existing_row(existing),
         :ok <- replaceable(old, binding, args, user),
         :ok <- pause_existing(old, ctx),
         {:ok, %{"state" => "succeeded"} = report, event} <-
           Loops.build(ctx, %{"main.c" => @program}, "main.c", path),
         {:ok, committed} <-
           AgentActor.commit_workspace_operation(
             ctx.agent_id,
             "comma:proactive:" <> args["key"],
             report,
             [event],
             billing_context: ctx[:billing_context] || %{},
             actor_type: "user"
           ) do
      id = if old, do: old["id"], else: SalixStore.Ids.new_loop_id()

      record = %{
        "id" => id,
        "tenant_id" => ctx.tenant_id,
        "group_id" => ctx.group_id,
        "agent_id" => ctx.agent_id,
        "session_id" => ctx.session_id,
        "name" => args["intent"],
        "elf_path" => path,
        "elf_sha256" => committed["artifact_sha256"],
        "composio_trigger" => nil,
        "config" => %{
          "comma_proactive" => binding,
          "watch_id" => id,
          "source" => args["source"],
          "source_ref" => args["source_ref"],
          "intent" => args["intent"],
          "related" => args["related"],
          "context" => %{
            "tool" => "im_api.internal.read_conversation",
            "arguments" => %{
              "connect_id" => "internal",
              "conversation_id" => home,
              "query" => "Owner interests, handled work and earlier reminders",
              "tail" => 12,
              "limit" => 12
            }
          },
          "poll_interval_ms" => args["poll_interval_ms"] || 0
        },
        "ifc" => %{"creator" => SalixIFC.Codec.encode_principal!({:comma_user, user})},
        "status" => "paused",
        "updated_at" => SystemsClock.system_time(:millisecond)
      }

      written =
        if old do
          Store.update_mail_binding(id, fn current ->
            with :ok <- replaceable(current, binding, args, user),
                 true <-
                   current["status"] == "paused" and current["session_id"] == old["session_id"] do
              # Accepted work stays on the same Loop. A settled comparison
              # observation cannot supply evidence under a different source receipt.
              checkpoint = current["checkpoint"] || %{}

              checkpoint =
                if same_input?(current, binding, args),
                  do: checkpoint,
                  else: Map.delete(checkpoint, "observation")

              {:ok, current |> Map.merge(record) |> Map.put("checkpoint", checkpoint)}
            else
              false -> {:error, :proactive_watch_changed}
              error -> error
            end
          end)
        else
          Store.create_paused_by_path(
            Map.put(record, "created_at", SystemsClock.system_time(:millisecond))
          )
        end

      # Only a row this call created may be removed when the watch cannot
      # start; a replaced row returns to its earlier recipe.
      with {:ok, row} <- written do
        prior =
          cond do
            old -> {:replaced, old}
            row["id"] == id -> :created
            true -> :existing
          end

        {:ok, row, prior}
      end
    else
      {:ok, _, _} -> {:error, :proactive_build_failed}
      error -> error
    end
  end

  defp existing_row({:ok, row}), do: {:ok, row}
  defp existing_row({:error, :not_found}), do: {:ok, nil}
  defp existing_row(error), do: error
  defp pause_existing(nil, _ctx), do: :ok

  defp pause_existing(row, ctx) do
    case Loops.pause(ctx.agent_id, row["id"]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp replaceable(nil, _binding, _args, _user), do: :ok

  defp replaceable(row, binding, args, user) do
    old =
      get_in(row, ["config", "comma_proactive"]) || get_in(row, ["config", "comma_mail"]) || %{}

    cond do
      old["user_id"] != user or old["workspace_id"] != binding["workspace_id"] ->
        {:error, :proactive_watch_conflict}

      (map_size(row["pending_events"] || %{}) > 0 or
         is_map(get_in(row, ["checkpoint", "pending_poll"]))) and
          not same_input?(row, binding, args) ->
        {:error, :proactive_pending_events_require_original_source}

      true ->
        :ok
    end
  end

  defp same_input?(row, binding, args) do
    old =
      get_in(row, ["config", "comma_proactive"]) || get_in(row, ["config", "comma_mail"]) || %{}

    same_source =
      Map.take(old, ~w(connection_id consent_revision)) ==
        Map.take(binding, ~w(connection_id consent_revision))

    same_recipe =
      is_map(get_in(row, ["config", "comma_mail"])) or
        (row["config"]["source"] == args["source"] and row["config"]["related"] == args["related"])

    same_source and same_recipe
  end

  defp bind_trigger(row, nil, _ctx), do: {:ok, row}

  defp bind_trigger(row, trigger, ctx) do
    binding = row["config"]["comma_proactive"]

    with :ok <- trigger_supported(trigger, binding),
         {:ok, _} <-
           execute(
             %{
               "tool" => "composio.create_trigger",
               "arguments" => %{
                 "loop_id" => row["id"],
                 "connected_account_id" => binding["connection_id"],
                 "trigger_slug" => trigger["slug"],
                 "trigger_config" => trigger["config"] || %{}
               }
             },
             ctx
           ),
         :ok <- current_consent(binding) do
      Store.get_agent_owned(row["id"], ctx.agent_id)
    end
  end

  defp valid_args(args) do
    interval = args["poll_interval_ms"] || 0
    source = args["source"]

    valid =
      is_binary(args["key"]) and Regex.match?(~r/^[a-z0-9_-]{1,80}$/, args["key"]) and
        is_binary(args["source_ref"]) and byte_size(args["source_ref"]) in 1..500 and
        is_binary(args["intent"]) and byte_size(args["intent"]) in 1..500 and
        is_map(source) and is_map(source["arguments"]) and
        byte_size(Jason.encode!([source, args["related"]])) <= 5000 and
        is_integer(interval) and (interval == 0 or interval in 300_000..86_400_000) and
        (interval > 0 or is_map(args["trigger"])) and
        (is_nil(source["event_argument"]) or
           (is_binary(source["event_argument"]) and is_binary(source["event_field"]) and
              interval == 0))

    if valid, do: :ok, else: {:error, :invalid_proactive_watch}
  end

  defp bounded_read?(%{"tool_slug" => "GMAIL_FETCH_EMAILS", "arguments" => args}),
    do: args["max_results"] in 1..20

  # Keep optional Outlook watches inside the same existing Loop and bounded
  # to this owner’s account; never allow a delegated mailbox as a read recipe.
  defp bounded_read?(%{"tool_slug" => "OUTLOOK_OUTLOOK_GET_MESSAGE", "arguments" => args}),
    do:
      args["user_id"] in [nil, "me"] and is_binary(args["message_id"]) and
        byte_size(args["message_id"]) in 1..512

  defp bounded_read?(%{"tool_slug" => "OUTLOOK_OUTLOOK_LIST_MESSAGES", "arguments" => args}),
    do:
      args["user_id"] in [nil, "me"] and args["top"] in 1..40 and
        args["folder"] in [nil, "inbox", "Inbox", "sentitems", "SentItems"]

  # Composio exposes no get-one Calendar event or Drive file action. A watch
  # pins a filtered list read (an event's iCalUID or a file query) with a few
  # results, so the read stays inside the Loop's evidence limits.
  defp bounded_read?(%{"tool_slug" => "GOOGLECALENDAR_EVENTS_LIST", "arguments" => args}),
    do: is_binary(args["calendarId"]) and args["maxResults"] in 1..10

  defp bounded_read?(%{"tool_slug" => "GOOGLEDRIVE_LIST_FILES", "arguments" => args}),
    do: is_binary(args["q"]) and args["pageSize"] in 1..10

  defp bounded_read?(_), do: true

  defp allowed_call(_config, name, _args) when name in ~w(agent.notify decide), do: :ok

  defp allowed_call(config, name, args) do
    if Enum.any?(
         [config["source"], config["related"], config["context"]],
         &matches?(&1, name, args)
       ), do: :ok, else: {:error, :proactive_read_outside_source}
  end

  defp matches?(%{"tool" => name, "arguments" => expected} = spec, name, actual) do
    case spec["event_argument"] do
      nil ->
        expected == actual

      field ->
        nested = name == "composio.execute"
        value = if nested, do: get_in(actual, ["arguments", field]), else: actual[field]

        stripped =
          if nested,
            do: Map.update(actual, "arguments", %{}, &Map.delete(&1, field)),
            else: Map.delete(actual, field)

        expected =
          if nested,
            do: Map.update(expected, "arguments", %{}, &Map.delete(&1, field)),
            else: Map.delete(expected, field)

        is_binary(value) and byte_size(value) in 1..256 and expected == stripped
    end
  end

  defp matches?(_, _, _), do: false

  defp related_binding(nil, _workspace, _user, _binding), do: :ok

  defp related_binding(spec, workspace, user, binding) do
    with {:ok, ^binding} <- source_binding(spec, workspace, user),
         do: :ok,
         else: (_ -> {:error, :proactive_source_required})
  end

  defp router(ctx, workspace) do
    with {:ok, agent} <- SalixAgent.Control.get(ctx.agent_id),
         true <-
           workspace["router_agent_id"] == ctx.agent_id and
             agent["router_session_id"] == ctx.session_id,
         do: :ok,
         else: (_ -> {:error, :comma_home_router_required})
  end

  defp settings,
    do: SystemsRuntime.get_env(:salix_web, :composio_settings_mod, Salix.Control.ComposioSettings)

  defp client, do: SystemsRuntime.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)
end
