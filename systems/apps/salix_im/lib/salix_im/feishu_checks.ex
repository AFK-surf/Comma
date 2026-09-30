defmodule SalixIM.FeishuChecks do
  @moduledoc """
  On-demand Feishu setup verification probes used by the BridgeForTeams
  run-checks surface. The probe contract and evidence policy are documented in
  `docs/bridge-for-teams/design.md` §6 and §9.

  `callback_preflight/1` POSTs a synthetic **official Feishu callback envelope**
  to a connect's webhook/event URL and asserts the `challenge` round-trips. It is
  the orchestration previously inlined in
  `scripts/bridge_tob_feishu_live_smoke.exs`, lifted into `salix_im` so the
  BridgeForTeams Run-checks surface can call it over erpc.

  Fidelity matters (RFC §6.2): when an `encrypt_key` is configured the envelope is
  AES-256-CBC encrypted with a **random 16-byte IV** prepended to the ciphertext —
  the official Feishu wire format — *not* a fixed IV. A fixed-IV preflight passes
  the runtime's own decryptor while the real Feishu URL verification (random IV)
  returns 401, i.e. a false-green. Sending the official envelope makes the probe
  fail honestly (`:encrypted_unsupported`) when the runtime cannot yet decrypt the
  official format, instead of pretending the callback is healthy.

  Reuses the AES/signature primitives that mirror
  `SalixIM.ProviderHTTP`'s Feishu envelope handling rather than inventing new
  crypto.

  Returns `{:ok, evidence_map}` or `{:error, reason_class}` where `reason_class`
  is one of `:token_mismatch | :decrypt_signature | :callback_unreachable |
  :encrypted_unsupported`. The evidence map is redaction-safe (RFC §9): it carries
  status/class/challenge-mode but never raw secrets, signatures, or message
  bodies.

  ## Connect-aware paths

  `callback_preflight_for_connect/1` and `first_message/1` are **connect-aware**:
  the caller (BridgeForTeams over erpc) passes an identity only (`connect_id`),
  and this module resolves the bot secrets **inside Salix** from the tenant
  Feishu app store keyed by `tenant_id`. Connect records carry identity and
  webhook status, not bot secrets.

  Tenant app lookup and agent delivery go through SalixIM ports.
  """

  alias SalixIM.Ports.{AgentDelivery, ProviderAppStore}
  alias SalixIM.{GroupDirectory, ProviderConnects}

  # Bound the in-Salix reply poll UNDER the BFT erpc budget (erpc default 15_000ms
  # + 5_000ms = 20_000ms wall). A slow LLM must surface as :no_assistant_reply,
  # not a transport :timeout — the BFT call site passes an elevated `timeout:` so
  # this poll always completes first.
  @reply_poll_timeout_ms 12_000
  @reply_poll_interval_ms 500

  @doc """
  Resolve and verify the Feishu bot identity attached to a connect.

  Group-message routing must match Feishu @-mentions by the bot's `open_id`.
  A connect with no `bot_open_id` is not safe to treat as ready: falling back to
  a mutable display name can make real Feishu callbacks return HTTP 200 while
  the message is silently ignored before router enqueue.

  Returns `{:ok, redacted_evidence}` with a short fingerprint when the identity
  exists, otherwise `{:error, :bot_identity_missing}`.
  """
  @spec bot_identity(map()) :: {:ok, map()} | {:error, atom()}
  def bot_identity(params) when is_map(params) do
    with {:ok, connect} <- find_connect(trim(get(params, "connect_id"))),
         :ok <- ensure_connect_active(connect),
         :ok <- ensure_feishu_connect(connect) do
      case trim(connect["bot_open_id"]) do
        "" ->
          {:error, :bot_identity_missing}

        open_id ->
          {:ok,
           %{
             "ok" => true,
             "redacted" => true,
             "identity" => "feishu_bot_open_id",
             "open_id_fingerprint" => fingerprint(open_id),
             "app_id" => trim(connect["app_id"]),
             "connect_id" => trim(connect["connect_id"]),
             "checked_at" =>
               DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
           }}
      end
    end
  end

  @doc """
  Run the callback preflight against a Feishu connect's webhook/event URL.

  `params` keys (string or atom):

    * `"webhook_url"` — target URL; defaults to the deployment's public
      `/v1/im/feishu/events` endpoint.
    * `"app_id"` — appended as a query param so the runtime can resolve the
      active connect.
    * `"verification_token"` — placed in the envelope header `token`; lets the
      runtime detect a token mismatch.
    * `"encrypt_key"` — when non-blank, the envelope is AES-encrypted with a
      random 16-byte IV (official wire format); when blank, a plain
      `url_verification` challenge is sent.

  Returns `{:ok, evidence}` when the challenge round-trips, otherwise
  `{:error, reason_class}`.
  """
  @spec callback_preflight(map()) :: {:ok, map()} | {:error, atom()}
  def callback_preflight(params) when is_map(params) do
    webhook_url = resolve_webhook_url(params)
    encrypt_key = trim(get(params, "encrypt_key"))
    verification_token = trim(get(params, "verification_token"))
    encrypted? = encrypt_key != ""
    challenge = "feishu_preflight_" <> nonce()

    {raw, signing_secret} =
      build_callback_request(challenge, verification_token, encrypt_key, encrypted?)

    timestamp = Integer.to_string(System.system_time(:second))
    request_nonce = nonce()
    signature = feishu_signature(timestamp, request_nonce, signing_secret, raw)

    headers =
      [{"content-type", "application/json"}]
      |> maybe_signature_headers(signing_secret, timestamp, request_nonce, signature)

    case post(webhook_url, headers, raw) do
      {:ok, status, body} ->
        evidence = base_evidence(encrypted?, status)

        if challenge_round_trips?(status, body, challenge) do
          {:ok, Map.put(evidence, "ok", true)}
        else
          {:error, classify_failure(status, body, encrypted?)}
        end

      {:error, :unreachable} ->
        {:error, :callback_unreachable}
    end
  end

  @doc """
  Connect-aware callback preflight.

  Resolves the connect + its bot secrets **inside Salix** from a `connect_id`
  identity (never from params), then runs the existing `callback_preflight/1`
  logic against the connect's real webhook URL.

  `params` keys (string or atom):

    * `"connect_id"` — the active Feishu connect to verify (required).

  Returns `{:ok, evidence}` when the challenge round-trips, otherwise
  `{:error, reason_class}` where `reason_class` adds the fail-closed resolution
  classes `:connect_not_found | :connect_inactive | :secrets_not_configured`
  to the `callback_preflight/1` taxonomy.
  """
  @spec callback_preflight_for_connect(map()) :: {:ok, map()} | {:error, atom()}
  def callback_preflight_for_connect(params) when is_map(params) do
    with {:ok, connect, secrets} <- resolve_connect_secrets(params) do
      callback_preflight(%{
        "webhook_url" => connect["webhook_url"],
        "app_id" => connect["app_id"],
        "verification_token" => secrets.verification_token,
        "encrypt_key" => secrets.encrypt_key
      })
    end
  end

  @doc """
  First-message smoke for an active Feishu connect.

  Connect-aware: takes a `connect_id` identity, resolves the connect's router
  agent + bot secrets inside Salix, delivers ONE synthetic @Bridge user message
  to the canonical group router session, then polls that session for an
  assistant reply to confirm the first-message round-trip works.

  Router agents have exactly one canonical session per group, so this smoke is a
  normal router notification rather than a separate runtime session. Each run
  uses a fresh nonce'd `source_message_id` so the agent-delivery dedupe never
  returns a stale session. The reply poll is bounded under the erpc budget so a
  slow LLM surfaces as `:no_assistant_reply` rather than a transport `:timeout`.

  `params` keys (string or atom):

    * `"connect_id"` — the active Feishu connect to smoke-test (required).

  Returns `{:ok, redacted_evidence}` when an assistant reply round-trips,
  otherwise `{:error, reason_class}` where `reason_class` is one of
  `:connect_not_found | :connect_inactive | :secrets_not_configured |
  :router_not_configured | :no_assistant_reply | :callback_unreachable |
  :token_mismatch | :decrypt_signature | :timeout`.
  """
  @spec first_message(map()) :: {:ok, map()} | {:error, atom()}
  def first_message(params) when is_map(params) do
    with {:ok, connect, _secrets} <- resolve_connect_secrets(params),
         {:ok, router_agent_id} <- resolve_router_agent(connect),
         {:ok, session_id} <-
           ProviderConnects.agent_group_router_session_id(
             router_agent_id,
             connect["group_id"]
           ),
         content = "@Bridge first-message smoke ping " <> nonce(),
         metadata = %{
           "provider" => "feishu",
           "connect_id" => connect["connect_id"],
           "check_kind" => "first_message_smoke"
         } do
      source_message_id = "im_smoke:feishu:#{connect["connect_id"]}:" <> nonce()

      baseline = assistant_count(router_agent_id, session_id)

      case ProviderConnects.enqueue_group_router_im_provider_message(
             connect["group_id"],
             content,
             metadata,
             source_message_id
           ) do
        {:ok, :queued} ->
          poll_for_reply(router_agent_id, session_id, baseline)

        {:error, _reason} ->
          {:error, :callback_unreachable}
      end
    end
  end

  # ---- connect-aware secret resolution (private) ----

  # Resolve the connect (fail closed) then its bot secrets from the tenant app
  # store. Returns
  # `{:ok, connect_record, %{verification_token, encrypt_key}}`.
  @spec resolve_connect_secrets(map()) ::
          {:ok, map(), %{verification_token: binary(), encrypt_key: binary()}} | {:error, atom()}
  defp resolve_connect_secrets(params) do
    connect_id = trim(get(params, "connect_id"))

    with {:ok, connect} <- find_connect(connect_id),
         :ok <- ensure_connect_active(connect),
         :ok <- ensure_feishu_connect(connect),
         {:ok, secrets} <- resolve_bot_secrets(connect) do
      {:ok, connect, secrets}
    end
  end

  defp find_connect(""), do: {:error, :connect_not_found}

  defp find_connect(connect_id) do
    case ProviderConnects.find_active_im_connect_by_id(connect_id) do
      {:ok, connect} -> {:ok, connect}
      {:error, _} -> {:error, :connect_not_found}
    end
  end

  # `find_active_im_connect_by_id/1` already excludes deleted/disabled; assert the
  # connected status so an in-flight/errored connect fails closed.
  defp ensure_connect_active(connect) do
    if trim(connect["status"]) == "connected", do: :ok, else: {:error, :connect_inactive}
  end

  defp ensure_feishu_connect(connect) do
    if trim(connect["provider"]) == "feishu", do: :ok, else: {:error, :connect_not_found}
  end

  # The tenant Feishu app store is the only source of Feishu bot secrets.
  # Connect records intentionally do not carry verification_token/encrypt_key.
  defp resolve_bot_secrets(connect) do
    with {:ok, secrets} <- tenant_app_secrets(trim(connect["tenant_id"])),
         :ok <- ensure_app_match(connect, secrets),
         :ok <- ensure_secret_material(secrets) do
      {:ok, secrets}
    end
  end

  defp tenant_app_secrets(""), do: {:error, :secrets_not_configured}

  defp tenant_app_secrets(tenant_id) do
    case ProviderAppStore.get_feishu_tenant_app(tenant_id) do
      {:ok, app} ->
        {:ok,
         %{
           app_id: trim(app["app_id"]),
           verification_token: trim(app["verification_token"]),
           encrypt_key: trim(app["encrypt_key"])
         }}

      _ ->
        {:error, :secrets_not_configured}
    end
  end

  defp ensure_secret_material(%{verification_token: "", encrypt_key: ""}),
    do: {:error, :secrets_not_configured}

  defp ensure_secret_material(_secrets), do: :ok

  defp ensure_app_match(_connect, %{app_id: ""}), do: :ok

  defp ensure_app_match(connect, %{app_id: app_id}) do
    if app_id == trim(connect["app_id"]),
      do: :ok,
      else: {:error, :secrets_not_configured}
  end

  # ---- router agent resolution (RFC §6.1; mirrors the live-smoke 0/1/many) ----

  # Reproduce `derive_router_agent_from_connect_group/1`'s 0/1/many handling: pick
  # the single router agent for the connect's group; on many, pick the most
  # recently updated; on none, fail closed `:router_not_configured`.
  defp resolve_router_agent(connect) do
    group_id = trim(connect["group_id"])

    if group_id == "" do
      {:error, :router_not_configured}
    else
      group_id
      |> GroupDirectory.list_group_agents()
      |> case do
        {:ok, agents} -> agents
        {:error, _} -> []
      end
      |> Enum.filter(fn agent ->
        trim(agent["role"]) == "router"
      end)
      |> case do
        [] ->
          {:error, :router_not_configured}

        [agent] ->
          router_agent_id(agent)

        matches ->
          # Many router agents for one group — pick the freshest, mirroring the
          # live-smoke tie-break, so the smoke targets the active session.
          matches
          |> Enum.max_by(&(&1["updated_at"] || &1["created_at"] || ""), fn -> nil end)
          |> router_agent_id()
      end
    end
  end

  defp router_agent_id(nil), do: {:error, :router_not_configured}

  defp router_agent_id(agent) do
    case trim(agent["id"] || agent["agent_id"]) do
      "" -> {:error, :router_not_configured}
      id -> {:ok, id}
    end
  end

  # ---- reply poll (RFC §6.1; bounded UNDER the erpc budget) ----

  defp assistant_count(router_agent_id, session_id) do
    case AgentDelivery.get_session_messages(router_agent_id, session_id) do
      {:ok, session} -> session |> session_messages() |> Enum.count(&assistant_message?/1)
      {:error, _} -> 0
    end
  end

  defp poll_for_reply(router_agent_id, session_id, baseline) do
    deadline = System.monotonic_time(:millisecond) + @reply_poll_timeout_ms
    do_poll_for_reply(router_agent_id, session_id, baseline, deadline)
  end

  defp do_poll_for_reply(router_agent_id, session_id, baseline, deadline) do
    case AgentDelivery.get_session_messages(router_agent_id, session_id) do
      {:ok, session} ->
        messages = session_messages(session)

        if Enum.count(messages, &assistant_message?/1) > baseline do
          {:ok, reply_evidence(session_id, messages)}
        else
          continue_or_timeout(router_agent_id, session_id, baseline, deadline)
        end

      {:error, _reason} ->
        continue_or_timeout(router_agent_id, session_id, baseline, deadline)
    end
  end

  defp continue_or_timeout(router_agent_id, session_id, baseline, deadline) do
    if System.monotonic_time(:millisecond) + @reply_poll_interval_ms < deadline do
      Process.sleep(@reply_poll_interval_ms)
      do_poll_for_reply(router_agent_id, session_id, baseline, deadline)
    else
      {:error, :no_assistant_reply}
    end
  end

  defp session_messages(session) do
    Map.get(session, :messages) || Map.get(session, "messages") || []
  end

  defp assistant_message?(message) do
    trim(Map.get(message, :role) || Map.get(message, "role")) == "assistant"
  end

  # Redaction-safe evidence (RFC §9): session prefix + counts + mode, never raw
  # session ids, message bodies, or secrets.
  defp reply_evidence(session_id, messages) do
    %{
      "ok" => true,
      "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "check_kind" => "first_message_smoke",
      "session_id_prefix" => String.slice(to_string(session_id), 0, 12),
      "message_count" => length(messages),
      "assistant_reply" => true,
      "redacted" => true
    }
  end

  # ---- pure classification helpers (unit-tested) ----

  @doc false
  # Maps a webhook response (HTTP status + decoded body) to a `reason_class` when
  # the challenge did not round-trip. `encrypted?` disambiguates a
  # signature/decrypt 401 between a plain-mode signature failure and an encrypted
  # callback failure. The latter keeps the historical `:encrypted_unsupported`
  # reason for old deployments and setup guidance; current runtimes support the
  # official random-IV envelope (RFC §6.2 / former COMMA-27 dependency).
  @spec classify_failure(non_neg_integer(), map() | binary() | nil, boolean()) :: atom()
  def classify_failure(status, body, encrypted?)

  def classify_failure(401, body, encrypted?) do
    cond do
      error_mentions?(body, "token") -> :token_mismatch
      encrypted? -> :encrypted_unsupported
      true -> :decrypt_signature
    end
  end

  def classify_failure(404, _body, _encrypted?), do: :callback_unreachable

  def classify_failure(status, _body, _encrypted?) when status in 500..599,
    do: :callback_unreachable

  # A 200 that did not round-trip the challenge: the encrypted envelope was
  # accepted but silently failed to decrypt into a usable challenge.
  def classify_failure(_status, _body, true), do: :encrypted_unsupported
  def classify_failure(_status, _body, false), do: :decrypt_signature

  @doc false
  # `true` when the runtime echoed the exact challenge we sent (URL verification
  # success).
  @spec challenge_round_trips?(non_neg_integer(), map() | binary() | nil, binary()) :: boolean()
  def challenge_round_trips?(200, %{"challenge" => echoed}, challenge)
      when is_binary(echoed),
      do: echoed == challenge

  def challenge_round_trips?(_status, _body, _challenge), do: false

  @doc false
  # Whether the runtime error body names a given failure cause (e.g. "token",
  # "signature"). Tolerant of decoded maps and raw strings.
  @spec error_mentions?(map() | binary() | nil, binary()) :: boolean()
  def error_mentions?(%{"error" => error}, needle) when is_binary(error),
    do: String.contains?(error, needle)

  def error_mentions?(body, needle) when is_binary(body),
    do: String.contains?(body, needle)

  def error_mentions?(_body, _needle), do: false

  # ---- envelope construction ----

  defp build_callback_request(challenge, verification_token, _encrypt_key, false) do
    plain =
      Jason.encode!(%{
        "type" => "url_verification",
        "challenge" => challenge,
        "token" => verification_token
      })

    {plain, verification_token}
  end

  defp build_callback_request(challenge, verification_token, encrypt_key, true) do
    plain =
      Jason.encode!(%{
        "type" => "url_verification",
        "challenge" => challenge,
        "token" => verification_token
      })

    raw = Jason.encode!(%{"encrypt" => feishu_encrypt(plain, encrypt_key)})
    {raw, encrypt_key}
  end

  # Official Feishu wire format: base64(iv ++ AES-256-CBC(key, iv, pkcs7(plain)))
  # with key = SHA256(encrypt_key) and a random 16-byte IV (NOT a fixed IV — see
  # RFC §6.2). The IV is prepended to the ciphertext so the receiver can recover
  # it; a fixed-IV envelope would false-green against an implementation-shaped
  # decryptor.
  defp feishu_encrypt(plaintext, encrypt_key) do
    key = :crypto.hash(:sha256, encrypt_key)
    iv = :crypto.strong_rand_bytes(16)
    cipher = :crypto.crypto_one_time(:aes_256_cbc, key, iv, pkcs7_pad(plaintext), true)
    Base.encode64(iv <> cipher)
  end

  defp pkcs7_pad(data) do
    pad = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<pad>>, pad)
  end

  defp feishu_signature(_timestamp, _nonce, "", _raw), do: ""

  defp feishu_signature(timestamp, nonce, secret, raw) do
    :crypto.hash(:sha256, timestamp <> nonce <> secret <> raw)
    |> Base.encode16(case: :lower)
  end

  defp maybe_signature_headers(headers, "", _timestamp, _nonce, _signature), do: headers

  defp maybe_signature_headers(headers, _secret, timestamp, nonce, signature) do
    headers ++
      [
        {"x-lark-request-timestamp", timestamp},
        {"x-lark-request-nonce", nonce},
        {"x-lark-signature", signature}
      ]
  end

  # ---- evidence (redaction-safe, RFC §9 / §6 evidence key allow-list) ----

  defp base_evidence(encrypted?, status) do
    %{
      "ok" => false,
      "checked_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "http_status" => status,
      "challenge_mode" => if(encrypted?, do: "encrypted", else: "plain"),
      "redacted" => true
    }
  end

  # ---- HTTP ----

  defp post(url, headers, raw) do
    case Req.post(url, headers: headers, body: raw, retry: false) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  # ---- params / url ----

  defp resolve_webhook_url(params) do
    base =
      case trim(get(params, "webhook_url")) do
        "" -> ProviderConnects.public_base_url() <> "/v1/im/feishu/events"
        url -> url
      end

    case trim(get(params, "app_id")) do
      "" -> base
      app_id -> put_query_param(base, "app_id", app_id)
    end
  end

  defp put_query_param(url, key, value) do
    uri = URI.parse(url)
    query = uri.query |> Kernel.||("") |> URI.decode_query() |> Map.put(key, value)

    uri
    |> Map.put(:query, URI.encode_query(query))
    |> URI.to_string()
  end

  defp get(params, key) do
    Map.get(params, key) || Map.get(params, String.to_atom(key))
  end

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp fingerprint(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end
end
