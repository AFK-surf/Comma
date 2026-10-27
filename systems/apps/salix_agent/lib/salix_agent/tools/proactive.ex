defmodule SalixAgent.Tools.Proactive do
  @moduledoc "Comma-owned attention state. Reads and decisions use existing tools."

  def defs do
    read = %{
      "type" => "object",
      "properties" => %{
        "tool" => %{
          "type" => "string",
          "description" =>
            "composio.execute, im_api.internal.read_conversation, recommendation.read, or one plugin MCP read: mcp.slack.*, mcp.github.*, mcp.linear.* or mcp.notion.*",
          "pattern" =>
            "^(composio\\.execute|im_api\\.internal\\.read_conversation|recommendation\\.read|mcp\\.(slack|github|linear|notion)\\.[A-Za-z0-9_-]+)$"
        },
        "arguments" => %{"type" => "object"},
        "event_argument" => string(),
        "event_field" => string()
      },
      "required" => ["tool", "arguments"],
      "additionalProperties" => false
    }

    [
      tool(
        "state",
        "Read the user's canonical reminder states, bounded watches, automatic handoff budget, notification budget, whether the user can see Home replies in the desktop App now (app_active), the user's bound personal chats (personal_targets: the exact reply tool and arguments for a reminder you decided on while app_active is false) and the Drive path of their proactive notebook when it exists. Reuse exact keys/generations and linked Task creation receipts. Read source facts through existing Composio or conversation tools; no provider read or write occurs here.",
        %{},
        [],
        :state,
        "read"
      ),
      tool(
        "watch",
        "Follow one matter the user asked about, such as a pull request, issue, page or thread, with the bundled proactive Loop. Slack, GitHub, Linear and Notion reads use the connected plugin MCP tool (mcp.slack.*, mcp.github.*, mcp.linear.*, mcp.notion.*) with a poll interval. Confirm the follow only after success. Comma already checks connected sources for new work; do not watch them again.\n\nDiscover read schemas with existing tools. Supply a stable key, source_ref, exact read recipe with a pinned account (or internal conversation), and either a provider trigger or a bounded poll interval of 5 minutes to 24 hours. Plugin MCP, internal and Routine reads have no provider trigger. Optional related read binds a field from the primary result for a thread/context read. This is enrollment, not another Task or permission to write to a source.",
        %{
          "key" => string(),
          "intent" => string(),
          "source_ref" => string(),
          "source" => read,
          "related" => read,
          "poll_interval_ms" => %{
            "type" => "integer",
            "minimum" => 300_000,
            "maximum" => 86_400_000
          },
          "trigger" => %{
            "type" => "object",
            "properties" => %{"slug" => string(), "config" => %{"type" => "object"}},
            "required" => ["slug"],
            "additionalProperties" => false
          }
        },
        ~w(key intent source_ref source),
        :watch,
        "write"
      ),
      tool(
        "act",
        "Update proactive matter and reminder state: track, remind, notify, quiet, snooze, draft, handled, link_task, resume or source. Send replies through normal authorized reply tools, never through this state tool.\n\nUse track to record a freshly read source and observation without sending any message. Use remind with source_ref, observation_id, title, exact read recipe and future run_at to create an explicit reminder at a time the user chose. After a background handoff, record your decision on its key before replying: notify spends the user's notification budget for an automatic matter and fails when it is closed, quiet records why you stay quiet, and snooze with a reason rechecks the matter at run_at. Apply the user's reply to the same canonical reminder across App/Telegram/WeChat: draft starts the offered work in a Task, snooze reminds later, handled ends it, and link_task or resume repair state. Supply its exact key from state and a stable request_id; snooze takes future Unix milliseconds run_at. Use source to inspect its fresh source. If an unquoted reply has several possible subjects, ask which one: omitting key only resolves a single active reminder. Handled does not close an external issue or complete a Task. Confirm only after success.",
        %{
          "action" => %{
            "type" => "string",
            "enum" => ~w(track remind notify quiet handled snooze draft link_task resume source)
          },
          "source_ref" => string(),
          "observation_id" => string(),
          "title" => string(),
          "url" => %{"type" => "string", "maxLength" => 65_536},
          "read" => read,
          "key" => string(),
          "request_id" => string(),
          "generation" => %{"type" => "integer", "minimum" => 1},
          "run_at" => %{"type" => "integer"},
          "task_id" => string(),
          "reason" => string()
        },
        ~w(action request_id),
        :act,
        "write"
      )
    ]
  end

  def state(args, ctx), do: call(:state, args, ctx)
  def watch(args, ctx), do: call(:watch, args, ctx)
  def act(args, ctx), do: call(:act, args, ctx)

  defp call(operation, args, ctx) do
    module = SystemsRuntime.get_env(:salix_agent, :proactive_adapter)
    if is_nil(module), do: raise("Comma proactive controls are unavailable")

    case apply(module, operation, [args, ctx]) do
      {:ok, result} ->
        SalixAgent.IFC.ConnectorLabels.group_audience(Jason.encode!(result), ctx)

      {:error, reason} ->
        raise "Proactive #{operation} failed: #{inspect(reason)}" <> hint(reason)
    end
  end

  # The Router must tell the owner why a follow is not active and what fixes it.
  defp hint(:consented_source_required),
    do:
      ". The user has not connected this source through its Comma plugin, or the pinned account is not theirs. An account from composio.request_connection cannot be watched; ask the user to connect the plugin in Plugins."

  defp hint(:proactive_source_required),
    do:
      ". This read cannot be watched. Use a plugin MCP read (mcp.slack.*, mcp.github.*, mcp.linear.*, mcp.notion.*), a supported Composio read, an internal conversation or recommendation.read."

  defp hint(:proactive_trigger_unavailable),
    do: ". This source has no provider trigger here; use poll_interval_ms instead."

  defp hint(:comma_home_router_required),
    do: ". Only the user's Home Router session can enroll a watch."

  defp hint(:invalid_proactive_watch),
    do:
      ". Check key (a-z, 0-9, _ or -), source_ref, intent, and either poll_interval_ms (300000-86400000) or a trigger."

  defp hint(_reason), do: ""

  defp string, do: %{"type" => "string", "minLength" => 1, "maxLength" => 1000}

  defp tool(name, description, properties, required, function, safety),
    do:
      {"proactive." <> name, description,
       %{
         "type" => "object",
         "properties" => properties,
         "required" => required,
         "additionalProperties" => false
       }, Function.capture(__MODULE__, function, 2), 30, [safety: safety]}
end
