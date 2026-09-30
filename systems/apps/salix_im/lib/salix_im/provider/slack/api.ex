defmodule SalixIM.Provider.Slack.API do
  @moduledoc """
  Minimal Slack Web API client (Req-based) covering exactly the surface the
  Slack-native tool suite needs.

  Ports the `slack-go/slack` v0.19.0 call patterns used by willow
  `internal/tools/slack.go`, `slack_extra.go`, and `slack_helpers.go`:

    * Slack Web API writes and most reads use `POST {base}/{method}` with
      form-encoded fields; `files.list`, `conversations.history`, and
      `conversations.replies` follow Slack's documented `GET` query contract.
      The bot token is sent as an
      `Authorization: Bearer` header rather than in the form body (intentional
      divergence, asserted by tests),
    * JSON-in-form fields exactly as slack-go encodes them: `blocks`,
      `changes`, `document_content`, `files` are JSON strings inside the
      form,
    * file upload is the modern 3-step external flow slack-go's
      `UploadFileContext` performs: `files.getUploadURLExternal` → POST
      of the bytes to the returned URL → `files.completeUploadExternal`
      (step errors are prefixed `GetUploadURLExternal:` / `UploadToURL:` /
      `CompleteUploadExternal:` like slack-go's `fmt.Errorf` wrapping),
    * `{"ok": false, "error": ...}` responses raise
      `SalixIM.Provider.Slack.API.Error` carrying the raw Slack error string;
      HTTP 429 with a `Retry-After` header raises the same exception with
      `retry_after` set (slack-go's `RateLimitedError`). Direct provider-tool
      calls may opt into one bounded, shared retry scope with
      `with_tool_rate_limit_retry/1`; runtime-owned calls remain single-attempt
      at this layer.

  `error_message/1` reproduces willow's `slackErrorResult` shaping:
  rate-limit → `"rate limited by Slack, retry after <N>s"`, any message
  containing `missing_scope` → `"Slack API error: <msg>. The Slack app may
  need additional OAuth scopes."`, everything else passes through raw.
  `provider_error_message/1` keeps the existing IM-provider tool diagnostics
  stable (`Slack HTTP <status>`, `retry_after=<N>`, provider-specific scope
  details) while keeping Slack API error interpretation in this module.

  Intentional divergences from willow / slack-go:
    * bearer-header auth instead of token-in-form (above);
    * rate-limit durations always format as `"<N>s"` (Go `time.Duration`
      prints `"1m30s"` for 90s);
    * transport errors surface as `"slack api request failed: <reason>"`
      (slack-go surfaced Go `net/http` error strings);
    * non-JSON non-2xx responses raise `"slack server error: <status>"`
      (slack-go's `statusCodeError` includes the status text);
    * base URLs come from app env (`:slack_api_base_url`, default
      `https://slack.com/api`; `:slack_files_base_url`, default
      `https://files.slack.com`) instead of `slack.OptionAPIURL` — the
      files-URL seam has no willow equivalent (willow hardcoded
      `https://files.slack.com` in `downloadSlackCanvasMarkdown`) and exists
      so tests can mock canvas downloads.

  Requests are independent: no shared installation/method reservation or cooldown.
  Bounded direct-tool retries of remote Slack 429 responses are modeled in
  `tla/salix/SlackToolRetry.tla`.
  """

  alias SalixIM.Triage.CanonicalJSON

  @allow_observed_loopback Mix.env() == :test

  defmodule Error do
    @moduledoc """
    A Slack API-level failure: `message` is the raw Slack error string (or a
    step-prefixed variant), `retry_after` is the integer seconds from a 429
    `Retry-After` header (nil otherwise). Shape it for
    the model with `SalixIM.Provider.Slack.API.error_message/1`.
    """
    defexception [:message, :retry_after, :body, :status]
  end

  @tool_rate_limit_retry_key {__MODULE__, :tool_rate_limit_retry}
  @default_tool_rate_limit_retry_budget_ms 20_000
  # SalixAgent.Tools owns a 30-second outer tool deadline. Keep the transport
  # policy strictly inside it even when runtime config asks for more.
  @max_tool_rate_limit_retry_budget_ms 25_000
  @default_tool_rate_limit_max_retries 2
  @max_tool_rate_limit_max_retries 3
  # Do not spend the whole retry deadline sleeping; leave one bounded attempt.
  @tool_rate_limit_final_attempt_ms 1_000

  # ---- identity-fenced observed read ----
  #
  # The logical read a Triage identity fence authorizes is "up to
  # @observed_logical_limit objects of this exact scope", fetched as a bounded
  # chain of @observed_page_limit-object exchanges.
  #
  # These three bounds are ALSO the shape a stored receipt is validated against
  # (`Triage.RunFence` and `Triage.IdentityContract` compare `message_count`,
  # `page_budget`, and per-exchange counts to them), and fence records outlive
  # their run — the Ledger projection re-validates terminal fences long after.
  # They therefore have to keep describing what the reader can actually return:
  # raising the reader without raising these rejects real reads as forgeries,
  # and lowering them rejects already-stored receipts.
  #
  # Each chain follows its own cursor in order. Other callers may issue the
  # same method concurrently; the chain is not an atomic Slack snapshot.
  # Per-page receipts and the Triage run's authorization still bind its scope.
  #
  # @observed_page_budget * @observed_page_limit covers @observed_logical_limit
  # with margin for the thread parent Slack repeats on every replies page. A
  # scope wider than the budget settles as a real product boundary
  # (`page_budget_exceeded`), not as a transport artifact.
  @observed_logical_limit 200
  @observed_page_limit 15
  @observed_page_budget 14
  @observed_reaction_limit 64
  @observed_reaction_count_limit 10_000
  # Bound the complete read independently of the per-exchange timeout.
  @observed_chain_deadline_ms 60_000
  @max_observed_chain_deadline_ms 120_000
  @observed_page_chain_schema "comma.slack-read-page-chain.v1"
  @observed_message_keys ~w(
    app_id
    attachments
    blocks
    bot_id
    bot_profile
    client_msg_id
    display_as_bot
    edited
    files
    is_locked
    last_read
    latest_reply
    metadata
    parent_user_id
    reactions
    reply_count
    reply_users
    reply_users_count
    root
    subscribed
    subtype
    team
    text
    thread_ts
    ts
    type
    user
    unread_count
    upload
    username
  )
  @observed_bot_profile_keys ~w(
    app_id
    deleted
    icons
    id
    name
    team_id
    updated
    user_id
  )
  @observed_rich_text_container_types ~w(
    rich_text
    rich_text_list
    rich_text_preformatted
    rich_text_quote
    rich_text_section
  )
  @observed_rich_text_leaf_types ~w(
    broadcast
    channel
    color
    date
    emoji
    link
    message_mention
    text
    user
    usergroup
  )
  # Only rich-text blocks contribute canonical mention authority. The remaining
  # message blocks are presentation owned by Slack or by Comma's Slack renderer:
  # validate their closed outer contract after the recursive credential scan,
  # then drop them instead of interpreting their visible payload as ingress.
  @observed_display_only_block_keys %{
    "actions" => ~w(type block_id elements),
    "card" => ~w(type block_id hero_image icon slack_icon title subtitle body actions subtext),
    "container" => ~w(type block_id width title subtitle child_blocks has_header_divider),
    "context" => ~w(type block_id elements),
    "divider" => ~w(type block_id),
    "header" => ~w(type block_id text level),
    "image" => ~w(type block_id image_url alt_text title slack_file),
    "markdown" => ~w(type block_id text),
    "plan" => ~w(type block_id title tasks),
    "section" => ~w(type block_id text fields accessory expand),
    "table" => ~w(type block_id rows column_settings),
    "task_card" => ~w(type block_id task_id title status details output sources icon hide_title)
  }
  @observed_display_only_block_types Map.keys(@observed_display_only_block_keys)
  @observed_rejection_stages ~w(
    json_decode
    response_shape
    credential_material
    message_unknown_keys
    unsupported_message_content
    message_field_shape
    bot_profile_unknown_keys
    bot_profile_shape
    rich_text_unknown_keys
    rich_text_shape
    duplicate_timestamps
    unsafe_unknown_key_name
    unknown_key_overflow
  )
  @observed_rejection_paths ~w(
    response
    messages
    messages[]
    messages[].ts
    messages[].user
    messages[].text
    messages[].subtype
    messages[].bot_profile
    messages[].bot_id
    messages[].app_id
    messages[].blocks
    messages[].blocks[]
  )
  @credential_key_fragments ~w(
    api_key
    apikey
    authorization
    client_secret
    cookie
    credential
    headers
    password
    passwd
    private_key
    secret
    signing_secret
    token
  )

  @type credential :: String.t()

  @doc false
  def with_tool_rate_limit_retry(fun) when is_function(fun, 0) do
    case Process.get(@tool_rate_limit_retry_key) do
      %{deadline_ms: deadline_ms, retries_left: retries_left}
      when is_integer(deadline_ms) and is_integer(retries_left) ->
        # Nested helpers remain inside the original logical tool-call budget.
        fun.()

      previous ->
        run_with_tool_rate_limit_retry(fun, previous)
    end
  end

  defp run_with_tool_rate_limit_retry(fun, previous) do
    budget_ms = tool_rate_limit_retry_budget_ms()
    max_retries = tool_rate_limit_max_retries()

    if budget_ms == 0 or max_retries == 0 do
      fun.()
    else
      Process.put(@tool_rate_limit_retry_key, %{
        deadline_ms: System.monotonic_time(:millisecond) + budget_ms,
        retries_left: max_retries
      })

      try do
        fun.()
      after
        if is_nil(previous),
          do: Process.delete(@tool_rate_limit_retry_key),
          else: Process.put(@tool_rate_limit_retry_key, previous)
      end
    end
  end

  @doc "Resolve the bot token from an OAuth-complete Slack installation."
  @spec installation(map()) :: credential()
  def installation(connect) when is_map(connect) do
    values =
      [connect["bot_token"], connect["workspace_id"]]
      |> Enum.map(&(to_string(&1 || "") |> String.trim()))

    case values do
      [token, workspace_id] when token != "" and workspace_id != "" ->
        token

      _ ->
        raise ArgumentError, "Slack connect is not OAuth-complete"
    end
  end

  @doc "Slack Web API base URL (app env `:slack_api_base_url`)."
  @spec base_url() :: String.t()
  def base_url,
    do: configured_base(:slack_api_base_url, "https://slack.com/api")

  @doc """
  The normalized, approved Slack read origin hash.

  Identity-fenced Triage freezes this alongside the connect and product
  selectors, so a redirected, proxied, or otherwise substituted Slack endpoint
  cannot silently become the source of a frozen context. The only accepted
  origins are the live Slack Web API and, under `MIX_ENV=test`, a loopback
  mock.
  """
  @spec observed_read_origin_sha256() :: {:ok, String.t()} | {:error, :invalid_slack_read_origin}
  def observed_read_origin_sha256 do
    with {:ok, _origin, origin_sha256} <- normalized_observed_read_origin() do
      {:ok, origin_sha256}
    end
  end

  @doc "Objects one authorized logical observed read may return in total."
  @spec observed_logical_limit() :: pos_integer()
  def observed_logical_limit, do: @observed_logical_limit

  @doc "Objects one physical observed exchange asks Slack for."
  @spec observed_page_limit() :: pos_integer()
  def observed_page_limit, do: @observed_page_limit

  @doc "Exchanges one authorized logical observed read may spend."
  @spec observed_page_budget() :: pos_integer()
  def observed_page_budget, do: @observed_page_budget

  @doc """
  Narrows one pinned logical selector to the physical selector of one page.

  Exported so a recompute-side validator derives page 1's selector from the
  same code the reader used instead of re-deriving the rule from the field
  layout. Pages after the first carry an opaque Slack cursor no validator can
  reproduce.
  """
  @spec observed_page_selector(map(), String.t()) :: map()
  def observed_page_selector(%{"limit" => _, "cursor" => _} = selector, cursor)
      when is_binary(cursor),
      do: %{selector | "limit" => @observed_page_limit, "cursor" => cursor}

  defp normalized_observed_read_origin do
    uri = URI.parse(base_url())
    port = uri.port || URI.default_port(uri.scheme)
    base_path = uri.path || ""

    origin = %{
      "scheme" => uri.scheme,
      "host" => uri.host,
      "port" => port,
      "base_path" => base_path
    }

    origin_sha256 = origin |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

    valid? =
      is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
        base_path == "/api" and valid_observed_origin?(origin)

    if valid?, do: {:ok, origin, origin_sha256}, else: {:error, :invalid_slack_read_origin}
  end

  defp valid_observed_origin?(origin) do
    live? =
      origin == %{
        "scheme" => "https",
        "host" => "slack.com",
        "port" => 443,
        "base_path" => "/api"
      }

    loopback? =
      @allow_observed_loopback and origin["scheme"] == "http" and
        origin["host"] in ["127.0.0.1", "localhost", "::1"] and
        is_integer(origin["port"]) and origin["port"] > 0 and origin["base_path"] == "/api"

    live? or loopback?
  end

  @doc """
  willow's `slackErrorResult` message shaping for an `Error`:
  rate-limit wording, `missing_scope` OAuth hint, raw passthrough otherwise.

  Use this for meeting/runtime/provider-http paths that want the general
  model-facing Slack error wording.
  """
  @spec error_message(%Error{}) :: String.t()
  def error_message(%Error{retry_after: secs}) when is_integer(secs),
    do: "rate limited by Slack, retry after #{secs}s"

  def error_message(%Error{message: msg}) do
    if String.contains?(msg, "missing_scope") do
      "Slack API error: " <> msg <> ". The Slack app may need additional OAuth scopes."
    else
      msg
    end
  end

  @doc """
  Tool-facing Slack provider operation error shaping.

  This keeps provider operation messages stable while still making this module
  the single owner of Slack Web API error interpretation.
  Use this only from IM provider tool operations that need the existing
  provider diagnostics format.
  """
  @spec provider_error_message(%Error{}) :: String.t()
  def provider_error_message(%Error{retry_after: secs, body: body}) when is_integer(secs) do
    body = if is_map(body), do: body, else: %{}
    provider_rate_limited_message(Map.put(body, "retry_after", secs))
  end

  def provider_error_message(%Error{message: error, body: body})
      when is_map(body) and is_binary(error),
      do: provider_error_message(error, body)

  def provider_error_message(%Error{message: "slack server error: " <> status}),
    do: "Slack HTTP #{status}"

  def provider_error_message(%Error{message: message}), do: message

  # ---- chat ----

  @doc """
  Generic Slack Web API form request for provider operations that own their
  own response shaping. Returns the decoded Slack response body.
  """
  @spec request_form(credential(), String.t(), Enumerable.t(), keyword()) :: map()
  def request_form(token, method, fields, request_opts \\ []),
    do: request(:post, token, method, fields, request_opts)

  @doc "`oauth.v2.access` for Slack app installation callbacks."
  @spec oauth_v2_access(String.t(), String.t(), String.t(), String.t()) :: map()
  def oauth_v2_access(client_id, client_secret, code, redirect_uri) do
    post_form_without_auth("oauth.v2.access",
      client_id: client_id,
      client_secret: client_secret,
      code: code,
      redirect_uri: redirect_uri
    )
  end

  @doc "`auth.test` for resolving the installed bot's stable Slack identities."
  @spec auth_test(credential()) :: map()
  def auth_test(token), do: post_form(token, "auth.test", [])

  @doc "`auth.test` plus Slack's HTTP response time, used for provider-clock boundaries."
  @spec auth_test_with_response_date_ms(credential()) :: {map(), integer() | nil}
  def auth_test_with_response_date_ms(token) do
    {body, response} = request_with_response(:post, token, "auth.test", [])
    {body, response_date_ms(response)}
  end

  @doc """
  `chat.postMessage`. `opts`: `:blocks` / `:metadata` (maps encoded as JSON
  form fields), `:thread_ts`. Returns the decoded response map (`"channel"`,
  `"ts"`).
  """
  @spec post_message(credential(), String.t(), String.t(), keyword()) :: map()
  def post_message(token, channel, text, opts \\ []) do
    fields =
      [channel: channel, text: text]
      |> put_json(:blocks, opts[:blocks])
      |> put_json(:metadata, opts[:metadata])
      |> put_field(:thread_ts, opts[:thread_ts])

    post_form(token, "chat.postMessage", fields)
  end

  @doc "`chat.delete`."
  @spec delete_message(credential(), String.t(), String.t()) :: map()
  def delete_message(token, channel, ts),
    do: post_form(token, "chat.delete", channel: channel, ts: ts)

  @doc "`files.delete`."
  @spec delete_file(credential(), String.t()) :: map()
  def delete_file(token, file_id),
    do: post_form(token, "files.delete", file: file_id)

  @doc "`assistant.threads.setStatus`. `opts`: `:loading_messages`. Slack clears it when the app next posts to the thread."
  @spec set_assistant_status(credential(), String.t(), String.t(), String.t(), keyword()) ::
          map()
  def set_assistant_status(token, channel_id, thread_ts, status, opts \\ []) do
    fields =
      [channel_id: channel_id, thread_ts: thread_ts, status: status]
      |> put_json(:loading_messages, opts[:loading_messages])

    request(:post, token, "assistant.threads.setStatus", fields, keep_empty_keys: [:status])
  end

  # ---- conversations ----

  @doc "`conversations.info`. Returns the `\"channel\"` map."
  @spec conversation_info(credential(), String.t()) :: map()
  def conversation_info(token, channel) do
    token
    |> post_form("conversations.info", channel: channel)
    |> Map.get("channel", %{})
  end

  @doc """
  `conversations.list`. `opts`: `:limit`, `:cursor`, `:types` (list,
  comma-joined like slack-go), `:exclude_archived` (boolean). Returns the
  `"channels"` list.
  """
  @spec list_conversations(credential(), keyword()) :: [map()]
  def list_conversations(token, opts \\ []) do
    token
    |> list_conversation_page(opts)
    |> Map.get("channels", [])
  end

  @doc """
  One cursor-preserving `conversations.list` page for product-owned channel
  pickers. The projection keeps the Slack cursor beside the channels so the
  caller can offer an explicit, bounded "load more" action.
  """
  @spec list_conversation_page(credential(), keyword()) :: map()
  def list_conversation_page(token, opts \\ []) do
    fields =
      []
      |> put_field(:limit, opts[:limit])
      |> put_field(:cursor, opts[:cursor])
      |> put_field(:types, opts[:types] && Enum.join(opts[:types], ","))
      |> put_field(:exclude_archived, encode_bool(opts[:exclude_archived]))

    response = post_form(token, "conversations.list", fields)

    %{
      "channels" => Map.get(response, "channels", []),
      "next_cursor" => get_in(response, ["response_metadata", "next_cursor"])
    }
  end

  @doc """
  One cursor-preserving `users.conversations` page: the channels this
  installation's bot is actually a MEMBER of.

  Distinct from `list_conversation_page/2` above, which lists what exists in
  the workspace. Reading history needs membership, not existence —
  `conversations.history` on a channel the bot never joined answers
  `not_in_channel` — so a walker that enumerated with `conversations.list`
  would spend its whole Slack budget being refused.
  """
  @spec list_user_conversation_page(credential(), keyword()) :: map()
  def list_user_conversation_page(token, opts \\ []) do
    fields =
      []
      |> put_field(:limit, opts[:limit])
      |> put_field(:cursor, opts[:cursor])
      |> put_field(:types, opts[:types] && Enum.join(opts[:types], ","))
      |> put_field(:exclude_archived, encode_bool(opts[:exclude_archived]))

    response = post_form(token, "users.conversations", fields)

    %{
      "channels" => Map.get(response, "channels", []),
      "next_cursor" => get_in(response, ["response_metadata", "next_cursor"])
    }
  end

  @doc "`conversations.members`. Returns the `\"members\"` id list."
  @spec conversation_members(credential(), String.t(), pos_integer()) :: [String.t()]
  def conversation_members(token, channel, limit) do
    token
    |> post_form("conversations.members", channel: channel, limit: limit)
    |> Map.get("members", [])
  end

  @doc """
  `conversations.replies`. `opts`: `:cursor`, `:oldest`, `:latest`,
  `:inclusive`, `:include_all_metadata`, `:limit`. Returns
  `{messages, next_cursor}`.

  The restrictive observed mode requires exactly `receipt: :return`,
  `limit: 200`, `request_selector_sha256`, and `slack_api_origin_sha256`, and
  returns `{:ok, merged_page, chain_bytes, chain_receipt}` or a closed
  `{:error, typed_reason, chain_receipt}` after one bounded, cursor-following
  page chain. Invalid observed options fail before transport.
  """
  @spec conversation_replies(credential(), String.t(), String.t(), keyword(), keyword()) ::
          {[map()], String.t()}
          | {:ok, map(), binary(), map()}
          | {:error, atom()}
          | {:error, atom(), map()}
  def conversation_replies(token, channel, thread_ts, opts \\ [], request_opts \\ []) do
    case Keyword.fetch(opts, :receipt) do
      {:ok, :return} ->
        observed_conversation_replies(token, channel, thread_ts, opts)

      :error ->
        fields =
          [channel: channel, ts: thread_ts]
          |> put_field(:cursor, opts[:cursor])
          |> put_field(:oldest, opts[:oldest])
          |> put_field(:latest, opts[:latest])
          |> put_field(:inclusive, encode_bool(opts[:inclusive]))
          |> put_field(:include_all_metadata, encode_bool(opts[:include_all_metadata]))
          |> put_field(:limit, opts[:limit])

        body = get_query(token, "conversations.replies", fields, request_opts)
        {Map.get(body, "messages", []), get_in(body, ["response_metadata", "next_cursor"]) || ""}

      {:ok, _invalid_mode} ->
        {:error, :invalid_slack_read_receipt_request}
    end
  end

  @doc """
  `conversations.history`. `opts`: `:cursor`, `:oldest`, `:latest`,
  `:inclusive`, `:include_all_metadata`, `:limit`. Returns `{messages, next_cursor}`.

  The restrictive observed mode has the same closed chain-receipt contract as
  `conversation_replies/5`, but binds a channel-history selector without a
  caller-supplied method or URL.
  """
  @spec conversation_history(credential(), String.t(), keyword()) ::
          {[map()], String.t()}
          | {:ok, map(), binary(), map()}
          | {:error, atom()}
          | {:error, atom(), map()}
  def conversation_history(token, channel, opts \\ []) do
    case Keyword.fetch(opts, :receipt) do
      {:ok, :return} ->
        observed_conversation_history(token, channel, opts)

      :error ->
        fields =
          [channel: channel]
          |> put_field(:cursor, opts[:cursor])
          |> put_field(:oldest, opts[:oldest])
          |> put_field(:latest, opts[:latest])
          |> put_field(:inclusive, encode_bool(opts[:inclusive]))
          |> put_field(:include_all_metadata, encode_bool(opts[:include_all_metadata]))
          |> put_field(:limit, opts[:limit])

        body = get_query(token, "conversations.history", fields)
        {Map.get(body, "messages", []), get_in(body, ["response_metadata", "next_cursor"]) || ""}

      {:ok, _invalid_mode} ->
        {:error, :invalid_slack_read_receipt_request}
    end
  end

  defp observed_conversation_replies(credential, channel, thread_ts, opts) do
    operation = "conversations.replies"

    with :ok <- validate_observed_read_opts(opts),
         :ok <- validate_observed_values([credential, channel, thread_ts]),
         selector = observed_logical_selector(operation, channel, thread_ts),
         true <- canonical_sha256(selector) == opts[:request_selector_sha256],
         {:ok, _origin, origin_sha256, url} <-
           observed_read_origin(opts[:slack_api_origin_sha256], operation) do
      observed_paged_read(%{
        credential: credential,
        operation: operation,
        base_fields: [channel: channel, ts: thread_ts],
        selector: selector,
        selector_sha256: opts[:request_selector_sha256],
        origin_sha256: origin_sha256,
        url: url,
        root_ts: thread_ts
      })
    else
      false -> {:error, :invalid_slack_read_receipt_request}
      {:error, _reason} = error -> error
    end
  end

  defp observed_conversation_history(credential, channel, opts) do
    operation = "conversations.history"

    with :ok <- validate_observed_read_opts(opts),
         :ok <- validate_observed_values([credential, channel]),
         selector = observed_logical_selector(operation, channel, nil),
         true <- canonical_sha256(selector) == opts[:request_selector_sha256],
         {:ok, _origin, origin_sha256, url} <-
           observed_read_origin(opts[:slack_api_origin_sha256], operation) do
      observed_paged_read(%{
        credential: credential,
        operation: operation,
        base_fields: [channel: channel],
        selector: selector,
        selector_sha256: opts[:request_selector_sha256],
        origin_sha256: origin_sha256,
        url: url,
        root_ts: nil
      })
    else
      false -> {:error, :invalid_slack_read_receipt_request}
      {:error, _reason} = error -> error
    end
  end

  defp observed_paged_read(read) do
    read
    |> Map.put(:deadline, observed_chain_deadline())
    |> observed_page_chain("", [], [])
    |> observed_chain_result(read)
  end

  defp observed_chain_deadline,
    do: System.monotonic_time(:millisecond) + observed_chain_deadline_ms()

  defp observed_chain_deadline_ms do
    configured =
      Application.get_env(
        :salix_im,
        :slack_observed_chain_deadline_ms,
        @observed_chain_deadline_ms
      )

    if is_integer(configured) and configured > 0 and configured < @max_observed_chain_deadline_ms,
      do: configured,
      else: @observed_chain_deadline_ms
  end

  defp observed_page_chain(read, cursor, pages, exchanges) do
    index = length(exchanges) + 1

    cond do
      index > @observed_page_budget ->
        {:page_budget_exceeded, Enum.reverse(pages), Enum.reverse(exchanges)}

      System.monotonic_time(:millisecond) >= read.deadline ->
        {:chain_deadline_exceeded, Enum.reverse(pages), Enum.reverse(exchanges)}

      true ->
        observed_page_exchange(read, cursor, pages, exchanges)
    end
  end

  defp observed_page_exchange(read, cursor, pages, exchanges) do
    exchange_selector_sha256 = canonical_sha256(observed_page_selector(read.selector, cursor))
    fields = read.base_fields ++ [limit: @observed_page_limit] ++ observed_cursor_field(cursor)

    :get
    |> observed_request(auth(read.credential), read.url, fields)
    |> observed_read_envelope(read.operation, exchange_selector_sha256, read.origin_sha256)
    |> case do
      {:ok, page, receipt} ->
        pages = [page | pages]
        exchanges = [receipt | exchanges]

        case page["next_cursor"] do
          "" -> {:complete, Enum.reverse(pages), Enum.reverse(exchanges)}
          next -> observed_page_chain(read, next, pages, exchanges)
        end

      {:error, reason, receipt} ->
        {:failed, reason, Enum.reverse(pages), Enum.reverse([receipt | exchanges])}
    end
  end

  defp observed_cursor_field(""), do: []
  defp observed_cursor_field(cursor), do: [cursor: cursor]

  defp observed_chain_result({:complete, pages, exchanges}, read) do
    case merge_observed_pages(pages, read.root_ts) do
      # The authorized logical read is "up to @observed_logical_limit objects".
      # A merge that came out larger is a scope the authorization never covered,
      # so it settles at the same product boundary a too-wide scope already
      # settles at instead of silently handing back a page nobody authorized or
      # silently dropping the tail.
      {:ok, %{"messages" => messages}} when length(messages) > @observed_logical_limit ->
        {:error, :page_budget_exceeded,
         observed_error_chain_receipt(read, :page_budget_exceeded, exchanges, nil)}

      {:ok, page} ->
        {:ok, page, observed_page_chain_bytes(pages),
         observed_success_chain_receipt(read, page, pages, exchanges)}

      {:error, rejection} ->
        {:error, :decode_error,
         observed_error_chain_receipt(read, :decode_error, exchanges, rejection)}
    end
  end

  # A rejection the failing exchange recorded is the chain's rejection too: the
  # chain is the whole read, and the read failed for exactly that reason.
  defp observed_chain_result({:failed, reason, _pages, exchanges}, read),
    do:
      {:error, reason,
       observed_error_chain_receipt(read, reason, exchanges, List.last(exchanges)["rejection"])}

  defp observed_chain_result({outcome, _pages, exchanges}, read)
       when outcome in [:page_budget_exceeded, :chain_deadline_exceeded],
       do: {:error, outcome, observed_error_chain_receipt(read, outcome, exchanges, nil)}

  # Slack repeats the thread parent at the head of every `conversations.replies`
  # page. Dropping that exact repeat is the only merge licence; anything else
  # that repeats a timestamp is a rejected page, not a paging artifact.
  defp merge_observed_pages([first | rest], root_ts) do
    root = List.first(first["messages"])

    messages =
      Enum.reduce(rest, first["messages"], fn page, acc ->
        acc ++ drop_repeated_root(page["messages"], root, root_ts)
      end)

    timestamps = Enum.map(messages, & &1["ts"])

    if length(timestamps) == MapSet.size(MapSet.new(timestamps)),
      do: {:ok, %{"messages" => messages, "next_cursor" => ""}},
      else: {:error, observed_rejection("duplicate_timestamps", "messages", [])}
  end

  # The licensed repeat is the parent SLACK RETURNED, not the ts the caller
  # asked about: `conversations.replies` on a reply's ts answers with the whole
  # thread headed by its real parent, so requiring `head["ts"] == root_ts` made
  # that legitimate read fail as `decode_error` on duplicate timestamps instead
  # of merging.
  defp drop_repeated_root([head | tail], root, root_ts)
       when is_map(root) and is_binary(root_ts) and root_ts != "" do
    if head == root, do: tail, else: [head | tail]
  end

  defp drop_repeated_root(messages, _root, _root_ts), do: messages

  defp observed_success_chain_receipt(read, page, pages, exchanges) do
    chain_sha256 = pages |> observed_page_chain_bytes() |> CanonicalJSON.sha256()

    read
    |> observed_chain_receipt_base(exchanges)
    |> Map.merge(%{
      "outcome" => "success",
      "typed_reason" => nil,
      "canonical_page_sha256" => page |> CanonicalJSON.encode!() |> CanonicalJSON.sha256(),
      "message_count" => length(page["messages"]),
      "next_cursor_empty" => true,
      "canonical_page_chain_sha256" => chain_sha256,
      "rejection" => nil
    })
  end

  defp observed_error_chain_receipt(read, reason, exchanges, rejection) do
    typed_reason = Atom.to_string(reason)

    read
    |> observed_chain_receipt_base(exchanges)
    |> Map.merge(%{
      "outcome" => typed_reason,
      "typed_reason" => typed_reason,
      "canonical_page_sha256" => nil,
      "message_count" => nil,
      "next_cursor_empty" => nil,
      "canonical_page_chain_sha256" => nil,
      "rejection" => if(valid_observed_rejection?(rejection), do: rejection)
    })
  end

  defp observed_chain_receipt_base(read, exchanges) do
    last = List.last(exchanges)

    %{
      "schema" => "comma.slack-read-receipt-chain.v1",
      "operation" => read.operation,
      "method" => "GET",
      "request_selector_sha256" => read.selector_sha256,
      "slack_api_origin_sha256" => read.origin_sha256,
      "transport_invocation_count" => length(exchanges),
      "page_budget" => @observed_page_budget,
      "retry" => false,
      "redirect" => false,
      "http_status" => last && last["http_status"],
      "slack_request_id_sha256" => last && last["slack_request_id_sha256"],
      "exchanges" => exchanges
    }
  end

  @doc """
  Canonical bytes of one ordered observed page chain.

  The identity fence binds these bytes so every page that contributed to a
  frozen context is provable, not just the merged result.
  """
  @spec observed_page_chain_bytes([map()]) :: binary()
  def observed_page_chain_bytes(pages) when is_list(pages),
    do: CanonicalJSON.encode!(%{"schema" => @observed_page_chain_schema, "pages" => pages})

  defp observed_request(verb, headers, url, fields) do
    fields = Enum.reject(fields, fn {_key, value} -> value in [nil, ""] end)

    apply(Req, verb, [
      url,
      [headers: headers, params: fields, retry: false, redirect: false, decode_body: false]
    ])
  end

  defp validate_observed_values(values) do
    if Enum.all?(values, &nonblank_binary?/1),
      do: :ok,
      else: {:error, :invalid_slack_read_receipt_request}
  end

  defp nonblank_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp validate_observed_read_opts(opts) do
    valid? =
      Keyword.keyword?(opts) and
        opts |> Keyword.keys() |> Enum.sort() ==
          Enum.sort([:limit, :receipt, :request_selector_sha256, :slack_api_origin_sha256]) and
        opts[:limit] == @observed_logical_limit and opts[:receipt] == :return and
        lowercase_sha256?(opts[:request_selector_sha256]) and
        lowercase_sha256?(opts[:slack_api_origin_sha256])

    if valid?, do: :ok, else: {:error, :invalid_slack_read_receipt_request}
  end

  # The logical selector the identity fence pins names the whole read: this
  # scope, up to @observed_logical_limit objects, from the start. Each physical
  # exchange narrows it to one capped, cursor-anchored page.
  defp observed_logical_selector(operation, channel, nil) do
    %{
      "operation" => operation,
      "channel_id" => channel,
      "limit" => @observed_logical_limit,
      "cursor" => ""
    }
  end

  defp observed_logical_selector(operation, channel, thread_ts) do
    %{
      "operation" => operation,
      "channel_id" => channel,
      "thread_ts" => thread_ts,
      "limit" => @observed_logical_limit,
      "cursor" => ""
    }
  end

  defp canonical_sha256(value),
    do: value |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

  defp lowercase_sha256?(value),
    do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/

  defp observed_read_origin(expected_sha256, operation)
       when operation in ["conversations.history", "conversations.replies"] do
    with {:ok, origin, origin_sha256} <- normalized_observed_read_origin(),
         true <- origin_sha256 == expected_sha256 do
      uri = URI.parse(base_url())

      request_uri = %URI{
        scheme: uri.scheme,
        host: uri.host,
        port: uri.port,
        path: origin["base_path"] <> "/" <> operation
      }

      {:ok, origin, origin_sha256, URI.to_string(request_uri)}
    else
      _invalid -> {:error, :invalid_slack_read_origin}
    end
  end

  defp observed_read_envelope(
         {:ok, %Req.Response{status: status, body: body} = response},
         operation,
         selector_sha256,
         origin_sha256
       )
       when status in 200..299 and is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        observed_read_envelope(
          {:ok, %{response | body: decoded}},
          operation,
          selector_sha256,
          origin_sha256
        )

      {:error, _reason} ->
        observed_error(
          :decode_error,
          response,
          operation,
          selector_sha256,
          origin_sha256,
          observed_rejection("json_decode", "response", [])
        )
    end
  end

  defp observed_read_envelope(
         {:ok, %Req.Response{status: status, body: %{"ok" => true} = body} = response},
         operation,
         selector_sha256,
         origin_sha256
       )
       when status in 200..299 do
    messages = body["messages"]
    next_cursor = get_in(body, ["response_metadata", "next_cursor"]) || ""

    with :ok <- observed_response_shape(messages, next_cursor),
         {:ok, projected_messages} <- project_observed_messages(messages) do
      page = %{"messages" => projected_messages, "next_cursor" => next_cursor}
      page_sha256 = page |> CanonicalJSON.encode!() |> CanonicalJSON.sha256()

      {:ok, page,
       observed_receipt(
         operation,
         selector_sha256,
         origin_sha256,
         response,
         "success",
         nil,
         page_sha256,
         length(projected_messages),
         next_cursor == ""
       )}
    else
      {:error, %{} = rejection} ->
        observed_error(
          :decode_error,
          response,
          operation,
          selector_sha256,
          origin_sha256,
          rejection
        )

      _invalid ->
        observed_error(:decode_error, response, operation, selector_sha256, origin_sha256)
    end
  end

  defp observed_read_envelope(result, operation, selector_sha256, origin_sha256),
    do: observed_read_outcome(result, operation, selector_sha256, origin_sha256)

  defp observed_read_outcome(
         {:ok, %Req.Response{status: status, body: %{"ok" => false}} = response},
         operation,
         selector_sha256,
         origin_sha256
       )
       when status in 200..299,
       do: observed_error(:slack_error, response, operation, selector_sha256, origin_sha256)

  defp observed_read_outcome(
         {:ok, %Req.Response{status: status} = response},
         operation,
         selector_sha256,
         origin_sha256
       )
       when status in 200..299 do
    observed_error(
      :decode_error,
      response,
      operation,
      selector_sha256,
      origin_sha256,
      observed_rejection("response_shape", "response", [])
    )
  end

  defp observed_read_outcome(
         {:ok, %Req.Response{status: 429} = response},
         operation,
         selector_sha256,
         origin_sha256
       ),
       do: observed_error(:rate_limited, response, operation, selector_sha256, origin_sha256)

  defp observed_read_outcome(
         {:ok, %Req.Response{status: status} = response},
         operation,
         selector_sha256,
         origin_sha256
       )
       when is_integer(status) and (status < 200 or status > 299),
       do: observed_error(:http_error, response, operation, selector_sha256, origin_sha256)

  defp observed_read_outcome({:error, _reason}, operation, selector_sha256, origin_sha256),
    do: observed_error(:transport_error, nil, operation, selector_sha256, origin_sha256)

  defp observed_error(
         reason,
         response,
         operation,
         selector_sha256,
         origin_sha256,
         rejection \\ nil
       )
       when reason in [:slack_error, :rate_limited, :http_error, :transport_error, :decode_error] do
    typed_reason = Atom.to_string(reason)

    receipt =
      observed_receipt(
        operation,
        selector_sha256,
        origin_sha256,
        response,
        typed_reason,
        typed_reason,
        nil,
        nil,
        nil
      )

    receipt =
      if reason == :decode_error and valid_observed_rejection?(rejection) do
        receipt
        |> Map.put("schema", "comma.slack-read-receipt.v2")
        |> Map.put("rejection", rejection)
      else
        receipt
      end

    {:error, reason, receipt}
  end

  defp observed_receipt(
         operation,
         selector_sha256,
         origin_sha256,
         response,
         outcome,
         typed_reason,
         page_sha256,
         message_count,
         next_cursor_empty
       ) do
    %{
      "schema" => "comma.slack-read-receipt.v1",
      "operation" => operation,
      "method" => "GET",
      "request_selector_sha256" => selector_sha256,
      "slack_api_origin_sha256" => origin_sha256,
      "transport_invocation_count" => 1,
      "retry" => false,
      "redirect" => false,
      "outcome" => outcome,
      "typed_reason" => typed_reason,
      "http_status" => observed_http_status(response),
      "canonical_page_sha256" => page_sha256,
      "message_count" => message_count,
      "next_cursor_empty" => next_cursor_empty,
      "slack_request_id_sha256" => slack_request_id_sha256(response)
    }
  end

  defp slack_request_id_sha256(nil), do: nil

  defp slack_request_id_sha256(%Req.Response{} = response) do
    case Req.Response.get_header(response, "x-slack-req-id") do
      [request_id | _] when request_id != "" -> CanonicalJSON.sha256(request_id)
      _ -> nil
    end
  end

  defp observed_http_status(%Req.Response{status: status}) when is_integer(status), do: status
  defp observed_http_status(_response), do: nil

  defp project_observed_messages(messages) do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, projected} ->
      case project_observed_message(message) do
        {:ok, safe_message} -> {:cont, {:ok, [safe_message | projected]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, projected} ->
        projected = Enum.reverse(projected)
        timestamps = Enum.map(projected, & &1["ts"])

        if length(timestamps) == MapSet.size(MapSet.new(timestamps)),
          do: {:ok, projected},
          else: {:error, observed_rejection("duplicate_timestamps", "messages", [])}

      {:error, _reason} = error ->
        error
    end
  end

  defp project_observed_message(message) when is_map(message) do
    with :ok <- reject_credential_material(message),
         :ok <- reject_unsupported_observed_message_content(message),
         :ok <- reject_unknown_observed_message_keys(message),
         {:ok, timestamp} <-
           with_observed_rejection(
             observed_timestamp(message["ts"]),
             "message_field_shape",
             "messages[].ts"
           ),
         {:ok, user} <-
           with_observed_rejection(
             observed_optional_provider_id(message["user"]),
             "message_field_shape",
             "messages[].user"
           ),
         {:ok, text} <-
           with_observed_rejection(
             observed_text(message["text"]),
             "message_field_shape",
             "messages[].text"
           ),
         {:ok, subtype} <-
           with_observed_rejection(
             observed_optional_string(message["subtype"]),
             "message_field_shape",
             "messages[].subtype"
           ),
         {:ok, bot_profile} <- observed_bot_profile(message["bot_profile"]),
         {:ok, bot_id} <-
           with_observed_rejection(
             observed_optional_provider_id(message["bot_id"] || bot_profile["bot_id"]),
             "message_field_shape",
             "messages[].bot_id"
           ),
         {:ok, app_id} <-
           with_observed_rejection(
             observed_optional_provider_id(message["app_id"] || bot_profile["app_id"]),
             "message_field_shape",
             "messages[].app_id"
           ),
         {:ok, blocks} <- observed_rich_text_mentions(message["blocks"]),
         {:ok, reactions} <- observed_reactions(message["reactions"]) do
      safe_message = %{
        "ts" => timestamp,
        "user" => user,
        "text" => text,
        "subtype" => subtype,
        "bot_id" => bot_id,
        "app_id" => app_id,
        "bot_profile_name" => bot_profile["name"],
        "blocks" => blocks
      }

      safe_message =
        if reactions == [], do: safe_message, else: Map.put(safe_message, "reactions", reactions)

      safe_message =
        if observed_user_attributed_upload?(message, user) do
          Map.put(safe_message, "actor_kind", "human")
        else
          safe_message
        end

      {:ok, safe_message}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      _invalid -> {:error, :unsafe_observed_page}
    end
  end

  defp project_observed_message(_message), do: {:error, :unsafe_observed_page}

  defp observed_reactions(nil), do: {:ok, []}

  defp observed_reactions(reactions)
       when is_list(reactions) and length(reactions) <= @observed_reaction_limit do
    reactions
    |> Enum.reduce_while({:ok, []}, fn reaction, {:ok, projected} ->
      name = if is_map(reaction), do: reaction["name"]
      count = if is_map(reaction), do: reaction["count"]

      if is_binary(name) and byte_size(name) in 1..100 and
           Regex.match?(~r/\A[a-z0-9_+\-:]+\z/, name) and is_integer(count) and
           count in 1..@observed_reaction_count_limit do
        {:cont, {:ok, [%{"name" => name, "count" => count} | projected]}}
      else
        {:halt,
         {:error,
          observed_rejection(
            "message_field_shape",
            "messages[].reactions",
            []
          )}}
      end
    end)
    |> case do
      {:ok, projected} -> {:ok, Enum.reverse(projected)}
      {:error, _reason} = error -> error
    end
  end

  defp observed_reactions(_reactions),
    do: {:error, observed_rejection("message_field_shape", "messages[].reactions", [])}

  defp observed_response_shape(messages, next_cursor)
       when is_list(messages) and is_binary(next_cursor),
       do: :ok

  defp observed_response_shape(_messages, _next_cursor),
    do: {:error, observed_rejection("response_shape", "response", [])}

  defp reject_unsupported_observed_message_content(message) do
    if observed_dropped_collection?(message["files"]) and
         observed_dropped_collection?(message["attachments"]) and
         observed_dropped_root?(message["root"]) and
         observed_dropped_boolean?(message["display_as_bot"]) and
         observed_dropped_boolean?(message["upload"]),
       do: :ok,
       else: {:error, observed_rejection("unsupported_message_content", "messages[]", [])}
  end

  defp observed_dropped_collection?(nil), do: true

  defp observed_dropped_collection?(values) when is_list(values),
    do: Enum.all?(values, &is_map/1)

  defp observed_dropped_collection?(_value), do: false

  defp observed_dropped_root?(nil), do: true
  defp observed_dropped_root?(value), do: is_map(value)

  defp observed_dropped_boolean?(nil), do: true
  defp observed_dropped_boolean?(value), do: is_boolean(value)

  defp observed_user_attributed_upload?(message, provider_user_id)
       when is_binary(provider_user_id) and provider_user_id != "" do
    files = message["files"]

    message["display_as_bot"] == false and message["upload"] == true and
      is_list(files) and files != [] and
      Enum.all?(files, fn file ->
        is_map(file) and file["user"] == provider_user_id
      end)
  end

  defp observed_user_attributed_upload?(_message, _provider_user_id), do: false

  defp reject_unknown_observed_message_keys(message) do
    case Map.keys(message) -- @observed_message_keys do
      [] ->
        :ok

      keys ->
        {:error, observed_unknown_keys_rejection(keys, "message_unknown_keys", "messages[]")}
    end
  end

  defp observed_unknown_keys_rejection(keys, stage, path) do
    keys = keys |> Enum.uniq() |> Enum.sort()

    cond do
      length(keys) > 16 -> observed_rejection("unknown_key_overflow", path, [])
      Enum.all?(keys, &safe_observed_rejection_key?/1) -> observed_rejection(stage, path, keys)
      true -> observed_rejection("unsafe_unknown_key_name", path, [])
    end
  end

  defp observed_rejection(stage, path, unknown_keys) do
    rejection = %{
      "schema" => "comma.slack-read-rejection.v1",
      "stage" => stage,
      "path" => path,
      "unknown_keys" => unknown_keys
    }

    true = valid_observed_rejection?(rejection)
    rejection
  end

  defp valid_observed_rejection?(
         %{
           "schema" => "comma.slack-read-rejection.v1",
           "stage" => stage,
           "path" => path,
           "unknown_keys" => unknown_keys
         } = rejection
       ) do
    map_size(rejection) == 4 and stage in @observed_rejection_stages and
      path in @observed_rejection_paths and is_list(unknown_keys) and
      length(unknown_keys) <= 16 and
      unknown_keys == unknown_keys |> Enum.uniq() |> Enum.sort() and
      Enum.all?(unknown_keys, &safe_observed_rejection_key?/1)
  end

  defp valid_observed_rejection?(_rejection), do: false

  defp safe_observed_rejection_key?(key) when is_binary(key) do
    byte_size(key) <= 64 and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, key) and
      not credential_key?(key)
  end

  defp safe_observed_rejection_key?(_key), do: false

  defp with_observed_rejection({:ok, _value} = result, _stage, _path), do: result

  defp with_observed_rejection({:error, _reason}, stage, path),
    do: {:error, observed_rejection(stage, path, [])}

  defp observed_required_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :unsafe_observed_page}, else: {:ok, value}
  end

  defp observed_required_string(_value), do: {:error, :unsafe_observed_page}

  defp observed_timestamp(value) do
    with {:ok, value} <- observed_required_string(value),
         true <- Regex.match?(~r/\A\d+\.\d{1,6}\z/, value) do
      {:ok, value}
    else
      _invalid -> {:error, :unsafe_observed_page}
    end
  end

  defp observed_text(nil), do: {:ok, ""}
  defp observed_text(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp observed_text(_value), do: {:error, :unsafe_observed_page}

  defp observed_optional_string(nil), do: {:ok, nil}
  defp observed_optional_string(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp observed_optional_string(_value), do: {:error, :unsafe_observed_page}

  defp observed_optional_provider_id(nil), do: {:ok, nil}

  defp observed_optional_provider_id(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or Regex.match?(~r/\A[A-Z0-9_]+\z/, value),
      do: {:ok, if(value == "", do: nil, else: value)},
      else: {:error, :unsafe_observed_page}
  end

  defp observed_optional_provider_id(_value), do: {:error, :unsafe_observed_page}

  defp observed_bot_profile(nil), do: {:ok, %{"name" => nil, "bot_id" => nil, "app_id" => nil}}

  defp observed_bot_profile(profile) when is_map(profile) do
    with :ok <-
           reject_observed_unknown_keys(
             Map.keys(profile) -- @observed_bot_profile_keys,
             "bot_profile_unknown_keys",
             "messages[].bot_profile"
           ),
         {:ok, name} <-
           with_observed_rejection(
             observed_optional_string(profile["name"]),
             "bot_profile_shape",
             "messages[].bot_profile"
           ),
         true <- is_nil(name) or safe_identity_label?(name),
         {:ok, bot_id} <-
           with_observed_rejection(
             observed_optional_provider_id(profile["id"]),
             "bot_profile_shape",
             "messages[].bot_profile"
           ),
         {:ok, app_id} <-
           with_observed_rejection(
             observed_optional_provider_id(profile["app_id"]),
             "bot_profile_shape",
             "messages[].bot_profile"
           ) do
      {:ok, %{"name" => name, "bot_id" => bot_id, "app_id" => app_id}}
    else
      {:error, %{} = rejection} ->
        {:error, rejection}

      _invalid ->
        {:error, observed_rejection("bot_profile_shape", "messages[].bot_profile", [])}
    end
  end

  defp observed_bot_profile(_profile),
    do: {:error, observed_rejection("bot_profile_shape", "messages[].bot_profile", [])}

  defp safe_identity_label?(value) do
    String.length(value) in 1..64 and not Regex.match?(~r/[\p{C}\r\n\t]/u, value) and
      not credential_shaped?(value) and not Regex.match?(~r/\A[ABCTUW][A-Z0-9_]{5,}\z/, value) and
      not String.contains?(value, ["@", "://", "/", "\\"])
  end

  defp observed_rich_text_mentions(nil), do: {:ok, []}

  defp observed_rich_text_mentions(blocks) when is_list(blocks) do
    with {:ok, mentions} <- collect_rich_text_mentions(blocks, []) do
      {:ok, mentions |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp observed_rich_text_mentions(_blocks),
    do: {:error, observed_rejection("rich_text_shape", "messages[].blocks", [])}

  defp collect_rich_text_mentions([], mentions), do: {:ok, mentions}

  defp collect_rich_text_mentions([value | rest], mentions) do
    with {:ok, mentions} <- collect_rich_text_mentions(value, mentions),
         {:ok, mentions} <- collect_rich_text_mentions(rest, mentions) do
      {:ok, mentions}
    end
  end

  defp collect_rich_text_mentions(%{"type" => "user", "user_id" => user_id} = element, mentions) do
    with :ok <-
           reject_observed_unknown_keys(
             Map.keys(element) -- ["type", "user_id", "style", "from_llm"],
             "rich_text_unknown_keys",
             "messages[].blocks[]"
           ),
         true <- is_nil(element["from_llm"]) or is_boolean(element["from_llm"]),
         {:ok, user_id} <-
           with_observed_rejection(
             observed_optional_provider_id(user_id),
             "rich_text_shape",
             "messages[].blocks[]"
           ),
         true <- not is_nil(user_id) do
      {:ok, [%{"type" => "user", "user_id" => user_id} | mentions]}
    else
      {:error, %{} = rejection} -> {:error, rejection}
      _invalid -> {:error, observed_rejection("rich_text_shape", "messages[].blocks[]", [])}
    end
  end

  defp collect_rich_text_mentions(%{"type" => type, "elements" => elements} = element, mentions)
       when type in @observed_rich_text_container_types and is_list(elements) do
    with :ok <-
           reject_observed_unknown_keys(
             Map.keys(element) -- observed_rich_text_container_keys(type),
             "rich_text_unknown_keys",
             "messages[].blocks[]"
           ),
         :ok <- observed_rich_text_container_shape(type, element) do
      collect_rich_text_mentions(elements, mentions)
    else
      {:error, %{} = rejection} -> {:error, rejection}
    end
  end

  defp collect_rich_text_mentions(%{"type" => type} = element, mentions)
       when type in @observed_rich_text_leaf_types do
    with :ok <-
           reject_observed_unknown_keys(
             Map.keys(element) -- observed_rich_text_leaf_keys(type),
             "rich_text_unknown_keys",
             "messages[].blocks[]"
           ),
         :ok <- observed_rich_text_leaf_shape(type, element) do
      {:ok, mentions}
    else
      {:error, %{} = rejection} -> {:error, rejection}
    end
  end

  defp collect_rich_text_mentions(%{"type" => type} = element, mentions)
       when type in @observed_display_only_block_types do
    with :ok <-
           reject_observed_unknown_keys(
             Map.keys(element) -- Map.fetch!(@observed_display_only_block_keys, type),
             "rich_text_unknown_keys",
             "messages[].blocks[]"
           ),
         :ok <- observed_display_only_block_shape(type, element) do
      {:ok, mentions}
    else
      {:error, %{} = rejection} -> {:error, rejection}
    end
  end

  defp collect_rich_text_mentions(_value, _mentions),
    do: {:error, observed_rejection("rich_text_shape", "messages[].blocks[]", [])}

  defp observed_rich_text_container_keys("rich_text_quote"),
    do: ~w(type elements block_id border indent offset style contains_padding)

  defp observed_rich_text_container_keys(_type),
    do: ~w(type elements block_id border indent offset style)

  # Slack's read response can attach this boolean layout hint to a quote even
  # though it is not part of the authored Block Kit payload. It is presentation
  # metadata: validate its type, then drop it before the canonical page.
  defp observed_rich_text_container_shape("rich_text_quote", element) do
    case Map.fetch(element, "contains_padding") do
      :error ->
        :ok

      {:ok, value} when is_boolean(value) ->
        :ok

      {:ok, _invalid} ->
        {:error, observed_rejection("rich_text_shape", "messages[].blocks[]", [])}
    end
  end

  defp observed_rich_text_container_shape(_type, _element), do: :ok

  defp observed_rich_text_leaf_keys("message_mention"),
    do: ~w(type author_id channel_id message_ts thread_ts text url)

  defp observed_rich_text_leaf_keys("link"),
    do:
      ~w(type text style name unicode url channel_id range trigger usergroup_id timestamp format fallback truncated from_llm is_slack_url unsafe)

  defp observed_rich_text_leaf_keys(_type),
    do:
      ~w(type text style name unicode url channel_id range trigger usergroup_id timestamp format fallback)

  defp observed_rich_text_leaf_shape("link", element) do
    valid? =
      Enum.all?(~w(truncated from_llm is_slack_url unsafe), fn key ->
        case Map.fetch(element, key) do
          :error -> true
          {:ok, value} -> is_boolean(value)
        end
      end)

    if valid?,
      do: :ok,
      else: {:error, observed_rejection("rich_text_shape", "messages[].blocks[]", [])}
  end

  defp observed_rich_text_leaf_shape(_type, _element), do: :ok

  defp observed_display_only_block_shape(type, element) do
    valid? =
      observed_optional_nonempty_string?(element["block_id"]) and
        observed_display_only_block_fields?(type, element)

    if valid?,
      do: :ok,
      else: {:error, observed_rejection("rich_text_shape", "messages[].blocks[]", [])}
  end

  defp observed_display_only_block_fields?("divider", _element), do: true

  defp observed_display_only_block_fields?("section", element) do
    (is_map(element["text"]) or observed_nonempty_list?(element["fields"])) and
      observed_optional_map?(element["accessory"]) and
      observed_optional_boolean?(element["expand"])
  end

  defp observed_display_only_block_fields?("header", element) do
    is_map(element["text"]) and
      (is_nil(element["level"]) or element["level"] in 1..4)
  end

  defp observed_display_only_block_fields?("markdown", element),
    do: observed_nonempty_string?(element["text"])

  defp observed_display_only_block_fields?("table", element) do
    observed_nonempty_list?(element["rows"]) and
      observed_optional_list?(element["column_settings"])
  end

  defp observed_display_only_block_fields?("actions", element),
    do: observed_nonempty_list?(element["elements"])

  defp observed_display_only_block_fields?("context", element),
    do: observed_nonempty_list?(element["elements"])

  defp observed_display_only_block_fields?("image", element) do
    (observed_nonempty_string?(element["image_url"]) and
       observed_nonempty_string?(element["alt_text"])) or
      is_map(element["slack_file"])
  end

  defp observed_display_only_block_fields?("card", element) do
    (is_map(element["hero_image"]) or is_map(element["title"]) or
       observed_nonempty_list?(element["actions"]) or is_map(element["body"])) and
      Enum.all?(~w(hero_image icon slack_icon title subtitle body), fn key ->
        observed_optional_map?(element[key])
      end) and
      observed_optional_list?(element["actions"]) and
      observed_optional_map?(element["subtext"])
  end

  defp observed_display_only_block_fields?("container", element) do
    observed_nonempty_string?(element["width"]) and is_map(element["title"]) and
      observed_nonempty_list?(element["child_blocks"]) and
      observed_optional_map?(element["subtitle"]) and
      observed_optional_boolean?(element["has_header_divider"])
  end

  defp observed_display_only_block_fields?("plan", element) do
    observed_nonempty_string?(element["title"]) and observed_nonempty_list?(element["tasks"])
  end

  defp observed_display_only_block_fields?("task_card", element) do
    observed_nonempty_string?(element["task_id"]) and
      observed_nonempty_string?(element["title"]) and
      element["status"] in ~w(pending in_progress complete error) and
      observed_optional_map?(element["details"]) and
      observed_optional_map?(element["output"]) and
      observed_optional_list?(element["sources"]) and
      observed_optional_map?(element["icon"]) and
      observed_optional_boolean?(element["hide_title"])
  end

  defp observed_nonempty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp observed_nonempty_string?(_value), do: false

  defp observed_optional_nonempty_string?(nil), do: true
  defp observed_optional_nonempty_string?(value), do: observed_nonempty_string?(value)

  defp observed_nonempty_list?(value) when is_list(value), do: value != []
  defp observed_nonempty_list?(_value), do: false

  defp observed_optional_list?(nil), do: true
  defp observed_optional_list?(value), do: is_list(value)

  defp observed_optional_map?(nil), do: true
  defp observed_optional_map?(value), do: is_map(value)

  defp observed_optional_boolean?(nil), do: true
  defp observed_optional_boolean?(value), do: is_boolean(value)

  defp reject_credential_material(value) do
    if credential_material?(value),
      do: {:error, observed_rejection("credential_material", "messages[]", [])},
      else: :ok
  end

  defp reject_observed_unknown_keys([], _stage, _path), do: :ok

  defp reject_observed_unknown_keys(keys, stage, path),
    do: {:error, observed_unknown_keys_rejection(keys, stage, path)}

  defp credential_material?(value) when is_map(value) do
    Enum.any?(value, fn {key, child} -> credential_key?(key) or credential_material?(child) end)
  end

  defp credential_material?(value) when is_list(value),
    do: Enum.any?(value, &credential_material?/1)

  defp credential_material?(value) when is_binary(value), do: credential_shaped?(value)
  defp credential_material?(_value), do: false

  defp credential_key?(key) when is_binary(key) do
    normalized = String.downcase(key)
    Enum.any?(@credential_key_fragments, &String.contains?(normalized, &1))
  end

  defp credential_key?(_key), do: true

  defp credential_shaped?(value) do
    Enum.any?(
      [
        ~r/\bBearer\s+\S+/i,
        ~r/\bxox[baprs]-[A-Za-z0-9-]+\b/i,
        ~r/\bsk-(?:live|test)-[A-Za-z0-9_-]+\b/i,
        ~r/\bsk-[A-Za-z0-9_-]{12,}\b/,
        ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
        ~r/\bAKIA[0-9A-Z]{16}\b/,
        ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
      ],
      &Regex.match?(&1, value)
    )
  end

  # ---- files (modern external upload flow) ----

  @doc "`files.getUploadURLExternal` (form: `filename`, `length`, optional `alt_txt`)."
  @spec get_upload_url_external(credential(), String.t(), pos_integer(), keyword()) :: map()
  def get_upload_url_external(token, filename, length, opts \\ []) do
    fields =
      [filename: filename, length: length]
      |> put_field(:alt_txt, opts[:alt_txt])

    post_form(token, "files.getUploadURLExternal", fields)
  end

  @doc """
  Multipart POST of the file bytes to the pre-signed upload URL (`file` field).

  The upload URL comes from `files.getUploadURLExternal` and already carries
  its own upload authorization, so this step must not attach the bot token.
  """
  @spec upload_to_url(String.t(), String.t(), binary()) :: :ok
  def upload_to_url(upload_url, filename, data) do
    case Req.post(upload_url,
           form_multipart: [file: {data, filename: filename}],
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status}} ->
        raise Error, message: "slack server error: #{status}", status: status

      {:error, reason} ->
        raise Error, message: "slack api request failed: #{inspect(reason)}"
    end
  end

  @doc """
  Streaming POST of file bytes to the pre-signed upload URL.

  Use this when the caller already has a fixed-length stream and must avoid
  buffering the whole file in memory. The upload URL comes from
  `files.getUploadURLExternal` and already carries its own upload authorization,
  so this step must not attach the bot token.
  """
  @spec upload_stream_to_url(String.t(), Enumerable.t(), non_neg_integer()) :: :ok
  def upload_stream_to_url(upload_url, stream, size) do
    case Req.post(upload_url,
           body: stream,
           headers: [
             {"content-type", "application/octet-stream"},
             {"content-length", Integer.to_string(size)}
           ],
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        raise Error, message: "slack server error: #{status}", body: body, status: status

      {:error, reason} ->
        raise Error, message: "slack api request failed: #{inspect(reason)}"
    end
  end

  @doc """
  `files.completeUploadExternal`. `files` is a list of
  `%{"id" => ..., "title" => ...}` maps (JSON-encoded into the form).
  `opts`: `:channel` (form `channel_id`), `:initial_comment`, `:thread_ts`.
  Returns the decoded response (`"files"`).
  """
  @spec complete_upload_external(credential(), [map()], keyword()) :: map()
  def complete_upload_external(token, files, opts \\ []) do
    fields =
      [files: Jason.encode!(files)]
      |> put_field(:channel_id, opts[:channel])
      |> put_field(:initial_comment, opts[:initial_comment])
      |> put_field(:thread_ts, opts[:thread_ts])

    post_form(token, "files.completeUploadExternal", fields)
  end

  @doc "`files.info`. Returns the `\"file\"` map (permalink / title / url_private_download)."
  @spec file_info(credential(), String.t()) :: map()
  def file_info(token, file_id) do
    token
    |> post_form("files.info", file: file_id)
    |> Map.get("file", %{})
  end

  @doc """
  `files.list` for Canvases. `:channel` narrows to a channel's Canvases; omit it
  to list the token's Canvases. `:count`, `:page`, `:ts_from`, `:ts_to`, and
  `:user` are optional.

  Slack does not publish an Elixir SDK, and this application already isolates
  its Slack protocol behind this Req adapter, so extending the adapter keeps
  auth, error shaping, and test seams in one replaceable boundary.
  """
  @spec list_canvases(credential(), keyword()) :: map()
  def list_canvases(token, opts \\ []) do
    fields =
      [types: "canvas"]
      |> put_field(:channel, opts[:channel])
      |> put_field(:count, opts[:count] || 100)
      |> put_field(:page, opts[:page] || 1)
      |> put_field(:ts_from, opts[:ts_from])
      |> put_field(:ts_to, opts[:ts_to])
      |> put_field(:user, opts[:user])

    get_query(token, "files.list", fields)
  end

  @doc """
  Authenticated raw GET (canvas / file downloads — slack-go's `GetFile`).
  Returns the body binary; raises `Error` on any non-200.
  """
  @spec get_file!(credential(), String.t()) :: binary()
  def get_file!(token, url) do
    case Req.get(url, headers: auth(token), retry: false, decode_body: false) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        body

      {:ok, %{status: 429, body: body} = response} ->
        retry_after = retry_after(response, body)

        raise Error,
          message: "slack rate limit exceeded, retry after #{retry_after}s",
          retry_after: retry_after,
          body: body,
          status: 429

      {:ok, %{status: status}} ->
        raise Error, message: "slack file download failed: #{status}", status: status

      {:error, reason} ->
        raise Error, message: "slack api request failed: #{inspect(reason)}"
    end
  end

  @doc """
  Authenticated raw streaming GET for Slack file downloads.

  This keeps Slack file HTTP/auth behavior in the Slack API helper while
  allowing callers such as `SalixIM.SlackFiles` to own their destination stream.
  """
  @spec stream_file(credential(), String.t(), function()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def stream_file(token, url, into, opts \\ []) when is_function(into, 2) do
    Req.get(url, [headers: auth(token), retry: false, decode_body: false, into: into] ++ opts)
  end

  # ---- canvases ----

  @doc "`canvases.create` (form: `title`, `document_content` JSON). Returns the `\"canvas_id\"`."
  @spec create_canvas(credential(), String.t(), String.t()) :: String.t()
  def create_canvas(token, title, markdown) do
    fields =
      []
      |> put_field(:title, title)
      |> put_json(:document_content, document_content(markdown))

    token
    |> post_form("canvases.create", fields)
    |> Map.get("canvas_id", "")
  end

  @typedoc "The exact supported values are `\"channel_ids\"` and `\"user_ids\"`."
  @type canvas_access_target_type :: String.t()

  @doc """
  `canvases.access.set` for a nonempty list of channel or user targets.

  Slack's form contract accepts exactly one of `channel_ids` or `user_ids` as
  a comma-separated string. `access_level` defaults to `"write"`.
  """
  @spec set_canvas_access(
          credential(),
          credential(),
          String.t(),
          [String.t(), ...] | String.t()
        ) :: map()
  def set_canvas_access(token, canvas_id, target_type, [_ | _] = target_ids)
      when target_type in ["channel_ids", "user_ids"] do
    set_canvas_access(token, canvas_id, target_type, target_ids, "write")
  end

  def set_canvas_access(token, canvas_id, channel, access_level)
      when is_binary(channel) and is_binary(access_level) do
    set_canvas_access(token, canvas_id, "channel_ids", [channel], access_level)
  end

  @spec set_canvas_access(
          String.t(),
          String.t(),
          canvas_access_target_type(),
          [String.t(), ...],
          String.t()
        ) :: map()
  def set_canvas_access(token, canvas_id, target_type, [_ | _] = target_ids, access_level)
      when target_type in ["channel_ids", "user_ids"] and is_binary(access_level) do
    target_field =
      case target_type do
        "channel_ids" -> :channel_ids
        "user_ids" -> :user_ids
      end

    post_form(token, "canvases.access.set", [
      {:canvas_id, canvas_id},
      {:access_level, access_level},
      {target_field, Enum.join(target_ids, ",")}
    ])
  end

  @doc false
  @spec set_canvas_access(credential(), String.t(), String.t()) :: map()
  def set_canvas_access(token, canvas_id, channel) when is_binary(channel) do
    set_canvas_access(token, canvas_id, "channel_ids", [channel], "write")
  end

  @doc "`canvases.edit` (form: `canvas_id`, `changes` JSON list)."
  @spec edit_canvas(credential(), String.t(), [map()]) :: map()
  def edit_canvas(token, canvas_id, changes) when is_list(changes) do
    post_form(token, "canvases.edit", canvas_id: canvas_id, changes: Jason.encode!(changes))
  end

  @doc "Rename a Canvas through the idempotent `canvases.edit` rename operation."
  @spec rename_canvas(credential(), String.t(), String.t()) :: map()
  def rename_canvas(token, canvas_id, title) do
    edit_canvas(token, canvas_id, [
      %{
        "operation" => "rename",
        "title_content" => %{"type" => "markdown", "markdown" => title}
      }
    ])
  end

  @doc """
  Read a Canvas file and its provider-rendered body in one Slack helper call.

  Slack accepts Markdown when creating a Canvas, but the private download URL
  returns rendered Quip HTML. Callers must not compare those representations
  byte-for-byte.
  """
  @spec canvas_file_and_content(credential(), String.t()) :: {map(), binary()}
  def canvas_file_and_content(token, canvas_id) do
    file = file_info(token, canvas_id)
    content = download_canvas_content!(token, canvas_id, file)
    {file, content}
  end

  @deprecated "Use canvas_file_and_content/2; Slack downloads are rendered HTML, not Markdown"
  @spec canvas_file_and_markdown(credential(), String.t()) :: {map(), binary()}
  def canvas_file_and_markdown(token, canvas_id), do: canvas_file_and_content(token, canvas_id)

  defp download_canvas_content!(token, canvas_id, file) do
    case file["url_private_download"] || file["url_private"] || "" do
      "" -> raise Error, message: "canvas #{canvas_id} has no downloadable content"
      url -> get_file!(token, rebase_files_url(url))
    end
  end

  # willow downloaded from the hardcoded files host; we rebase onto
  # `files_base_url/0` (default `https://files.slack.com`, overridable for tests)
  # while keeping Slack's signed path and query intact.
  defp rebase_files_url(url) do
    uri = URI.parse(url)
    base = URI.parse(files_base_url())
    URI.to_string(%{uri | scheme: base.scheme, host: base.host, port: base.port, authority: nil})
  end

  defp files_base_url,
    do: configured_base(:slack_files_base_url, "https://files.slack.com")

  # ---- users / emoji / bookmarks ----

  @doc "`users.info`. Returns the `\"user\"` map."
  @spec user_info(credential(), String.t()) :: map()
  def user_info(token, user_id) do
    token
    |> post_form("users.info", user: user_id)
    |> Map.get("user", %{})
  end

  # ---- core transport ----

  defp post_form(token, method, fields), do: request_form(token, method, fields)

  @doc "Read the exact message's complete reaction list for provider effect recovery."
  def message_reactions(credential, channel, timestamp, request_opts \\ []) do
    get_query(
      credential,
      "reactions.get",
      [channel: channel, timestamp: timestamp, full: true],
      request_opts
    )
  end

  defp get_query(token, method, fields, request_opts \\ []) do
    request(:get, token, method, fields, request_opts)
  end

  defp post_form_without_auth(method, fields), do: request(:post, nil, method, fields)

  defp request(verb, credential, method, fields, opts \\ []),
    do: request_with_response(verb, credential, method, fields, opts) |> elem(0)

  defp request_with_response(verb, credential, method, fields, opts \\ []) do
    retry_rate_limited_request(fn ->
      request_once_with_response(verb, credential, method, fields, opts)
    end)
  end

  defp request_once_with_response(verb, credential, method, fields, opts) do
    fields =
      Enum.reject(fields, fn {key, value} ->
        value in [nil, ""] and key not in Keyword.get(opts, :keep_empty_keys, [])
      end)

    do_request(verb, auth(credential), method, fields, opts)
  end

  defp retry_rate_limited_request(fun) do
    fun.()
  rescue
    error in Error ->
      case reserve_tool_rate_limit_retry(error) do
        {:retry, delay_ms} ->
          Process.sleep(delay_ms)

          if tool_rate_limit_retry_deadline_open?() do
            emit_tool_rate_limit_retry("ok", delay_ms)
            retry_rate_limited_request(fun)
          else
            emit_tool_rate_limit_retry("over_budget", 0)
            reraise error, __STACKTRACE__
          end

        :over_budget ->
          emit_tool_rate_limit_retry("over_budget", 0)
          reraise error, __STACKTRACE__

        :not_retryable ->
          reraise error, __STACKTRACE__
      end
  end

  defp reserve_tool_rate_limit_retry(%Error{retry_after: seconds})
       when is_integer(seconds) and seconds >= 0 do
    case Process.get(@tool_rate_limit_retry_key) do
      %{deadline_ms: deadline_ms, retries_left: retries_left} = policy
      when is_integer(deadline_ms) and is_integer(retries_left) ->
        delay_ms = seconds * 1_000
        remaining_ms = deadline_ms - System.monotonic_time(:millisecond)

        if retries_left > 0 and
             delay_ms + @tool_rate_limit_final_attempt_ms <= remaining_ms do
          Process.put(@tool_rate_limit_retry_key, %{policy | retries_left: retries_left - 1})
          {:retry, delay_ms}
        else
          :over_budget
        end

      _no_tool_retry_scope ->
        :not_retryable
    end
  end

  defp reserve_tool_rate_limit_retry(_error), do: :not_retryable

  defp tool_rate_limit_retry_deadline_open? do
    case Process.get(@tool_rate_limit_retry_key) do
      %{deadline_ms: deadline_ms} when is_integer(deadline_ms) ->
        System.monotonic_time(:millisecond) < deadline_ms

      _no_tool_retry_scope ->
        false
    end
  end

  defp emit_tool_rate_limit_retry(outcome, delay_ms) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: System.convert_time_unit(delay_ms, :millisecond, :native)},
      %{
        component: "salix_im",
        operation: "slack_api_retry",
        surface: "salix",
        outcome: outcome
      }
    )

    :ok
  end

  defp do_request(verb, headers, method, fields, opts) do
    pool_retries = Keyword.get(opts, :pool_retries, 1)

    response =
      apply(Req, verb, [web_api_url(method), request_options(verb, headers, fields, opts)])

    case response do
      {:ok, %{status: 429, body: body} = resp} ->
        retry_after = retry_after(resp, body)

        raise Error,
          message: "slack rate limit exceeded, retry after #{retry_after}s",
          retry_after: retry_after,
          body: body,
          status: 429

      {:ok, %{status: status, body: %{"ok" => true} = body} = response}
      when status in 200..299 ->
        {body, response}

      {:ok, %{status: status, body: %{"ok" => false} = body}} when status in 200..299 ->
        raise Error, message: to_string(body["error"] || "unknown_error"), body: body

      {:ok, %{status: status}} ->
        raise Error, message: "slack server error: #{status}", status: status

      {:error, %Req.HTTPError{reason: :pool_not_available}} when pool_retries > 0 ->
        Process.sleep(25)

        do_request(
          verb,
          headers,
          method,
          fields,
          Keyword.put(opts, :pool_retries, pool_retries - 1)
        )

      {:error, reason} ->
        raise Error, message: "slack api request failed: #{inspect(reason)}"
    end
  end

  defp request_options(verb, headers, fields, opts) do
    options =
      [headers: headers, retry: false]
      |> Keyword.put(if(verb == :get, do: :params, else: :form), fields)

    case effective_request_timeout_ms(opts) do
      timeout when is_integer(timeout) and timeout > 0 ->
        options
        |> Keyword.put(:pool_timeout, timeout)
        |> Keyword.put(:receive_timeout, timeout)
        |> Keyword.put(:connect_options, timeout: timeout)

      _ ->
        options
    end
  end

  defp effective_request_timeout_ms(opts) do
    configured = Keyword.get(opts, :timeout_ms)

    remaining =
      case Process.get(@tool_rate_limit_retry_key) do
        %{deadline_ms: deadline_ms} when is_integer(deadline_ms) ->
          max(deadline_ms - System.monotonic_time(:millisecond), 1)

        _no_tool_retry_scope ->
          nil
      end

    case {configured, remaining} do
      {timeout, remaining} when is_integer(timeout) and timeout > 0 and is_integer(remaining) ->
        min(timeout, remaining)

      {timeout, _remaining} when is_integer(timeout) and timeout > 0 ->
        timeout

      {_configured, remaining} when is_integer(remaining) ->
        remaining

      _ ->
        nil
    end
  end

  defp tool_rate_limit_retry_budget_ms do
    case Application.get_env(
           :salix_im,
           :slack_tool_rate_limit_retry_budget_ms,
           @default_tool_rate_limit_retry_budget_ms
         ) do
      value when is_integer(value) and value >= 0 ->
        min(value, @max_tool_rate_limit_retry_budget_ms)

      _invalid ->
        @default_tool_rate_limit_retry_budget_ms
    end
  end

  defp tool_rate_limit_max_retries do
    case Application.get_env(
           :salix_im,
           :slack_tool_rate_limit_max_retries,
           @default_tool_rate_limit_max_retries
         ) do
      value when is_integer(value) and value >= 0 ->
        min(value, @max_tool_rate_limit_max_retries)

      _invalid ->
        @default_tool_rate_limit_max_retries
    end
  end

  defp web_api_url(method), do: "#{base_url()}/#{method}"

  defp response_date_ms(response) do
    with [date | _] <- Req.Response.get_header(response, "date"),
         {{year, month, day}, {hour, minute, second}} <-
           :httpd_util.convert_request_date(String.to_charlist(date)),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      DateTime.to_unix(datetime, :millisecond)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp auth(token) when is_binary(token), do: [{"authorization", "Bearer #{token}"}]
  defp auth(_credential), do: []

  defp provider_error_message("missing_scope", body) do
    needed = body["needed"] || body["needed_scope"] || ""

    if needed == "",
      do: "Slack API error: missing_scope. The Slack app may need additional OAuth scopes.",
      else: "Slack API error: missing_scope; needed=#{needed}"
  end

  defp provider_error_message("ratelimited", body), do: provider_rate_limited_message(body)
  defp provider_error_message(error, _body), do: "Slack API error: #{error}"

  defp provider_rate_limited_message(body) do
    retry_after = provider_body_retry_after(body)

    if retry_after = presence(to_string(retry_after || "")) do
      "Slack API error: rate_limited; retry_after=#{retry_after}"
    else
      "Slack API error: rate_limited"
    end
  end

  defp provider_body_retry_after(%{} = body), do: body["retry_after"]
  defp provider_body_retry_after(_body), do: nil

  defp configured_base(key, default) do
    base =
      :salix_im
      |> Application.get_env(key, default)
      |> to_string()
      |> String.trim()

    base
    |> blank_default(default)
    |> String.trim_trailing("/")
  end

  defp blank_default("", default), do: default
  defp blank_default(value, _default), do: value

  defp presence(""), do: nil
  defp presence(value), do: value

  defp retry_after(resp, body) do
    case Req.Response.get_header(resp, "retry-after") do
      [secs | _] ->
        case Integer.parse(secs) do
          {n, _} -> n
          :error -> body_retry_after(body)
        end

      [] ->
        body_retry_after(body)
    end
  end

  defp body_retry_after(%{"retry_after" => value}) when is_integer(value), do: value

  defp body_retry_after(%{"retry_after" => value}) do
    case Integer.parse(to_string(value)) do
      {n, _} -> n
      :error -> 1
    end
  end

  defp body_retry_after(_body), do: 1

  defp document_content(markdown), do: %{"type" => "markdown", "markdown" => markdown}

  defp put_field(fields, _key, nil), do: fields
  defp put_field(fields, _key, ""), do: fields
  defp put_field(fields, key, value), do: fields ++ [{key, value}]

  defp put_json(fields, _key, nil), do: fields
  defp put_json(fields, _key, []), do: fields
  defp put_json(fields, key, value), do: fields ++ [{key, Jason.encode!(value)}]

  defp encode_bool(nil), do: nil
  defp encode_bool(b) when is_boolean(b), do: to_string(b)
end
