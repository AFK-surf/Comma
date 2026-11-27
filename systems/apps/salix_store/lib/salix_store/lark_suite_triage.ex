defmodule SalixStore.LarkSuiteTriage do
  @moduledoc """
  Postgres storage of Feishu and Lark group triage. Slack triage keeps its
  own tables and modules; nothing here is shared with it.

  * A source is one Feishu or Lark connect of a Group, with the Router Agent
    it answers as and its monitoring switch.
  * A chat is one group chat a source watches. At most one source of a tenant
    watches one chat at a time (`lark_suite_triage_chats_active_owner_idx`):
    two Agent Swarms in a shared group never both answer. A paused chat lets
    another Swarm take the group.
  * A batch collects the ambient messages of one chat thread during the
    debounce window, then one worker claims it, evaluates it once and records
    the outcome. Message text is stored redacted and is read only through
    `get_batch_for_reveal/3`; `list_activity/3` returns no text.

  Time comes from `SystemsClock`; each write takes `:now` (a `DateTime`) for
  deterministic tests.
  """

  alias SalixStore.Repo

  @providers ~w(feishu lark)
  @kinds ~w(reply reaction silence delegate)
  @max_messages 10
  @max_text_bytes 4_000
  @debounce_ms 3_000
  # A busy thread is still evaluated: the window moves with each message but
  # never past this bound from the batch's first message.
  @max_wait_ms 15_000
  @dedupe_window_ms 24 * 3_600_000
  @lease_ms 120_000
  @max_page 50
  @bearer ~r/Bearer\s+\S+/i
  @active_owner_index "lark_suite_triage_chats_active_owner_idx"

  @batch_columns ~w(
    id tenant_id provider group_id connect_id router_agent_id chat_id chat_name thread_key
    state due_at lease_holder lease_until target_message_id latest_message_at_ms message_ids
    messages_json decision_kind reason_code reply_text reaction_emoji task_title
    task_conversation_id error_code inserted_at updated_at settled_at
  )

  @type source :: map()
  @type batch :: map()

  def providers, do: @providers
  def debounce_ms, do: @debounce_ms

  ## Sources and chats

  @doc "Every source of a Group (`tenant_id`, `group_id`), each with its chats."
  @spec list_group_sources(String.t(), String.t()) :: {:ok, [source()]} | {:error, term()}
  def list_group_sources(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    with {:ok, sources} <-
           select(
             """
             SELECT tenant_id, provider, connect_id, group_id, router_agent_id, enabled,
                    updated_by, inserted_at, updated_at
             FROM lark_suite_triage_sources
             WHERE tenant_id = $1 AND group_id = $2
             ORDER BY provider, connect_id
             """,
             [tenant_id, group_id]
           ),
         {:ok, chats} <-
           select(
             """
             SELECT tenant_id, provider, connect_id, chat_id, group_id, chat_name, enabled,
                    inserted_at, updated_at
             FROM lark_suite_triage_chats
             WHERE tenant_id = $1 AND group_id = $2
             ORDER BY chat_name, chat_id
             """,
             [tenant_id, group_id]
           ) do
      by_source = Enum.group_by(chats, &{&1.provider, &1.connect_id})

      {:ok,
       Enum.map(sources, fn source ->
         Map.put(source, :chats, Map.get(by_source, {source.provider, source.connect_id}, []))
       end)}
    end
  end

  @doc """
  Creates or updates one source: `tenant_id`, `provider`, `connect_id`,
  `group_id`, `router_agent_id`, `enabled`, `updated_by`.
  """
  @spec upsert_source(map(), keyword()) :: {:ok, source()} | {:error, term()}
  def upsert_source(attrs, opts \\ []) when is_map(attrs) do
    now = now(opts)

    with {:ok, attrs} <- source_attrs(attrs) do
      select_one(
        """
        INSERT INTO lark_suite_triage_sources
          (tenant_id, provider, connect_id, group_id, router_agent_id, enabled, updated_by,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8)
        ON CONFLICT (tenant_id, provider, connect_id) DO UPDATE SET
          group_id = EXCLUDED.group_id,
          router_agent_id = EXCLUDED.router_agent_id,
          enabled = EXCLUDED.enabled,
          updated_by = EXCLUDED.updated_by,
          updated_at = EXCLUDED.updated_at
        RETURNING tenant_id, provider, connect_id, group_id, router_agent_id, enabled,
                  updated_by, inserted_at, updated_at
        """,
        [
          attrs.tenant_id,
          attrs.provider,
          attrs.connect_id,
          attrs.group_id,
          attrs.router_agent_id,
          attrs.enabled,
          attrs.updated_by,
          now
        ]
      )
    end
  end

  @doc """
  Adds a chat to a source, or enables it again: `tenant_id`, `provider`,
  `connect_id`, `group_id`, `chat_id`, `chat_name`. A chat another active
  source of the tenant watches is refused with the Group and connect that hold
  it. If the holding source is disabled, its chat row is paused first so the
  new source can claim the chat.
  """
  @spec add_or_enable_chat(map(), keyword()) ::
          {:ok, map()} | {:error, {:chat_already_claimed, map()} | term()}
  def add_or_enable_chat(attrs, opts \\ []) when is_map(attrs) do
    now = now(opts)

    with {:ok, attrs} <- chat_attrs(attrs) do
      transaction(fn ->
        with :ok <-
               release_inactive_owner(
                 attrs.tenant_id,
                 attrs.provider,
                 attrs.chat_id,
                 attrs.connect_id,
                 now
               ) do
          select_one(
            """
            INSERT INTO lark_suite_triage_chats
              (tenant_id, provider, connect_id, chat_id, group_id, chat_name, enabled,
               inserted_at, updated_at)
            VALUES ($1, $2, $3, $4, $5, $6, true, $7, $7)
            ON CONFLICT (tenant_id, provider, connect_id, chat_id) DO UPDATE SET
              enabled = true,
              chat_name = CASE WHEN EXCLUDED.chat_name = '' THEN lark_suite_triage_chats.chat_name
                               ELSE EXCLUDED.chat_name END,
              updated_at = EXCLUDED.updated_at
            RETURNING tenant_id, provider, connect_id, chat_id, group_id, chat_name, enabled,
                      inserted_at, updated_at
            """,
            [
              attrs.tenant_id,
              attrs.provider,
              attrs.connect_id,
              attrs.chat_id,
              attrs.group_id,
              attrs.chat_name,
              now
            ]
          )
        end
      end)
      |> claimed(attrs)
    end
  end

  @doc "Pauses or resumes one chat of a source. Resuming is refused while another active source holds it."
  @spec set_chat_enabled(String.t(), String.t(), String.t(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, :not_found | {:chat_already_claimed, map()} | term()}
  def set_chat_enabled(tenant_id, provider, connect_id, chat_id, false, opts) do
    """
    UPDATE lark_suite_triage_chats SET enabled = false, updated_at = $5
    WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
    RETURNING tenant_id, provider, connect_id, chat_id, group_id, chat_name, enabled,
              inserted_at, updated_at
    """
    |> select_one([tenant_id, provider, connect_id, chat_id, now(opts)])
    |> claimed(%{
      tenant_id: tenant_id,
      provider: provider,
      connect_id: connect_id,
      chat_id: chat_id
    })
  end

  def set_chat_enabled(tenant_id, provider, connect_id, chat_id, true, opts) do
    now = now(opts)

    attrs = %{
      tenant_id: tenant_id,
      provider: provider,
      connect_id: connect_id,
      chat_id: chat_id
    }

    transaction(fn ->
      with {:ok, [_exists]} <-
             select(
               """
               SELECT 1 FROM lark_suite_triage_chats
               WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
               FOR UPDATE
               """,
               [tenant_id, provider, connect_id, chat_id],
               :rows
             ),
           :ok <- release_inactive_owner(tenant_id, provider, chat_id, connect_id, now) do
        select_one(
          """
          UPDATE lark_suite_triage_chats SET enabled = true, updated_at = $5
          WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
          RETURNING tenant_id, provider, connect_id, chat_id, group_id, chat_name, enabled,
                    inserted_at, updated_at
          """,
          [tenant_id, provider, connect_id, chat_id, now]
        )
      else
        {:ok, []} -> {:ok, nil}
        {:error, _reason} = error -> error
      end
    end)
    |> claimed(attrs)
  end

  def set_chat_enabled(tenant_id, provider, connect_id, chat_id, enabled),
    do: set_chat_enabled(tenant_id, provider, connect_id, chat_id, enabled, [])

  @doc """
  The enabled source and enabled chat that watch `chat_id` through
  `connect_id`, or `:none`.
  """
  @spec active_source_for_chat(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{source: source(), chat: map()}} | :none | {:error, term()}
  def active_source_for_chat(tenant_id, provider, connect_id, chat_id)
      when is_binary(tenant_id) and is_binary(provider) and is_binary(connect_id) and
             is_binary(chat_id) do
    case select(
           """
           SELECT s.group_id, s.router_agent_id, s.enabled, c.chat_name, c.enabled
           FROM lark_suite_triage_sources s
           JOIN lark_suite_triage_chats c
             ON c.tenant_id = s.tenant_id AND c.provider = s.provider AND c.connect_id = s.connect_id
           WHERE s.tenant_id = $1 AND s.provider = $2 AND s.connect_id = $3 AND c.chat_id = $4
             AND s.enabled = true AND c.enabled = true
           """,
           [tenant_id, provider, connect_id, chat_id],
           :rows
         ) do
      {:ok, [[group_id, router_agent_id, true, chat_name, true]]} ->
        {:ok,
         %{
           source: %{
             tenant_id: tenant_id,
             provider: provider,
             connect_id: connect_id,
             group_id: group_id,
             router_agent_id: router_agent_id,
             enabled: true
           },
           chat: %{chat_id: chat_id, chat_name: chat_name, enabled: true}
         }}

      {:ok, _none} ->
        :none

      {:error, _reason} = error ->
        error
    end
  end

  def active_source_for_chat(_tenant_id, _provider, _connect_id, _chat_id), do: :none

  ## Batches

  @doc """
  Adds one ambient message to the collecting batch of its chat thread, or
  starts one. `context`: `tenant_id`, `provider`, `group_id`, `connect_id`,
  `router_agent_id`, `chat_id`, `chat_name`, `thread_key`. `message`:
  `message_id`, `sender_id`, `sender_name`, `text`, `sent_at_ms`.

  A message already in this chat's batches of the last day is ignored. Text
  is redacted (`Bearer` credentials) before it is stored, and a batch keeps
  the newest #{@max_messages} messages; its target is the newest one.
  """
  @spec append_ambient_message(map(), map(), keyword()) ::
          {:ok, :appended | :duplicate, String.t() | nil} | {:error, term()}
  def append_ambient_message(context, message, opts \\ [])
      when is_map(context) and is_map(message) do
    now = now(opts)

    with {:ok, context} <- batch_context(context),
         {:ok, message} <- message_attrs(message) do
      transaction(fn -> append(context, message, now) end)
    end
  end

  defp append(context, message, now) do
    since = NaiveDateTime.add(now, -@dedupe_window_ms, :millisecond)

    case select(
           """
           SELECT 1 FROM lark_suite_triage_batches
           WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
             AND inserted_at >= $5 AND $6 = ANY(message_ids)
           LIMIT 1
           """,
           [
             context.tenant_id,
             context.provider,
             context.connect_id,
             context.chat_id,
             since,
             message.message_id
           ],
           :rows
         ) do
      {:ok, [_hit]} -> {:ok, :duplicate, nil}
      {:ok, []} -> append_new(context, message, now)
      {:error, _reason} = error -> error
    end
  end

  defp append_new(context, message, now) do
    case collecting_for_update(context) do
      {:ok, nil} ->
        insert_batch(context, message, now)

      {:ok, batch} ->
        update_batch(batch, message, now)

      {:error, _reason} = error ->
        error
    end
  end

  defp collecting_for_update(context) do
    case select(
           "SELECT #{Enum.join(@batch_columns, ", ")} FROM lark_suite_triage_batches " <>
             "WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4 " <>
             "AND thread_key = $5 AND state = 'collecting' FOR UPDATE",
           [
             context.tenant_id,
             context.provider,
             context.connect_id,
             context.chat_id,
             context.thread_key
           ]
         ) do
      {:ok, [batch]} -> {:ok, batch}
      {:ok, []} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp insert_batch(context, message, now) do
    id = "ltb_" <> SystemsRuntime.Proc.uuid()
    due = NaiveDateTime.add(now, @debounce_ms, :millisecond)

    case Repo.query(
           """
           INSERT INTO lark_suite_triage_batches
             (id, tenant_id, provider, group_id, connect_id, router_agent_id, chat_id, chat_name,
              thread_key, state, due_at, target_message_id, latest_message_at_ms, message_ids,
              messages_json, inserted_at, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'collecting', $10, $11, $12, $13, $14,
                   $15, $15)
           ON CONFLICT (tenant_id, provider, connect_id, chat_id, thread_key)
             WHERE state = 'collecting' DO NOTHING
           """,
           [
             id,
             context.tenant_id,
             context.provider,
             context.group_id,
             context.connect_id,
             context.router_agent_id,
             context.chat_id,
             context.chat_name,
             context.thread_key,
             due,
             message.message_id,
             message.sent_at_ms,
             [message.message_id],
             [message_json(message)],
             now
           ]
         ) do
      {:ok, %{num_rows: 1}} ->
        {:ok, :appended, id}

      # Another delivery started the batch first: join it.
      {:ok, %{num_rows: 0}} ->
        case collecting_for_update(context) do
          {:ok, %{} = batch} -> update_batch(batch, message, now)
          {:ok, nil} -> {:error, :batch_conflict}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp update_batch(batch, message, now) do
    messages =
      (batch.messages_json ++ [message_json(message)])
      |> Enum.sort_by(&{&1["sent_at_ms"] || 0, &1["message_id"]})
      |> Enum.take(-@max_messages)

    target = List.last(messages)
    deadline = NaiveDateTime.add(batch.inserted_at, @max_wait_ms, :millisecond)
    due = Enum.min([NaiveDateTime.add(now, @debounce_ms, :millisecond), deadline], NaiveDateTime)

    case Repo.query(
           """
           UPDATE lark_suite_triage_batches SET
             message_ids = $2, messages_json = $3, target_message_id = $4,
             latest_message_at_ms = $5, due_at = $6, updated_at = $7
           WHERE id = $1 AND state = 'collecting'
           """,
           [
             batch.id,
             Enum.uniq(batch.message_ids ++ [message.message_id]),
             messages,
             target["message_id"],
             max(batch.latest_message_at_ms, message.sent_at_ms),
             due,
             now
           ]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, :appended, batch.id}
      {:ok, _} -> {:error, :batch_conflict}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Claims up to `limit` batches whose window has closed, and batches whose
  earlier claim lapsed, for `holder` (`FOR UPDATE SKIP LOCKED`).
  """
  @spec claim_due_batches(String.t(), pos_integer(), keyword()) ::
          {:ok, [batch()]} | {:error, term()}
  def claim_due_batches(holder, limit, opts \\ [])
      when is_binary(holder) and is_integer(limit) and limit > 0 do
    now = now(opts)

    select(
      """
      WITH due AS (
        SELECT id FROM lark_suite_triage_batches
        WHERE (state = 'collecting' AND due_at <= $1)
           OR (state = 'claimed' AND lease_until <= $1)
        ORDER BY due_at
        LIMIT $2
        FOR UPDATE SKIP LOCKED
      )
      UPDATE lark_suite_triage_batches b SET
        state = 'claimed', lease_holder = $3, lease_until = $4, updated_at = $1
      FROM due WHERE b.id = due.id
      RETURNING #{Enum.map_join(@batch_columns, ", ", &("b." <> &1))}
      """,
      [now, min(limit, @max_page), holder, NaiveDateTime.add(now, @lease_ms, :millisecond)]
    )
  end

  @doc "Whether a later batch of the same chat thread is still pending."
  @spec newer_pending?(batch()) :: boolean()
  def newer_pending?(batch) do
    case select(
           """
           SELECT 1 FROM lark_suite_triage_batches
           WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
             AND thread_key = $5 AND id <> $6 AND state IN ('collecting', 'claimed')
             AND inserted_at >= $7
           LIMIT 1
           """,
           [
             batch.tenant_id,
             batch.provider,
             batch.connect_id,
             batch.chat_id,
             batch.thread_key,
             batch.id,
             batch.inserted_at
           ],
           :rows
         ) do
      {:ok, []} -> false
      _hit_or_unknown -> true
    end
  end

  @doc """
  Records the outcome of a claimed batch. `outcome`: `state` (`applied`,
  `stale` or `failed`) and any of `decision_kind`, `reason_code`,
  `reply_text`, `reaction_emoji`, `task_title`, `task_conversation_id`,
  `error_code`, and `messages_json` with sender names resolved. Only the claim's holder settles it.
  """
  @spec complete_batch(String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, :lease_lost | term()}
  def complete_batch(batch_id, holder, outcome, opts \\ []) when is_map(outcome) do
    state = outcome[:state]

    if state in ~w(applied stale failed) do
      case Repo.query(
             """
             UPDATE lark_suite_triage_batches SET
               state = $3, decision_kind = $4, reason_code = $5, reply_text = $6,
               reaction_emoji = $7, task_title = $8, task_conversation_id = $9, error_code = $10,
               lease_holder = NULL, lease_until = NULL, settled_at = $11, updated_at = $11,
               messages_json = COALESCE($12, messages_json)
             WHERE id = $1 AND state = 'claimed' AND lease_holder = $2
             """,
             [
               batch_id,
               holder,
               state,
               outcome[:decision_kind],
               outcome[:reason_code],
               outcome[:reply_text],
               outcome[:reaction_emoji],
               outcome[:task_title],
               outcome[:task_conversation_id],
               outcome[:error_code],
               now(opts),
               outcome_messages(outcome[:messages_json])
             ]
           ) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, _} -> {:error, :lease_lost}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_outcome}
    end
  end

  @doc """
  One page of a Router Agent's settled batches, newest first, without message
  text. `opts`: `kind` (`reply`, `reaction`, `silence`, `delegate`),
  `chat_id`, `before` (a `{inserted_at_us, id}` cursor), `limit` (at most
  #{@max_page}).
  """
  @spec list_activity(String.t(), String.t(), keyword()) ::
          {:ok, %{items: [map()], next_cursor: {integer(), String.t()} | nil}} | {:error, term()}
  def list_activity(tenant_id, router_agent_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(@max_page)
    kind = Keyword.get(opts, :kind)
    chat_id = Keyword.get(opts, :chat_id)

    {before_at, before_id} =
      case Keyword.get(opts, :before) do
        {us, id} when is_integer(us) and is_binary(id) -> {from_us(us), id}
        _none -> {nil, nil}
      end

    params = [
      tenant_id,
      router_agent_id,
      if(kind in @kinds, do: kind),
      present(chat_id),
      before_at,
      before_id,
      limit + 1
    ]

    with {:ok, rows} <-
           select(
             """
             SELECT #{Enum.join(@batch_columns, ", ")} FROM lark_suite_triage_batches
             WHERE tenant_id = $1 AND router_agent_id = $2
               AND state IN ('applied', 'stale', 'failed')
               AND ($3::text IS NULL OR decision_kind = $3)
               AND ($4::text IS NULL OR chat_id = $4)
               AND ($5::timestamp IS NULL OR (inserted_at, id) < ($5, $6::text))
             ORDER BY inserted_at DESC, id DESC
             LIMIT $7
             """,
             params
           ) do
      {page, rest} = Enum.split(rows, limit)

      next =
        case {rest, List.last(page)} do
          {[_ | _], %{} = last} -> {to_us(last.inserted_at), last.id}
          _ -> nil
        end

      {:ok, %{items: Enum.map(page, &without_text/1), next_cursor: next}}
    end
  end

  @doc "One settled batch of a Router Agent with its redacted message text, for an audited reveal."
  @spec get_batch_for_reveal(String.t(), String.t(), String.t()) ::
          {:ok, batch()} | {:error, :not_found | term()}
  def get_batch_for_reveal(tenant_id, router_agent_id, batch_id) do
    case select(
           "SELECT #{Enum.join(@batch_columns, ", ")} FROM lark_suite_triage_batches " <>
             "WHERE tenant_id = $1 AND router_agent_id = $2 AND id = $3 " <>
             "AND state IN ('applied', 'stale', 'failed')",
           [tenant_id, router_agent_id, batch_id]
         ) do
      {:ok, [batch]} -> {:ok, batch}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Replaces `Bearer` credentials in `text`."
  @spec redact(String.t()) :: String.t()
  def redact(text) when is_binary(text),
    do: Regex.replace(@bearer, text, "[Bearer-credential withheld]")

  ## Helpers

  # Sender names resolved at evaluation replace the stored ones; nothing else
  # of a message changes after intake.
  defp outcome_messages(messages) when is_list(messages),
    do: Enum.map(messages, &Map.take(&1, ~w(message_id sender_id sender_name text sent_at_ms)))

  defp outcome_messages(_messages), do: nil

  defp without_text(batch) do
    %{
      batch
      | messages_json:
          Enum.map(
            batch.messages_json,
            &Map.take(&1, ~w(message_id sender_id sender_name sent_at_ms))
          )
    }
    |> Map.drop([:reply_text])
  end

  defp claimed({:error, %Postgrex.Error{postgres: %{constraint: @active_owner_index}}}, attrs) do
    case select(
           """
           SELECT group_id, connect_id FROM lark_suite_triage_chats
           WHERE tenant_id = $1 AND provider = $2 AND chat_id = $3 AND enabled = true
           LIMIT 1
           """,
           [attrs.tenant_id, attrs.provider, attrs.chat_id],
           :rows
         ) do
      {:ok, [[group_id, connect_id]]} ->
        {:error, {:chat_already_claimed, %{group_id: group_id, connect_id: connect_id}}}

      _gone ->
        {:error, {:chat_already_claimed, %{group_id: nil, connect_id: nil}}}
    end
  end

  defp claimed({:ok, nil}, _attrs), do: {:error, :not_found}
  defp claimed(result, _attrs), do: result

  defp source_attrs(attrs) do
    with {:ok, base} <- keys(attrs, ~w(tenant_id provider connect_id group_id router_agent_id)a),
         true <- is_boolean(attrs[:enabled]) || {:error, :invalid} do
      {:ok, Map.merge(base, %{enabled: attrs[:enabled], updated_by: present(attrs[:updated_by])})}
    end
  end

  defp chat_attrs(attrs) do
    with {:ok, base} <- keys(attrs, ~w(tenant_id provider connect_id group_id chat_id)a) do
      {:ok, Map.put(base, :chat_name, bounded(attrs[:chat_name] || "", 256))}
    end
  end

  defp batch_context(context) do
    with {:ok, base} <-
           keys(context, ~w(tenant_id provider group_id connect_id router_agent_id chat_id)a) do
      {:ok,
       Map.merge(base, %{
         chat_name: bounded(context[:chat_name] || "", 256),
         thread_key: bounded(context[:thread_key] || "", 256)
       })}
    end
  end

  defp message_attrs(message) do
    with {:ok, %{message_id: id}} <- keys(message, [:message_id]),
         true <-
           (is_integer(message[:sent_at_ms]) and message[:sent_at_ms] >= 0) || {:error, :invalid} do
      {:ok,
       %{
         message_id: id,
         sender_id: bounded(message[:sender_id] || "", 128),
         sender_name: bounded(message[:sender_name] || "", 256),
         text: message[:text] |> to_string() |> redact() |> bounded(@max_text_bytes),
         sent_at_ms: message[:sent_at_ms]
       }}
    end
  end

  defp message_json(message),
    do: %{
      "message_id" => message.message_id,
      "sender_id" => message.sender_id,
      "sender_name" => message.sender_name,
      "text" => message.text,
      "sent_at_ms" => message.sent_at_ms
    }

  defp keys(attrs, keys) do
    values = Map.new(keys, &{&1, present(attrs[&1])})

    cond do
      Enum.any?(values, fn {_key, value} -> is_nil(value) end) -> {:error, :invalid}
      Map.has_key?(values, :provider) and values.provider not in @providers -> {:error, :invalid}
      true -> {:ok, values}
    end
  end

  defp release_inactive_owner(tenant_id, provider, chat_id, connect_id, now) do
    case select(
           """
           SELECT c.connect_id, c.group_id, COALESCE(s.enabled, false)
           FROM lark_suite_triage_chats c
           LEFT JOIN lark_suite_triage_sources s
             ON s.tenant_id = c.tenant_id AND s.provider = c.provider AND s.connect_id = c.connect_id
           WHERE c.tenant_id = $1 AND c.provider = $2 AND c.chat_id = $3
             AND c.enabled = true AND c.connect_id <> $4
           FOR UPDATE OF c
           """,
           [tenant_id, provider, chat_id, connect_id],
           :rows
         ) do
      {:ok, []} ->
        :ok

      {:ok, [[owner_connect_id, owner_group_id, true]]} ->
        {:error,
         {:chat_already_claimed, %{group_id: owner_group_id, connect_id: owner_connect_id}}}

      {:ok, [[owner_connect_id, _owner_group_id, false]]} ->
        case Repo.query(
               """
               UPDATE lark_suite_triage_chats SET enabled = false, updated_at = $5
               WHERE tenant_id = $1 AND provider = $2 AND connect_id = $3 AND chat_id = $4
                 AND enabled = true
               """,
               [tenant_id, provider, owner_connect_id, chat_id, now]
             ) do
          {:ok, _} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, _} = ok -> ok
             {:ok, _status, _id} = ok -> ok
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp select(sql, params, shape \\ :maps) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows}} when shape == :rows ->
        {:ok, rows}

      {:ok, %{columns: columns, rows: rows}} ->
        # Column names come from this module's own SQL.
        keys = Enum.map(columns, &String.to_atom/1)
        {:ok, Enum.map(rows, &(keys |> Enum.zip(&1) |> Map.new()))}

      {:error, _reason} = error ->
        error
    end
  end

  defp select_one(sql, params) do
    case select(sql, params) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now) do
      %DateTime{} = at -> DateTime.to_naive(at)
      %NaiveDateTime{} = at -> at
      nil -> DateTime.to_naive(SystemsClock.utc_now())
    end
  end

  @doc false
  def to_us(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  def to_us(_at), do: nil

  defp from_us(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present(_value), do: nil

  defp bounded(value, max) when is_binary(value) do
    if byte_size(value) <= max,
      do: value,
      else: value |> binary_part(0, max) |> String.chunk(:valid) |> hd()
  end

  defp bounded(_value, _max), do: ""
end
