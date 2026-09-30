defmodule SalixAgent.MigrationNotice do
  @moduledoc false

  @version 52
  @superseded_versions [
    11,
    18,
    19,
    24,
    25,
    26,
    28,
    5,
    6,
    7,
    8,
    9,
    10,
    12,
    13,
    14,
    15,
    17,
    20,
    30,
    33,
    34,
    39,
    40,
    41,
    42,
    47,
    49,
    51
  ]

  @doc false
  def version, do: @version

  @doc false
  def normalize_version(version) when is_integer(version) and version >= 0, do: version
  def normalize_version(version) when is_integer(version), do: 0

  def normalize_version(version) when is_binary(version) do
    trimmed = String.trim(version)

    case Integer.parse(trimmed) do
      {int, ""} when int >= 0 -> int
      _ -> 0
    end
  end

  def normalize_version(_), do: 0

  @doc false
  def payloads_since(version) do
    version = normalize_version(version)

    if version >= @version do
      []
    else
      (version + 1)..@version
      # Current notices replace these older call-shape instructions. Never put
      # obsolete and canonical Task-create/list names in one model-visible
      # upgrade notice.
      |> Enum.reject(&(&1 in @superseded_versions))
      |> Enum.map(&payload/1)
    end
  end

  defp payload(version) do
    %{
      "type" => "migration_notice_delta",
      "runtime_message_id" => "migration-notice-version:#{version}",
      "version" => version,
      "summary" => summary(version),
      "wake" => false,
      "content" => content(version)
    }
  end

  defp summary(52), do: "Router completion and status notices use current Task policy"

  defp summary(51), do: "Tasks use ordinary Worker delegation"

  defp summary(45), do: "structured result delivery preserves widgets on follow-up"

  defp summary(1), do: "tool calls use the current canonical contract"
  defp summary(2), do: "durable memory uses canonical memory file tools"
  defp summary(3), do: "skill discovery uses runtime skill files"
  defp summary(4), do: "external runtime identity uses device runtime binding"
  defp summary(16), do: "known Task mentions use committed inline references"
  defp summary(21), do: "internal turns require an explicit work outcome"
  defp summary(22), do: "Task listing moved into internal IM"
  defp summary(23), do: "Task creation moved into internal IM"
  defp summary(27), do: "conversation participant mutation moved into internal IM"
  defp summary(29), do: "visible conversation Messages require explicit send_message"
  defp summary(31), do: "Slack replies use standard Markdown and provider-native rendering"
  defp summary(32), do: "Slack reply keywords link to known destinations"
  defp summary(35), do: "Complete outstanding file delivery from the existing attachment"

  defp summary(36),
    do: "Router Agent management uses named Workers, bounded pages and permanent archive"

  defp summary(37), do: "Router defaults to Tasks with explicit direct-handling exceptions"

  defp summary(38), do: "Worker creation requires purpose and retained creation provenance"

  defp summary(39), do: "IM and Comma final replies settle without another model request"

  defp summary(44), do: "Workers deliver structured results as UI within the existing Task"

  defp summary(43), do: "Restore original Router routing and restrict UI creation to Workers"

  defp summary(46), do: "Slack text sends split into thread replies and new channel topics"

  defp summary(48), do: "Use C scripts and the IM API for Comma replies"
  defp summary(49), do: "A final source reply can accompany end_turn"
  defp summary(50), do: "Reply history preserves completion calls and delivered receipts"

  defp summary(47), do: "Router delivery requires separate completion"

  defp summary(_version), do: "migration notice changed"

  defp content(52),
    do:
      "This replaces notice 51 and older instructions that only human acceptance can set completed. Create Tasks with agent_id and self-contained content. Task graph tools remain retired. Workers publish result Messages and cannot set status. Only the owning Router may complete a plain one-shot Task through internal.update_conversation after verified delivery with no remaining work or human decision. Recurring, product-assigned Triage and legacy Workflow Tasks cannot use this path. Human acceptance remains a separate version-checked operation. Existing Tasks retain identity and history. For each confirmed status change, end the original-source reply with the Task name, current status and its practical consequence under current Router policy. If that reply was already sent, promptly send a short follow-up within existing audience permissions. Report failed updates truthfully, avoid duplicate same-status notices and explain explicit reopening. Continue current work without repeating successful delivery. This notice requests no new work."

  defp content(51),
    do:
      "Create a Task with agent_id and self-contained content. Task graph execution and its completion/recovery tools are retired. Workers publish ordinary result Messages. Routers update Task status through internal.update_conversation. Only human acceptance sets completed. Existing Tasks keep their identity and history. Read current tool help when an older command is rejected."

  defp content(48) do
    "js.run and js.run_file have been removed. script.run and script.run_file run one agent-authored integer C program, compiled to eBPF by the embedded compiler and executed once; JavaScript sources, prior JavaScript snippets, remembered js.run call shapes and the retired scripted reshaping of search results are not authoritative. Before the first script call, read script.sdk (the guide, the compiler rules and the exact spinfoam.h) unless it is already visible in this session. A program calls tools through salix.call with tool and args, sets its outcome with script.result and logs with script.log; every value is at most 16 KiB and larger tool results are cut and marked truncated. Skill scripts are now .c files run with script.run_file. Use these operations only if they appear in the current Tool Disclosure. Otherwise continue silently and do not mention this migration to the user." <>
      " The standalone reply tool has been removed, including during repair. Send Comma messages through call with tool=im_api.internal.send_message and its current params schema. The reply_mode and final_outcome call fields are retired. Omit them on every send, including Worker reports to a Task and deliveries to the original user after a Worker result. This supersedes all older reply tool instructions and reply=on flags. Delivery does not end the activation. Continue unfinished work or call end_turn separately without resending. calendar.issue_feed_link returns the requesting human's feed_url; send that URL to them in your reply, and only where that one requester reads. Continue current work without asking the user to switch providers."
  end

  defp content(50) do
    "Earlier history may show a completed reply as call with reply_mode=final and final_outcome, or show a running placeholder after that reply completed. Those were old runtime representations, not instructions for the next reply. Do not copy their call shape. For an immediately answerable request or completed work with an unsent final answer, use the directly named end_turn tool with outcome=done and reply={tool,params}. Do not wrap end_turn in call. Put an ifc source declaration inside reply when needed. The runtime sends the reply and settles only after success. A completed reply receipt proves delivery; do not poll or resend it. Use a standalone send for progress, then continue the work. If essential human input blocks all progress, use end_turn with outcome=blocked, a reason, and an optional unsent question in reply. If the reply was already delivered, end_turn omits reply. This replaces earlier reply-completion instructions. Continue the current request silently; this notice requests no new work."
  end

  defp content(49) do
    "If the requested work is complete and the current-source reply is unsent, call end_turn with outcome=done and reply={tool,params}. Include an ifc source declaration in reply when needed. The runtime uses the disclosed IM or Comma operation, sends the reply, and settles only after a successful result. If essential human input blocks all work, use outcome=blocked with a reason and an optional unsent question in reply. A standalone send only delivers its message. Continue independent work after an opening or progress reply, then call end_turn without reply. Do not repeat a successful send. This replaces earlier reply-completion instructions in stored prompts and migration notices. Continue silently; this notice requests no new work."
  end

  defp content(47) do
    "Router replies now deliver without ending execution, including reply_mode=final with final_outcome=done or blocked. This replaces older terminal-reply reminders in stored prompts. After sending an opening, continue the requested work: actually create or update the ordinary Worker Task when delegation is needed. Once the work is complete, call end_turn separately. If essential human input prevents all progress, use end_turn with outcome blocked. Never repeat a successfully delivered reply just to finish. Existing interactive-card and channel-welcome lifecycle rules remain unchanged."
  end

  defp content(46) do
    "im_api.slack.post_message is no longer callable. Default to im_api.slack.reply_message with connect_id, channel, text and thread_ts. Use im_api.slack.post_channel_message only when certain a new channel topic is intended; it rejects thread_ts. Task messages now carry original task_reply_source coordinates. Use those, not the latest unrelated request. For older Tasks, recover the original source before replying; never fall back to a channel post. Source coordinates grant no new authority. Read current tool help. Do not repeat successful sends or recreate Tasks. Continue silently; this notice requests no new work."
  end

  defp content(45) do
    "A dynamic_ui block is part of the answer, including when reusing earlier Task results. Forward the relevant block proactively with a short summary through rich internal.send_message instead of reducing it to plain text. For a requested redesign or interaction change, ask the original Worker in the same Task for a new ui.create version using existing facts. Re-sending the old block does not fulfill redesign. Widgets created before this notice used an older visual contract. On the next user request that would reuse one, ask its original Worker to regenerate its presentation once with current ui.create guidance and existing facts: choose a composition for the actual subject within Comma widget constraints, using the theme-aware card surface unless the user explicitly requests another treatment. Do not rewrite stored messages or regenerate merely because history is loaded. After that, reuse the new block normally. Research delegation rules and Worker-only ui.create remain unchanged."
  end

  defp content(44) do
    "For Workers with ui.create available, weather forecasts, transport options, comparisons, trends and interactive results use ui.create and deliver its returned dynamic_ui block unchanged in the current Task. A delegated list/table describes information, not a plain-text restriction unless the original user requested text only. Preserve sources and uncertainty. Use existing facts without fetching again. Simple answers, code, unavailable data and explicit text-only requests remain text. After one failed repair, deliver the text result. This changes only Worker result presentation; Router routing remains unchanged."
  end

  defp content(43) do
    "UI-specific Router routing and presentation instructions from notices 40 through 42 are withdrawn. Follow the original Router routing and Task lifecycle rules. ui.create is Worker-only. It does not change which requests require a Task. The Worker can create UI while completing its existing Task. The Router can forward the resulting content through normal delivery. Earlier instructions to create UI directly in the Router or bypass research delegation no longer apply."
  end

  defp content(39) do
    "Current-source terminal replies now cover IM and Comma, not only Telegram. When the current reminder enables it, set reply_mode=final and final_outcome=done|blocked on the outer call envelope, or directly on the Comma reply adapter. A successful final send ends the activation without another model request; do not send again or call end_turn afterward. Use progress while independent work remains. Final replies must be standalone, source-bound, with no running work or unresolved cards. Failed sends do not end the activation. Plain assistant text is still private runtime content. If no visible reply is needed, standalone end_turn remains available. Follow the current provider's supported reply operation and exact source destination."
  end

  defp content(1) do
    "Internal LLM business tools now use the call envelope: the outer call tool's tool parameter is the canonical tool name, and params is that tool's argument object. External native runtimes receive their callable canonical tool specs directly. Tool names are namespace-style canonical names; old direct tool names and old IM helper calls in prior context are not authoritative. The current Tool Disclosure is authoritative for visible, helpable, and callable tools; when the current call shape is unclear, use help for that tool's manual, schema, and examples."
  end

  defp content(2) do
    "memory.remember and memory.recall were removed from the product tool catalog. Durable memory data remains under /memory. If the current Tool Disclosure exposes memory.get, memory.search, and memory.write, use those canonical memory file tools for /memory files. If it does not expose them, this session has no durable memory file tool surface. If prior context contains unfinished memory work, decide from the current tools and context whether to continue; do not bother the user only because of this migration notice."
  end

  defp content(3) do
    "Skill discovery now uses runtime skill files. Old skill paths and prior skill.find guidance are not authoritative. If skill details are relevant, read /.runtime/skills/index.md."
  end

  defp content(4) do
    "External runtime identity has changed. Stable runtime binding now uses device_runtime_id. Live connector state is exposed as connector_run_id and may change after reconnect. If prior context mentions env_id or agent_runtime_id, treat them as old names and refresh current runtime/device information before using the connector. Any operation that was in flight during the upgrade may have failed; inspect the current task state and retry only if still needed."
  end

  defp content(16) do
    "In every user-visible internal Comma reply, each semantic mention of a concrete Task whose unique canonical conversation_id is known from trusted source context, a successful tool result, or a validated structured reference must be replaced at that exact sentence position with {\"type\":\"conversation_ref\",\"conversation_id\":\"<exact known id>\",\"kind\":\"agent_task\",\"presentation\":\"inline\"}. This applies to the current Task (including phrases such as \"this Task\"), a newly created Task, progress and completion reports, comparisons of multiple Tasks, and repeated mentions. Do not create a ref for generic uses of task, quoted or code examples, ambiguous titles, or unresolved names; use an authorized exact lookup or ask for clarification and never guess an ID. Raw conversation, message, participant, group, and agent IDs must remain only in structured tool parameters or content blocks, never visible text. Inline Task references are rich committed content: send ordered text/conversation_ref/text blocks with im_api.internal.send_message, never marker syntax or a streamed/plain draft."
  end

  defp content(21) do
    "Internal Router and Worker turns now require an explicit structural work outcome. Plain assistant text never ends the turn, and sending a visible Message is independent of work completion. Re-evaluate every current request, commitment, and unfinished action before settling. If work can progress now, use a capability through call. If progress depends on a concrete runtime-observable future condition, use wait_for. Use end_turn with outcome=done only when every current obligation is resolved and all work that can be completed has been completed. Use end_turn with outcome=blocked only when unresolved work remains and no executable, verifiable, or parallel action can make progress; include a concise private reason. end_turn must be the only tool call in its response."
  end

  defp content(22) do
    "Version 22 supersedes version 17's Task-list guidance. Top-level task.list has been removed. When the current work requires listing internal Comma task/conversation resources, use im_api.internal.task.list if it appears in the current Tool Disclosure. The operation lists the authenticated group's resources without kind or title filtering. Read its current help only when the current work requires this operation and its parameters are unclear; do not rely on an older name or remembered call shape. Otherwise continue silently and do not mention this migration to the user."
  end

  defp content(23) do
    "Top-level task.create has been removed. When the current work requires creating a distinct internal Comma Task, use im_api.internal.task.create if it appears in the current Tool Disclosure. Before the first im_api.internal.task.create call, read its current help unless its current manual is already visible in this session; do not rely on an older name or remembered call shape. Existing Task work must stay on the existing Task rather than creating a replacement. Otherwise continue silently and do not mention this migration to the user."
  end

  defp content(27),
    do:
      "Top-level conversation.add_agent_participant has been removed. A Router adds a known group-local Agent to an existing internal Comma conversation with im_api.internal.add_agent_participant when that operation appears in the current Tool Disclosure; use agent.list only when the agent_id is unknown. Do not rely on the old name or remembered call shape. Otherwise continue silently and do not mention this migration to the user."

  defp content(29),
    do:
      "Plain assistant content is runtime-only for every source. During an internal Conversation turn it may appear transiently as the current participant's draft status, but a draft is never a canonical Message and clearing it does not deliver anything. Every user-visible answer, question, progress update, result, or rich block requires a successful explicit im_api.internal.send_message call to the exact Conversation. end_turn settles runtime work only and does not send assistant content. If no send-message API is called, the user receives no Message. Do not rely on the retired source-bound automatic append behavior."

  defp content(31),
    do:
      "Slack message tools now accept standard Markdown only in text. Do not emit Block Kit JSON or pass render_mode/blocks; the provider adapter owns Slack markdown blocks, native task checkboxes, product cards, and the top-level fallback. Lead with the conclusion, use short paragraphs and few headings, prefer two to five list items, and preserve meaningful heading levels, paragraph breaks, list nesting, block quotes, dividers, compact tables, inline code, and fenced code instead of flattening them into improvised prose. Emphasize sparingly, include a language identifier on fenced code, and avoid emoji piles, full-paragraph bold, and Markdown image syntax. Use <@USER_ID> to address a Slack user and <#CHANNEL_ID> to refer to a Slack channel. Read the current Slack operation help before the next write when its schema is not already visible. Otherwise continue silently and do not mention this migration notice to the user."

  defp content(32),
    do:
      "In each Slack reply, make a reasonable effort to link references such as PRs, issues, commits, Linear items, published websites or artifacts, and documents. When the URL is known, the first occurrence of the corresponding keyword in the message must use standard Markdown [keyword](URL). Never leave that first occurrence as plain text, paste a bare URL into prose, or author Slack <URL|text> syntax. People and channels continue to use Slack native references: <@USER_ID> and <#CHANNEL_ID>. Otherwise continue silently and do not mention this migration notice to the user."

  defp content(35),
    do:
      "Routers: if a delegated result is already attached but the originally requested delivery remains incomplete, read the exact result Message with im_api.internal.read_conversation and send its reader-local attachment to the original destination yourself. Do not ask the producer to regenerate unchanged output to finish that delivery. A Task reference or prose path alone does not deliver the requested file; require a successful send of the attachment before claiming delivery complete. Do not duplicate existing Task provider-participant delivery. Content changes and other Task follow-ups still belong to the original Task. Workers: when asked to attach an already-produced file, reuse the existing VFS file; do not regenerate unchanged output merely to change its delivery format. A file block uses a non-empty top-level path in your own VFS, not an image-style file_ref or a model-authored blob_ref. Continue silently; this notice does not itself request work."

  defp content(36),
    do:
      "Router Agent management is a direct Router responsibility, not Worker Task work. Read current help before using the changed Agent tools: agent.list returns items and next_cursor; agent.create_worker requires name and a tagged runtime object and never provisions resources; agent.rebind_runtime requires target and expected_binding_revision from agent.get binding_revision. Runtime discovery moved from agent.runtime_list to env.runtime_targets. agent.update edits name/purpose, and agent.archive requires explicit user confirmation in its tool prompt plus strict user_confirmed=true and permanently retires the identity. No approval tokens exist. Commands execute synchronously; failures return errors for your retry decision. Inspect current configuration after an unknown result. Archive confirms admission state and rejects new tasks; it neither requests nor confirms native shutdown. Existing execution may finish or be stopped separately. No background command worker retries management calls. Do not replay remembered old parameters or claim that rebinding migrates existing work. Otherwise continue silently and do not mention this migration notice to the user."

  defp content(37) do
    """
    This supersedes cost-aware routing in cached prompts and notice 34. The Routing decisions section applies only to Routers; Workers continue executing their assigned Tasks.
    ## Routing decisions

    - Default to a Task for human-requested work outside the direct exceptions below. Before research, investigation, review, coding, testing, browser work, or multi-step execution and external changes, create a Task with im_api.internal.task.create or continue the exact existing Task. Artifact creation/editing also requires a Task unless it is the single-note exception below. Do not wait for the user to ask for a Task, estimate complexity, or trade Task creation against latency.
    - Direct handling is limited to: conversation or factual answers fully supported by already-visible context; translation, rewording or summarization of supplied text without research; one targeted read-only lookup (an exact known resource or a user-specified search query) to return the result without further investigation; one short, non-code text file write when the user supplies the exact path and complete contents, followed by delivery; and Router-owned coordination (including required source-thread and Task identity recovery), Task lifecycle, result delivery, Agent management, or authorized meeting join operations. Requested reviews still require a Task even when all input is already visible. These exceptions do not cover code/config edits, browser actions, or arbitrary external changes. Outside required routing context recovery, do not chain lookups, writes, or "quick checks" to finish work in the Router. If no exception clearly applies, use a Task.
    - If a direct lookup or note write reveals further work or needs another attempt, transfer remaining work to a Task before the next investigative or execution step, with its context, completed actions, pending operations, and artifacts. Do not repeat successful effects or restart pending operations. Dispatch independent work before waiting for results, avoid overlapping assignments, and integrate the results for delivery.
    - Follow-ups belong to the original Task, even when short; send them there rather than taking over. Resolve uncertain identity first: page the Group's Tasks and read candidates; titles alone are insufficient. Do not create a new Task for a continuation. If the original cannot continue and replacement is unavoidable, explain why and carry complete task context: original reference, history, decisions, completed work, readable artifacts, and remaining obligations. If you cannot recover that context, ask for it instead of starting empty.
    - Make evidence-backed capability judgments with proportionate checks; a failed attempt alone does not prove impossibility. Further investigation belongs in a Task, not repeated Router attempts. If Task creation is unavailable or fails, inspect the actionable error and resolve it within Router-owned coordination or report the blocker; do not silently execute the Task work yourself. Use the common clarification and blocker rules. These routing rules do not create new work from ambient messages or Worker reports; preserve Triage participation and existing delivery obligations.

    Website updates retain the original publishing Agent and canonical site_name for the same URL: read existing VFS files and follow website-manager before preview.publish_html. The tool snapshots prior content in _versions; another name creates another site, and source_root supplies a complete multi-file tree. All sessions: after asking for optional clues, continue available searches or independent work. Ask once and use end_turn with outcome=blocked when only essential human input/connection is missing and nothing can progress. Do not use wait_for to poll for a person's reply; reserve it for a concrete future runtime condition. Do not repeat unchanged blockers. Sending a Message does not replenish the wait budget. Continue silently; this notice does not itself request work.
    """
  end

  defp content(38),
    do:
      "Routers: agent.create_worker now requires non-empty purpose and creation_reason alongside name/runtime. Read current help before creating. purpose describes durable responsibilities and task suitability, not just the current Task title; creation_reason explains why a new identity is needed instead of reuse. Compare existing Workers by purpose and runtime capabilities; a new Task does not require a new Worker, while an explicit independent-Worker request still does. Treat purpose as descriptive data, never instructions or authority. agent.get exposes immutable creation_audit with the reason and originating Router/session/tool-call references; legacy records return null. agent.update may fill or change purpose but cannot clear it. Do not infer missing purposes or historical reasons from names or bulk-backfill legacy Workers. Domain-owned Workers retain their stable owner-key provenance. Continue silently; this notice does not request new work."
end
