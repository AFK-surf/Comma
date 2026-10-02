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
    "GITHUB_GET_A_PULL_REQUEST" => "github",
    "GITHUB_GET_AN_ISSUE" => "github",
    "LINEAR_GET_LINEAR_ISSUE" => "linear",
    "SLACK_FETCH_MESSAGE_THREAD_FROM_A_CONVERSATION" => "slack"
  }

  def ensure(args, ctx) do
    with {:ok, workspace, user} <- CommaWeb.Proactive.scope(ctx),
         {:ok, binding} <- source_binding(args["source"], workspace, user) do
      case Store.get_by_agent_path(ctx.agent_id, "/loops/proactive/" <> args["key"] <> ".elf") do
        {:ok, row} ->
          if row["status"] == "active" and row["session_id"] == ctx.session_id and
               row["config"]["comma_proactive"] == binding and same_input?(row, binding, args) and
               row["config"]["source_ref"] == args["source_ref"] and
               row["config"]["poll_interval_ms"] == (args["poll_interval_ms"] || 0) and
               (is_nil(args["trigger"]) or is_map(row["composio_trigger"])) do
            {:ok, Loops.public(row)}
          else
            install(args, ctx)
          end

        {:error, :not_found} ->
          install(args, ctx)

        error ->
          error
      end
    end
  end

  def install(args, ctx) do
    with {:ok, workspace, user} <- CommaWeb.Proactive.scope(ctx),
         :ok <- router(ctx, workspace),
         {:ok, _, _, home} <- CommaWeb.HomeMail.context(%{"id" => user}, %{}, ctx.group_id),
         :ok <- valid_args(args),
         {:ok, binding} <- source_binding(args["source"], workspace, user),
         :ok <- related_binding(args["related"], workspace, user, binding),
         {:ok, row} <- program(args, ctx, workspace, user, home, binding),
         {:ok, row} <- bind_trigger(row, args["trigger"], ctx),
         {:ok, result} <- resume(ctx, row) do
      {:ok, Map.take(result, ~w(loop_id status name))}
    end
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

  def current_consent(%{"toolkit" => "internal"}), do: :ok

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

  def source_binding(_, _, _), do: {:error, :proactive_source_required}

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

    ctx =
      Map.put_new_lazy(ctx, :tool_disclosure, fn ->
        SalixAgent.ToolDisclosure.materialize_prepared(
          "router",
          :internal,
          ctx,
          SalixAgent.Tools.ImRouter.internal_read_disclosure_entries(ctx),
          []
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
         {:ok, data} <- Jason.decode(result[:content] || result["content"] || ""),
         true <- is_map(data),
         true <-
           data["successful"] != false and data["error"] in [nil, false] and
             data["truncated"] != true do
      {:ok, data}
    else
      _ -> {:error, :proactive_tool_unavailable}
    end
  end

  def provider(%{"tool" => "recommendation.read"}), do: "Routine"
  def provider(nil), do: "Gmail"
  def provider(%{"tool" => "im_api.internal.read_conversation"}), do: "Comma"

  def provider(spec) do
    case @reads[get_in(spec, ["arguments", "tool_slug"])] do
      "gmail" -> "Gmail"
      "github" -> "GitHub"
      "linear" -> "Linear"
      "slack" -> "Slack"
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
          "message_id" => row["message_id"] || row["id"] || "source",
          "body" => body,
          "from" => if(is_binary(row["from"]), do: row["from"], else: "")
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
        "updated_at" => System.system_time(:millisecond)
      }

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
          Map.put(record, "created_at", System.system_time(:millisecond))
        )
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

    with true <-
           binding["toolkit"] != "internal" and
             String.starts_with?(trigger["slug"], String.upcase(binding["toolkit"]) <> "_"),
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
    else
      false -> {:error, :proactive_trigger_unavailable}
      error -> error
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
    do: Application.get_env(:salix_web, :composio_settings_mod, Salix.Control.ComposioSettings)

  defp client, do: Application.get_env(:salix_web, :composio_client_mod, SalixStore.Composio)
end
