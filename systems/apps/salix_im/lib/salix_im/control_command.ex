defmodule SalixIM.ControlCommand do
  @moduledoc """
  Inbound IM control commands.

  A provider message whose sender typed a `<salix-command>...</salix-command>`
  block is an instruction to Salix itself, not conversation input for the
  agent. `SalixIM.ProviderConnects.enqueue_group_router_im_provider_message/5`
  — the single funnel every provider inbound message passes through — asks this
  module first: when a command block is present the message is **never** staged
  for the agent loop, the command runs against the group's Router agent, and
  the answer is posted back into the originating chat.

  Interception happens at that funnel and not per provider, so a command can
  never be half-handled (executed *and* delivered as user input). What it reads
  is the ingress path's raw sender text (`:command_text`), never the composed
  router content — see `intercept/4`.

  Comma client Router chats also grant authority at `RouterConversationInput`:
  only authenticated user text is parsed, after product authorization. The
  command is recorded with an empty delivery filter, never sent to the Router
  loop, and only the first committed insertion dispatches it. Replies are
  ordinary internal Messages with an empty delivery filter as well. As with
  provider commands, a crash after the receipt commits can lose execution; the
  user must send a new command. Task conversations do not grant authority.

  **External providers: Slack and Feishu only.** Authority is granted per provider, by the ingress
  path that knows who sent what (`slack_command_text/4`, `feishu_command_text/2`
  in `SalixIM.ProviderHTTP`); a provider that grants none can never produce a
  command here. Telegram and WeChat grant none: neither filters inbound for bot
  relevance, so any group member would run commands without addressing the bot,
  and Telegram's `edited_message` mints a fresh `update_id` — editing one old
  message into a command would re-run it without limit. Adding either means
  building that gate first, not passing `:command_text`.

  ## Commands

    * `status` — the Router session's model and context usage.
    * `clear` — start a fresh Router session, preserving the previous transcript.
    * `compact` — trigger a compaction of the Router session context.
    * `emergency-compact` — mask historical non-model messages over 1,000 bytes.
    * `ls <path>` — list a path in the Router agent's VFS (`ls /`).
    * `cat <path>` — show a VFS file, truncated to a chat-safe size.
    * `help` — the supported commands.

  Everything else inside the block is refused with a usage reply rather than
  being passed through to the agent: a message that meant to be a command must
  not silently become a prompt.

  `ls` and `cat` are disabled unless the group explicitly enables
  `control_command_vfs_enabled` in the Salix dashboard. Missing settings and
  failed group reads deny access at execution time.

  `ls` and `cat` read the workspace through `SalixIM.Ports.AgentWorkspace` and
  never write to it. `cat` is the one command that puts bytes Salix did not
  compose into a chat, which is why it reads only the head of a file, refuses
  anything that is not UTF-8 text, and — on Slack — is escaped at the reply
  builder; see `slack_reply/2`.

  Every command is scoped to the group's own Router — `status`, `compact`, and
  `emergency-compact` to its session; `clear` switches its canonical session;
  `ls` and `cat` to its workspace. Slack
  worker-thread messages take a different ingress path
  (`SlackConversationIngress`) that does not cross this funnel, so a command in
  a worker thread is not recognized there.

  `clear` reuses the dashboard's owner-routed canonical session switch, including
  its expected-session fence. It affects every chat using this Router, stops the
  retired session runtime, and preserves its transcript. A lost reply must not
  be interpreted as a failed clear: check `status` before sending another one.

  ## Authority

  A command carries exactly the authority the sender already has by talking to
  the bot in that chat. Every one is scoped to the group's own Router agent and
  its Router session, resolved from the connect's `group_id` — never from
  anything in the message. `status` reports only what that chat's own agent is
  configured with. `compact` summarizes context without deleting transcript
  (see `SalixAgent.Compaction`); `emergency-compact` installs a read-side mask
  for that session's historical non-model messages over 1,000 bytes while
  preserving immutable event/archive bytes. `ls` and `cat` read the same
  workspace the chat's own agent already reads out on request; the path is the
  only thing the sender chooses, and it selects a key in THAT agent's manifest,
  so no path can reach another agent's files.

  The granting ingress paths require a HUMAN who ADDRESSED the bot: Slack needs
  an explicit mention on the message itself and refuses app-authored events;
  Feishu needs `sender_type == "user"` on top of its existing relevance gate.
  Thread participation alone is not enough — it admits replies that never
  addressed the bot, and on Slack it admits other apps' relayed content, whose
  text is written by whoever wrote the PR title or alert being relayed.

  ## Execution

  Commands run off the provider callback process (`Task.Supervisor`), because
  compaction can take minutes while Slack and Feishu expect a webhook ACK in
  seconds. The command's own reply is the user-visible completion signal. When
  the command pool is full the sender is told so from a separate reply pool —
  still never on the callback process, since a provider POST there is unbounded
  and would blow the ACK budget exactly when the node is least able to afford
  it.
  `config :salix_im, :control_command_execution, :sync` runs them inline for
  tests.

  A command is **at most once, best effort** — deliberately, and unlike agent
  delivery. The provider event receipt recorded upstream makes a webhook retry
  a duplicate; Slack's Triage path additionally re-drives already-receipted
  events on purpose, which delivery absorbs (it keys on `source_message_id`)
  but a command would not, so a re-driven command is recognised and dropped as
  already-handled — see `intercept/4`. It is still recognised, not un-granted:
  withholding the grant would drop it through the funnel as ordinary input, so
  one message would be both executed and delivered. Nothing durable is staged,
  so a node lost mid-run drops it. That is the right trade for an interactive
  control surface: neither command carries an obligation worth
  reviving later — a stale `status` would be wrong by the time it arrived, and a
  compaction the runtime still needs is re-triggered by the auto threshold
  (`SalixAgent.Compaction`) without anyone asking. An unanswered command is
  visible to the sender, who re-sends. The same applies to
  `emergency-compact`: its range predicate is durable and repeated commands
  coalesce, but a command lost before commit must be sent again.
  """

  require Logger

  alias SalixIM.GroupDirectory
  alias SalixIM.Ports.AgentControl
  alias SalixIM.Ports.AgentWorkspace
  alias SalixIM.ProviderConnects

  @task_supervisor SalixIM.ControlCommandTaskSupervisor
  @reply_supervisor SalixIM.ControlCommandReplySupervisor

  # The body excludes `<` and is length-bounded, which buys two things beyond
  # matching a command name.
  #
  # LINEAR TIME: a lazy `.*?` body restarts a scan-to-end-of-input at every
  # opener, so a message of repeated `<salix-command>` openers costs quadratic
  # CPU — ~0.9s at Slack's 40kB text cap, 13s at 150kB — on the webhook process
  # BEFORE the provider's ACK. `[^<]` cannot cross the next tag, so a failed
  # match dies within the bound.
  #
  # SAFE ECHO: an unknown body is quoted back into the chat. Every Slack ping
  # primitive (`<!channel>`, `<!here>`, `<@U…>`) and link is `<`-delimited, so
  # excluding `<` means the echo cannot make the bot mass-notify a channel.
  #
  # The bound holds a command name PLUS a VFS path, which is why it is not 64:
  # a real artifact path spends most of that on directories alone, and a body
  # over the bound does not match at all — it would fall through as a prompt,
  # which is the one outcome interception exists to prevent. It stays small
  # enough that the echo is a chat line, not a wall.
  @body_max_bytes 256
  @block_regex ~r/<salix-command>(?<body>[^<]{0,#{@body_max_bytes}})<\/salix-command>/

  # Bounds on what a command may put into a chat message. `cat` is the only one
  # that echoes bytes Salix did not compose, so it is the only one that needs
  # them: Slack caps `text` at 40kB and both providers render a long message as
  # an unreadable slab well before that.
  @cat_max_bytes 8_000
  @ls_max_entries 100

  # No literal tags: Slack mrkdwn eats `<...>` as an entity and Feishu
  # XML-escapes it, so spelling the syntax out renders as garbage in both.
  @help """
  Supported commands, each sent inside a salix-command block:
  • status — model and context usage
  • clear — start a fresh Router session (shared by all chats for this Router)
  • compact — compact the session context
  • emergency-compact — replace historical non-model messages over 1,000 bytes
  • ls PATH — list a workspace path, e.g. ls / or ls /artifacts
  • cat PATH — show a workspace file
  ls and cat require VFS control commands to be enabled in the Salix dashboard for this group.
  • help — this list
  """

  @type command ::
          :status
          | :clear
          | :compact
          | :emergency_compact
          | :help
          | {:ls, String.t()}
          | {:cat, String.t()}
  @type parsed ::
          {:ok, command()}
          | {:error, {:unknown_command, String.t()}}
          | {:error, {:missing_path, String.t()}}

  @doc """
  Find a `<salix-command>` block in the raw text a sender typed.

  Returns `:none` when the text carries no block — the caller then treats
  the message as ordinary agent input. A block whose body is not a supported
  command still intercepts (`{:error, {:unknown_command, name}}`): the sender
  clearly meant a command, so it gets an answer instead of leaking into the
  prompt. So does a command that needs a path and was sent without one
  (`{:error, {:missing_path, name}}`) — a bare `cat` is a mistyped command, not
  a question for the agent.

  The first whitespace-delimited word is the command NAME and is matched
  case-insensitively; everything after it is the argument, kept verbatim. VFS
  paths are case-sensitive and may contain spaces, so downcasing or splitting
  the remainder would make perfectly ordinary paths unaddressable.

  Only the FIRST block is honored. A message carrying several is one command
  with trailing prose, not a batch: executing the rest would let one message
  fan out into repeated runtime operations.

  A body containing `<`, or longer than #{@body_max_bytes} bytes, does not
  match at all and is ordinary agent input — no command name is that shape.
  """
  @spec parse(term()) :: parsed() | :none
  def parse(content) when is_binary(content) do
    case Regex.named_captures(@block_regex, content) do
      %{"body" => body} -> parse_body(body)
      nil -> :none
    end
  end

  def parse(_content), do: :none

  defp parse_body(body) do
    {name, argument} = split_body(body)

    case name do
      "status" -> {:ok, :status}
      "clear" -> {:ok, :clear}
      "compact" -> {:ok, :compact}
      "emergency-compact" -> {:ok, :emergency_compact}
      "help" -> {:ok, :help}
      # A bare `ls` means the root, the way it means the working directory in a
      # shell. A bare `cat` has no such default — there is no file it could
      # mean — so it is answered with usage rather than guessing one.
      "ls" -> {:ok, {:ls, absolute_path(argument, "/")}}
      "cat" when argument == "" -> {:error, {:missing_path, "cat"}}
      "cat" -> {:ok, {:cat, absolute_path(argument, "/")}}
      _ -> {:error, {:unknown_command, name}}
    end
  end

  defp split_body(body) do
    case body |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [name, argument] -> {String.downcase(name), String.trim(argument)}
      [name] -> {String.downcase(name), ""}
    end
  end

  # Chat clients invite `code` formatting and phone keyboards add smart quotes,
  # so a wrapping pair is stripped before the path is read: otherwise the marks
  # become part of the manifest key and every quoted path is "not found".
  defp absolute_path("", default), do: default

  defp absolute_path(argument, default) do
    argument = argument |> unwrap("`") |> unwrap("\"") |> unwrap("'")

    cond do
      argument == "" -> default
      String.starts_with?(argument, "/") -> argument
      true -> "/" <> argument
    end
  end

  defp unwrap(value, mark) do
    if byte_size(value) > 2 * byte_size(mark) and String.starts_with?(value, mark) and
         String.ends_with?(value, mark) do
      value
      |> binary_part(byte_size(mark), byte_size(value) - 2 * byte_size(mark))
      |> String.trim()
    else
      value
    end
  end

  @doc """
  Intercept a provider inbound message whose sender text carries a command
  block.

  `text` must be the RAW text the sender typed, never the Salix-composed
  router content: that content interpolates provider-supplied names, and a
  command block reaching this function from one of those would let whoever
  chose the name run commands. An ingress path with no sender text (a Slack
  `channel_created` fact, a meeting handoff) passes `nil` and is never a
  command.

  `opts[:replayed?]` marks a delivery the provider ingress is re-driving over
  an already-recorded receipt. A command recognised on a replay is claimed but
  NOT run — the first delivery already ran it and answered. It must still be
  claimed: letting it fall through would stage the raw `<salix-command>` text
  as a prompt, so one message would be both executed and delivered, which is
  exactly what interception exists to prevent.

  `:none` means the message is not a command and the caller must continue its
  normal delivery path. `{:ok, :command}` means this module has taken
  ownership of the message: it is not staged for the agent loop, and the reply
  is this module's responsibility.

  The Router is resolved BEFORE ownership is claimed. A group with no usable
  Router cannot answer a command, so it must not swallow one either: the
  `{:error, _}` passes straight back to the caller, which reports it the same
  way it would for an undeliverable message, instead of returning 200 for a
  message that was neither executed nor delivered.
  """
  @spec intercept(String.t(), term(), map(), keyword()) ::
          {:ok, :command} | :none | {:error, term()}
  def intercept(group_id, text, metadata, opts \\ [])

  def intercept(group_id, text, metadata, opts)
      when is_binary(group_id) and is_map(metadata) and is_list(opts) do
    case parse(text) do
      :none ->
        :none

      parsed ->
        if Keyword.get(opts, :replayed?, false) do
          log(group_id, parsed, metadata, :replayed)
          {:ok, :command}
        else
          claim(group_id, parsed, metadata)
        end
    end
  end

  def intercept(_group_id, _content, _metadata, _opts), do: :none

  defp claim(group_id, parsed, metadata) do
    with {:ok, agent_id, session_id} <- resolve_router(group_id),
         # Ownership is claimed only once the command is actually RUNNING or
         # queued to run. A dropped dispatch that still answered
         # `{:ok, :command}` would 200 the webhook over an already-recorded
         # receipt, leaving the message permanently neither executed nor
         # delivered; the error instead deletes the receipt, so the provider's
         # own retry gets a real attempt.
         :ok <-
           tag_agent(
             dispatch(fn -> run(group_id, parsed, metadata, agent_id, session_id) end),
             agent_id
           ) do
      {:ok, :command}
    else
      # Saturation is not an ingress fault and a retry cannot fix it: the tasks
      # holding the pool park for as long as a compaction takes, which outlasts
      # every provider retry. Erroring would put human message volume straight
      # onto the ingress error alert (im-ingress-alerting.md declines
      # caller-amplifiable input) and still lose the message. So the sender is
      # told, from the REPLY pool — never inline, see `respond_busy/2`.
      {:error, {:control_command_unavailable, :max_children}, agent_id} ->
        log(group_id, parsed, metadata, :saturated)
        respond_busy(agent_id, metadata)
        {:ok, :command}

      {:error, reason} = error ->
        log(group_id, parsed, metadata, {:refused, reason})
        error

      {:error, reason, _agent_id} ->
        log(group_id, parsed, metadata, {:refused, reason})
        {:error, reason}
    end
  end

  # `systems/AGENTS.md` names saturation as a case a metric must answer, and
  # this change adds a node-wide one. It rides the EXISTING finite
  # `salix.operations.total` family (component/operation/surface/outcome) —
  # never a second counter, and never a label carrying a group, connect or
  # sender. `over_budget` is the refusal; `ok` is a command that got a slot.
  defp emit_dispatch(outcome, surface) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: 0},
      %{
        component: "salix_im",
        operation: "control_command",
        surface: surface,
        outcome: outcome
      }
    )

    :ok
  end

  defp tag_agent({:error, reason}, agent_id), do: {:error, reason, agent_id}
  defp tag_agent(other, _agent_id), do: other

  # NOT inline. `intercept/4` runs on the provider callback process, and a
  # provider POST there is unbounded — Req's default receive timeout is 15s,
  # five times Slack's ACK budget. Holding a webhook worker that long is worst
  # exactly when the pool is already saturated: Slack times out at 3s, retries,
  # and the retry arrives as a receipt replay. The reply pool is separate from
  # the command pool because a reply is one bounded call that never parks,
  # while a `compact` task waits through its dependency budget and settlement
  # allowance. One pool would let the parked work starve the apology for it.
  defp respond_busy(agent_id, metadata) do
    text =
      "Salix is running too many commands right now and did not start this one. " <>
        "Please try again shortly."

    observability = SystemsObservability.Context.capture()

    reply = fn ->
      SystemsObservability.Context.run(observability, fn ->
        guarded(fn -> respond(agent_id, metadata, text) end)
      end)
    end

    if Process.whereis(@reply_supervisor) do
      case Task.Supervisor.start_child(@reply_supervisor, reply) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("salix busy reply not sent: #{inspect(reason)}")
      end
    else
      Logger.warning("salix busy reply not sent: no reply supervisor")
    end

    :ok
  catch
    :exit, reason ->
      Logger.warning("salix busy reply not sent: #{inspect(reason)}")
      :ok
  end

  @doc """
  Run one parsed command against an already-resolved Router session and post
  its reply. Synchronous.
  """
  @spec run(String.t(), parsed(), map(), String.t(), String.t()) :: :ok
  def run(group_id, parsed, metadata, agent_id, session_id)
      when is_binary(group_id) and is_map(metadata) and is_binary(agent_id) and
             is_binary(session_id) do
    text = execute_for_group(group_id, parsed, agent_id, session_id)
    log(group_id, parsed, metadata, :executed)
    respond(agent_id, metadata, text)
  end

  # ---- execution ----

  # Read the current group setting inside the execution task, not at enqueue time.
  defp execute_for_group(group_id, {:ok, {command, _path}} = parsed, agent_id, session_id)
       when command in [:ls, :cat] do
    case GroupDirectory.get_group(group_id) do
      {:ok, %{"control_command_vfs_enabled" => true}} ->
        execute(parsed, agent_id, session_id)

      _ ->
        "VFS control commands are disabled for this agent group. " <>
          "Enable VFS control commands in the Salix dashboard group overview to use ls or cat."
    end
  end

  defp execute_for_group(group_id, {:ok, :clear}, agent_id, session_id) do
    with {:ok, %{"tenant_id" => tenant_id}} <- GroupDirectory.get_group(group_id),
         {:ok, %{"router_session_id" => new_session_id}} <-
           AgentControl.switch_router_session(agent_id, tenant_id, session_id) do
      "Started a new Router session: #{new_session_id}. " <>
        "This applies to all chats using this Router; the previous transcript is preserved."
    else
      {:error, {:stale_router_session, _current_session_id}} ->
        "The Router session has already changed. This clear did not start another session."

      {:error, reason} ->
        "Router clear failed — #{failure(:clear, reason)}."
    end
  end

  defp execute_for_group(_group_id, parsed, agent_id, session_id),
    do: execute(parsed, agent_id, session_id)

  defp execute({:error, {:unknown_command, name}}, _agent_id, _session_id),
    do: String.trim("Unknown Salix command: #{display_name(name)}\n\n" <> @help)

  defp execute({:error, {:missing_path, name}}, _agent_id, _session_id),
    do: String.trim("Salix command #{name} needs a path, e.g. #{name} /artifacts\n\n" <> @help)

  defp execute({:ok, :help}, _agent_id, _session_id), do: String.trim(@help)

  defp execute({:ok, :status}, agent_id, session_id) do
    case AgentControl.session_status(agent_id, session_id) do
      {:ok, status} -> status_text(status)
      {:error, reason} -> "Salix status is unavailable right now — #{failure(:status, reason)}."
    end
  end

  defp execute({:ok, :compact}, agent_id, session_id) do
    case AgentControl.compact_session(agent_id, session_id) do
      {:ok, %{"status" => "compacted"}} ->
        "Compaction complete.\n" <> context_line(agent_id, session_id)

      {:ok, %{"status" => status} = result} ->
        "Compaction did not run (#{status}#{compact_reason(result)}).\n" <>
          context_line(agent_id, session_id)

      {:ok, _result} ->
        "Compaction finished.\n" <> context_line(agent_id, session_id)

      {:error, :compact_result_wait_timeout} ->
        "Compaction result is not available yet. The result wait timed out, " <>
          "but compaction may still complete. Use status to check the session."

      {:error, reason} ->
        "Compaction failed — #{failure(:compact, reason)}."
    end
  end

  defp execute({:ok, :emergency_compact}, agent_id, session_id) do
    case AgentControl.emergency_compact_session(agent_id, session_id) do
      {:ok,
       %{
         "status" => "emergency_compacted",
         "through_id" => through_id,
         "max_bytes" => max_bytes,
         "replacement" => replacement
       }} ->
        "Emergency compaction complete. Historical non-model messages over " <>
          "#{number(max_bytes)} bytes through message ##{number(through_id)} now read as " <>
          replacement <> "."

      {:ok, %{"status" => status}} ->
        "Emergency compaction finished with status #{status}."

      {:ok, _result} ->
        "Emergency compaction finished."

      {:error, reason} ->
        "Emergency compaction failed — #{failure(:emergency_compact, reason)}."
    end
  end

  defp execute({:ok, {:ls, path}}, agent_id, _session_id) do
    case AgentWorkspace.list(agent_id, path) do
      {:ok, entries} -> ls_text(path, entries)
      # `ls` on a file names the file, the way a shell does, instead of
      # pretending the path does not exist.
      {:file, entry} -> "#{path} (#{bytes(entry["size"])})"
      {:error, :not_found} -> "No such path: #{path}"
      {:error, reason} -> "Salix could not list #{path} — #{failure(:ls, reason)}."
    end
  end

  defp execute({:ok, {:cat, path}}, agent_id, _session_id) do
    # The manifest is consulted BEFORE the body is fetched, so a directory and
    # a missing path are told apart. Reading first cannot: a directory has no
    # manifest entry of its own, so it fails exactly like a typo, and the
    # sender is left guessing which of the two they did.
    case AgentWorkspace.list(agent_id, path) do
      {:file, _entry} -> cat_text(agent_id, path)
      {:ok, _entries} -> "#{path} is a directory — list it with: ls #{path}"
      {:error, :not_found} -> "No such file: #{path}"
      {:error, reason} -> "Salix could not read #{path} — #{failure(:cat, reason)}."
    end
  end

  defp cat_text(agent_id, path) do
    case AgentWorkspace.read_stream(agent_id, path) do
      {:ok, _stream, 0, _filename} ->
        "#{path} is empty (0 bytes)."

      {:ok, stream, size, _filename} ->
        case head_bytes(stream, @cat_max_bytes) do
          {:ok, head} -> cat_body(path, head, size)
          {:error, reason} -> "Salix could not read #{path} — #{failure(:cat, reason)}."
        end

      {:error, reason} ->
        "Salix could not read #{path} — #{failure(:cat, reason)}."
    end
  end

  # A workspace file has no size ceiling — an agent writes build output and
  # recordings here — so the body is never read whole. The blob stream is
  # RANGED (each chunk is its own ranged GET), so halting at the cap fetches only
  # the first bounded chunk(s), not the whole file. A storage chunk can be larger
  # than the displayed head; the 8 kB limit bounds chat text and retained heap,
  # while the storage layer independently bounds each network read.
  defp head_bytes(stream, max_bytes) do
    head =
      Enum.reduce_while(stream, <<>>, fn chunk, acc ->
        acc = acc <> chunk
        if byte_size(acc) >= max_bytes, do: {:halt, acc}, else: {:cont, acc}
      end)

    head = if byte_size(head) > max_bytes, do: binary_part(head, 0, max_bytes), else: head
    {:ok, head}
  rescue
    error ->
      {:error, {:unavailable, {:stream_read_failed, Exception.message(error)}}}
  catch
    kind, reason ->
      {:error, {:unavailable, {:stream_read_failed, {kind, reason}}}}
  end

  defp cat_body(path, head, size) do
    truncated_at_cap? = byte_size(head) == @cat_max_bytes and byte_size(head) < size

    case text_head(head, truncated_at_cap?) do
      :not_text ->
        "#{path} (#{bytes(size)}) is not UTF-8 text, so it cannot be shown in chat."

      {:ok, text} ->
        header =
          if byte_size(head) < size,
            do: "#{path} (#{bytes(size)}, showing the first #{bytes(byte_size(head))})",
            else: "#{path} (#{bytes(size)})"

        header <> "\n" <> text
    end
  end

  # The cut at the byte cap can land mid-codepoint. Erlang's Unicode decoder
  # distinguishes that incomplete suffix from malformed bytes, so only an
  # actually truncated head may keep its valid prefix. A complete file with the
  # same suffix is invalid and is refused. A NUL is rejected on top of validity
  # — it is legal UTF-8 and a reliable sign the file is not text.
  defp text_head(head, truncated_at_cap?) do
    case :unicode.characters_to_binary(head, :utf8, :utf8) do
      text when is_binary(text) ->
        text_result(text)

      {:incomplete, text, rest}
      when truncated_at_cap? and is_binary(text) and is_binary(rest) and byte_size(rest) <= 3 ->
        text_result(text)

      {:incomplete, _text, _rest} ->
        :not_text

      {:error, _text, _rest} ->
        :not_text
    end
  end

  defp text_result(text), do: if(String.contains?(text, <<0>>), do: :not_text, else: {:ok, text})

  defp ls_text(path, []), do: "#{path} is empty."

  defp ls_text(path, entries) do
    shown = Enum.take(entries, @ls_max_entries)
    hidden = length(entries) - length(shown)
    header = "#{path} (#{number(length(entries))} #{plural(length(entries), "entry", "entries")})"
    lines = Enum.map(shown, &("• " <> ls_entry(path, &1)))

    # A truncated listing that did not say so would read as the whole
    # directory, which is worse than a long message.
    more = if hidden > 0, do: ["… and #{number(hidden)} more"], else: []

    Enum.join([header] ++ lines ++ more, "\n")
  end

  defp ls_entry(path, entry) do
    prefix = dir_prefix(path)
    full = trim(entry["path"])
    name = String.replace_prefix(full, prefix, "")
    name = if name == "", do: full, else: name

    # Directory entries already carry a trailing `/` from the workspace, which
    # is the only thing distinguishing them in a flat list.
    if entry["kind"] == "dir", do: name, else: "#{name} (#{bytes(entry["size"])})"
  end

  defp dir_prefix("/"), do: "/"

  defp dir_prefix(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  # The reply is chat-facing, so it carries a bounded phrase; the raw reason is
  # logged here because nothing else logs it — `run/5` only records that the
  # command executed, so without this line the detail would exist nowhere.
  defp failure(kind, reason) do
    Logger.warning("salix control command #{kind} failed: #{inspect(reason)}")
    describe(reason)
  end

  defp compact_reason(%{"reason" => reason}) when is_binary(reason) and reason != "",
    do: ": " <> reason

  defp compact_reason(_result), do: ""

  # A best-effort trailer: the compaction itself already succeeded, so a status
  # read that fails afterwards must not turn the reply into a failure report.
  # It still logs — this is the one failure that would otherwise vanish.
  defp context_line(agent_id, session_id) do
    case AgentControl.session_status(agent_id, session_id) do
      {:ok, status} ->
        "Context: " <> context_usage(status)

      {:error, reason} ->
        Logger.warning("salix control command context trailer failed: #{inspect(reason)}")
        "Context usage is unavailable right now."
    end
  end

  defp status_text(status) do
    """
    Salix status
    • Model: #{model_label(status)}
    • Context: #{context_usage(status)}
    • Messages: #{messages_label(status)}
    • Session: #{session_label(status)}
    """
    |> String.trim()
  end

  defp session_label(status) do
    id = blank_default(status["session_id"], "unknown")

    state =
      case trim(status["activity_status"]) do
        "" -> trim(status["status"])
        activity -> activity
      end

    if state == "", do: id, else: id <> " (" <> state <> ")"
  end

  defp model_label(status) do
    model = blank_default(status["model"], "unknown")
    provider = trim(status["provider"])

    if provider == "", do: model, else: model <> " (" <> provider <> ")"
  end

  defp context_usage(status) do
    used = status["estimated_context_tokens"]
    window = status["context_tokens"]

    cond do
      is_integer(used) and is_integer(window) and window > 0 ->
        "#{number(used)} / #{number(window)} tokens (#{percent(used, window)}%)"

      is_integer(used) ->
        "#{number(used)} tokens"

      true ->
        "unknown"
    end
  end

  defp messages_label(status) do
    count = status["message_count"]
    compacted = status["compacted_through"]

    base = if is_integer(count), do: number(count), else: "unknown"

    if is_integer(compacted) and compacted > 0,
      do: base <> " (compacted through ##{number(compacted)})",
      else: base
  end

  # ---- reply ----

  @doc false
  def respond(agent_id, metadata, text) do
    case reply_call(metadata, text) do
      {:ok, provider, api, params} ->
        args = %{"connect_id" => trim(metadata["connect_id"]), "params" => params}

        case SalixIM.Provider.call_api(agent_id, provider, api, args) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "salix control command reply failed provider=#{provider} reason=#{inspect(reason)}"
            )

            :ok
        end

      :unsupported ->
        Logger.warning(
          "salix control command reply target unresolved provider=#{trim(metadata["provider"])}"
        )

        :ok
    end
  end

  # Only ingress surfaces that GRANT command authority get a reply builder. A
  # builder for one that grants none is unreachable, and leaving it here reads
  # as support — which is the invitation to "just pass `command_text`" that the
  # missing relevance gate makes unsafe.
  defp reply_call(metadata, text) do
    case trim(metadata["provider"]) do
      "slack" -> slack_reply(metadata, text)
      "feishu" -> feishu_reply(metadata, text)
      "internal" -> internal_reply(metadata, text)
      _ -> :unsupported
    end
  end

  defp internal_reply(metadata, text) do
    {:ok, "internal", "internal.send_message",
     %{
       "conversation_id" => metadata["conversation_id"],
       "request_id" => "salix-command:" <> metadata["source_message_id"],
       "content" => [%{"type" => "text", "text" => text}],
       "delivery_filter" => %{"participant_ids" => []}
     }}
  end

  defp slack_reply(metadata, text) do
    channel = trim(metadata["channel_id"])

    if channel == "" do
      :unsupported
    else
      params =
        %{"channel" => channel, "text" => slack_escape(text)}
        |> put_present("thread_ts", metadata["thread_ts"])

      {:ok, "slack", "slack.post_message", params}
    end
  end

  # `cat` puts file bytes Salix did not compose into a Slack message, and every
  # Slack ping primitive (`<!channel>`, `<!here>`, `<@U…>`) is `<`-delimited —
  # so a file containing one would make the bot mass-notify the channel. Slack
  # escapes exactly these three entities and renders them back, so escaping the
  # WHOLE reply here costs nothing on the composed commands and leaves no
  # second path for a future one to forget. Feishu needs no counterpart: its
  # provider already XML-escapes outbound text before splicing `<at>` tags in.
  #
  # `&` FIRST: escaping it after `<` would turn `&lt;` back into `&amp;lt;`.
  defp slack_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Replying to the source message keeps the answer attached to the request in
  # Feishu's UI. `reply_in_thread` follows the SAME rule as every other Feishu
  # reply in the repo (`SalixIM.ConversationDelivery`, the meeting bindings,
  # both tool manuals): it keys off CHAT TYPE, not off whether this particular
  # message already sits in a thread. A top-level group @mention is meant to
  # open a topic, so that later replies continue without another mention —
  # keying off thread presence would answer it flat and leave the command the
  # only Router reply in the group that opens no thread. `chat_id` rides along
  # so `Feishu.maybe_record_thread_participation/3` can mark the topic.
  defp feishu_reply(metadata, text) do
    message_id = trim(metadata["message_id"])
    chat_id = trim(metadata["chat_id"])
    group? = trim(metadata["chat_type"]) == "group"

    cond do
      message_id != "" ->
        params =
          %{"message_id" => message_id, "text" => text, "reply_in_thread" => group?}
          |> put_present("chat_id", chat_id)
          |> put_present("chat_type", metadata["chat_type"])

        params =
          if group?,
            do: put_present(params, "thread_id", metadata["message_thread_id"]),
            else: params

        {:ok, "feishu", "feishu.reply_text", params}

      chat_id != "" ->
        {:ok, "feishu", "feishu.send_text",
         %{"receive_id" => chat_id, "receive_id_type" => "chat_id", "text" => text}}

      true ->
        :unsupported
    end
  end

  # ---- routing ----

  # The Router agent and its persisted Router session come from the connect's
  # group, never from message content: a command's target is the chat it was
  # sent in, and nothing a sender writes can redirect it at another agent.
  defp resolve_router(group_id) do
    with {:ok, group} <- GroupDirectory.get_group(group_id),
         agent_id when agent_id != "" <- trim(group["router_agent_id"]),
         {:ok, session_id} <- ProviderConnects.agent_group_router_session_id(agent_id, group_id) do
      {:ok, agent_id, session_id}
    else
      "" -> {:error, :router_not_configured}
      {:error, _reason} = error -> error
    end
  end

  # ---- dispatch ----

  # Never fall back to running inline: a compaction on the callback process
  # would blow the provider's ACK budget. A dispatch that cannot start is an
  # ERROR, not a silent drop — see `intercept/4`.
  defp dispatch(fun) do
    if Application.get_env(:salix_im, :control_command_execution, :async) == :sync do
      guarded(fun)
      :ok
    else
      async(fun)
    end
  end

  defp async(fun) do
    # The GUIDE requires Task work to carry the request's context; without it a
    # command's spans and `surface` are orphaned from the webhook that caused
    # them, which is the only trace tying an executed command to its sender.
    observability = SystemsObservability.Context.capture()
    surface = SystemsObservability.Context.current_surface()
    child = fn -> SystemsObservability.Context.run(observability, fn -> guarded(fun) end) end

    if Process.whereis(@task_supervisor) do
      case Task.Supervisor.start_child(@task_supervisor, child) do
        {:ok, _pid} ->
          emit_dispatch("ok", surface)

        # `:max_children` is the shared node-wide cap: a `compact` task parks
        # for as long as the session owner takes, so a busy node really can
        # refuse. It is the SATURATION outcome the caller answers the sender
        # for; every other start failure is one it turns into an ingress
        # error, so the metric must split them the same way — otherwise a
        # query for off-ratio refusals counts a fault that IS on the ratio.
        {:error, :max_children} ->
          Logger.warning("salix control command was not dispatched: max_children")
          emit_dispatch("over_budget", surface)
          {:error, {:control_command_unavailable, :max_children}}

        {:error, reason} ->
          Logger.warning("salix control command was not dispatched: #{inspect(reason)}")
          emit_dispatch("unavailable", surface)
          {:error, {:control_command_unavailable, reason}}
      end
    else
      Logger.warning("salix control command was not dispatched: no task supervisor")
      emit_dispatch("unavailable", surface)
      {:error, {:control_command_unavailable, :no_task_supervisor}}
    end
  catch
    # A function-level `catch` cannot see the body's bindings, so the surface is
    # re-read here; it is process-local and unchanged by the failed spawn.
    :exit, reason ->
      Logger.warning("salix control command was not dispatched: #{inspect(reason)}")
      emit_dispatch("unavailable", SystemsObservability.Context.current_surface())
      {:error, {:control_command_unavailable, :task_supervisor_exit}}
  end

  defp guarded(fun) do
    fun.()
  rescue
    error -> Logger.warning("salix control command failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("salix control command failed: #{inspect({kind, reason})}")
  end

  defp log(group_id, parsed, metadata, outcome) do
    Logger.info(
      "salix_control_command group_id=#{group_id} provider=#{trim(metadata["provider"])} " <>
        "command=#{inspect(parsed)} outcome=#{inspect(outcome)}"
    )
  end

  # ---- formatting ----

  defp display_name(""), do: "(empty)"
  defp display_name(name), do: name

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp bytes(0), do: "0 bytes"
  defp bytes(1), do: "1 byte"
  defp bytes(size) when is_integer(size) and size > 0 and size < 1024, do: "#{number(size)} bytes"

  defp bytes(size) when is_integer(size) and size > 0 do
    {value, unit} =
      cond do
        size < 1024 * 1024 -> {size / 1024, "KB"}
        size < 1024 * 1024 * 1024 -> {size / (1024 * 1024), "MB"}
        true -> {size / (1024 * 1024 * 1024), "GB"}
      end

    :erlang.float_to_binary(value, decimals: 1) <> " " <> unit
  end

  # A manifest entry with no size is a shape this module does not control, so
  # it must not render as "0 bytes" — that would claim an empty file.
  defp bytes(_size), do: "unknown size"

  defp percent(used, window), do: round(used * 100 / window)

  defp number(value) when is_integer(value) and value < 0, do: "-" <> number(-value)

  defp number(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    |> String.reverse()
  end

  # Chat-facing, so it must not become an egress for internal detail: a bare
  # `inspect/1` here would render store errors, resolver tuples and exception
  # structs — paths, config, provider text — into a customer's Slack channel.
  # Known reasons get a sentence a person can act on; everything else degrades
  # to a bounded atom, with the raw term left to `failure/2`'s log line.
  defp describe(:internal_runtime_only),
    do: "this group's agent runs on an external runtime, which Salix does not manage"

  defp describe(:agent_control_not_configured), do: "the agent runtime is not available here"
  defp describe(reason) when is_atom(reason) and not is_nil(reason), do: to_string(reason)
  defp describe({reason, _detail}) when is_atom(reason), do: to_string(reason)
  defp describe(_reason), do: "unavailable"

  defp put_present(params, _key, nil), do: params

  defp put_present(params, key, value) do
    case trim(value) do
      "" -> params
      trimmed -> Map.put(params, key, trimmed)
    end
  end

  defp blank_default(value, fallback) do
    case trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
