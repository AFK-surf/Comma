defmodule SalixAgent.EventArchive.Emit do
  @moduledoc """
  Boundary emitters for the encrypted event archive.

  One function per crossing in docs/observability.md
  Call sites stay one-liners so the loop reads as the loop, not as an
  instrumentation harness.

  Every emitter runs inside `safe/1`, which short-circuits on
  `EventArchive.enabled?/0` before touching the payload and catches anything
  the shaping code throws. Both halves matter: assembling a full message list
  is real work a deployment without recipients must not pay for, and a raise
  in this module would otherwise fail the very turn it is observing.

  Payloads are passed through raw. No redaction, truncation, or summarizing
  happens here — that is the archive's entire point, and the recipient key is
  what contains the sensitivity.
  """

  require Logger

  alias SalixAgent.EventArchive
  alias SalixAgent.EventArchive.Accumulator

  @doc """
  Boundary 1 — an item the loop received from outside.

  Takes the raw entry and derives everything INSIDE the guard. Call sites must
  not dig into the payload to build arguments: argument expressions are
  evaluated in the caller, before any guard here applies, so
  `entry.payload[:session_id]` at a call site raises into the loop on an entry
  whose shape does not support Access. `require_session_id/1` on the delivery
  path is deliberately total about those shapes; this must be too.
  """
  def delivery(agent_id, entry, opts \\ []) do
    safe(fn ->
      opts =
        opts
        |> Keyword.put(:agent_id, agent_id)
        |> Keyword.put_new_lazy(:session_id, fn -> entry_session_id(entry) end)
        |> Keyword.put_new_lazy(:tenant_id, fn -> tenant_from_agent(agent_id) end)

      record(:delivery, entry, opts)
    end)
  end

  # An inbound delivery carries no billing context — it is staged before any
  # session actor exists — so tenant has to come from the agent id itself.
  # Without it the row stores tenant_id = "" and a per-tenant erasure
  # (`ALTER TABLE ... DELETE WHERE tenant_id = ...`) silently skips every
  # inbound event for that tenant. Total: a non-canonical id yields nil rather
  # than aborting the emit, because archiving without a tenant beats not
  # archiving at all.
  defp tenant_from_agent(agent_id) when is_binary(agent_id) do
    SalixStore.Ids.tenant_id_from_agent!(agent_id)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp tenant_from_agent(_agent_id), do: nil

  defp entry_session_id(%{payload: payload}) when is_map(payload),
    do: payload[:session_id] || payload["session_id"]

  defp entry_session_id(_entry), do: nil

  @doc """
  Boundary 2 — a request handed to the provider.

  Called from the `SalixAgent.LLM` dispatch seam, so it covers the round,
  compaction, title generation and the trajectory-eval judge alike. `kind`
  distinguishes them (`:complete`, `:complete_stream`, `:compact_context`).

  Compaction matters most here: it ships the whole conversation to the model
  and is the LAST point that history exists before compaction discards it.

  `identity` is what the CALL SITE knows about who this dispatch belongs to.
  Passing it is not optional in practice — see `from_llm_opts/2` for why
  `llm_opts` alone cannot answer that question.
  """
  def llm_request(kind, messages, tools, llm_opts, identity \\ []) do
    safe(fn ->
      request =
        case messages do
          {:encoded_provider_request, protocol, body} ->
            %{"protocol" => protocol, "request_body" => body}

          messages ->
            %{"messages" => messages}
        end

      payload =
        Map.merge(request, %{
          "call" => to_string(kind),
          "tool_specs" => tools,
          "options" => scrub_credentials(llm_opts)
        })

      record(:llm_request, payload, from_llm_opts(llm_opts, identity))
    end)
  end

  @doc """
  Take boundary 3's stream position before the provider is called.

  The dispatch seam wraps the provider call in try/rescue/catch so that a
  failed call still archives a response. That covers raises and exits — but not
  `Process.exit(pid, :kill)`, which is untrappable and is exactly how
  `SalixAgent.DependencyJob` cancels a job. A killed dispatch runs no arm of
  that try, so the response is simply never produced.

  Without a reservation nothing is left behind at all: no item and no `seq`
  consumed, so the hole has no position. Taking the position here and redeeming
  it in `llm_response/5` gives it one.

  That is the whole of what this buys, and it is less than "the loss becomes
  visible". An unredeemed reservation is reportable only when a later item
  lands on the same run to bound it; if the killed dispatch was the run's last
  activity, `archive.verify` still reports a clean run, and no counter fires
  either — see `SalixAgent.EventArchive.reserve/1` for why.

  Returns `nil` when there is nothing to reserve; `llm_response/5` then
  allocates normally.
  """
  def reserve_llm_response(llm_opts, identity \\ []) do
    if EventArchive.enabled?() do
      opts = from_llm_opts(llm_opts, identity)

      EventArchive.reserve(%{
        boundary: :llm_response,
        tenant_id: opts[:tenant_id],
        agent_id: opts[:agent_id],
        session_id: opts[:session_id],
        round_id: opts[:round_id]
      })
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  @doc false
  def reserve_egress(context, session_id) do
    if EventArchive.enabled?() do
      opts = from_context(context, session_id)

      EventArchive.reserve(%{
        boundary: :egress,
        tenant_id: opts[:tenant_id],
        agent_id: opts[:agent_id],
        session_id: opts[:session_id],
        round_id: opts[:round_id]
      })
    end
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  Boundary 3 — what the provider returned, plus anything that only existed
  as a stream.

  `accumulator` carries streamed text and reasoning deltas. Private reasoning
  never reaches the terminal result, so without it the archive would be missing
  what the model actually produced.

  `reservation` is whatever `reserve_llm_response/1` returned for this
  dispatch, so the item lands at the position taken before the call rather than
  at a fresh one.
  """
  def llm_response(kind, result, llm_opts, accumulator \\ nil, reservation \\ nil, identity \\ []) do
    safe(fn ->
      payload =
        kind
        |> shape_response(result)
        |> maybe_put_deltas(Accumulator.drain(accumulator))

      record(:llm_response, payload, from_llm_opts(llm_opts, identity), reservation)
    end)
  end

  @doc "Boundary 4 — tool calls the loop dispatched."
  def tool_calls(ctx, calls) do
    safe(fn ->
      if not is_list(calls) or calls == [] do
        :ok
      else
        record(:tool_call, %{"calls" => calls}, from_context(ctx, ctx[:session_id]))
      end
    end)
  end

  @doc "Boundary 5 — tool results the loop received, sync or async."
  def tool_results(ctx, results) do
    safe(fn ->
      if not is_list(results) or results == [] do
        :ok
      else
        record(:tool_result, %{"results" => results}, from_context(ctx, ctx[:session_id]))
      end
    end)
  end

  @doc """
  Boundary 4, withheld arm — calls the model made that the loop refused.

  These are filtered out before the `Tools` seam by the authorization
  boundary, so they reach no other emitter. Both the original call (with its
  full argument map) and the synthesized refusal are archived: the refusal
  alone would record the decision without the intent.
  """
  def withheld_tool_calls(ctx, withheld) do
    safe(fn ->
      if not is_list(withheld) or withheld == [] do
        :ok
      else
        record(
          :tool_call,
          %{"withheld" => withheld, "authorized" => false},
          from_context(ctx, ctx[:session_id])
        )
      end
    end)
  end

  @doc """
  Boundary 4, information-flow arm — one `SalixIFC.decide/4` verdict.

  Every decision is archived, audit-mode ones included: audit mode exists to
  be read, and a Group cannot compare "what enforce would have done" against
  "what happened" unless both are recorded. The payload carries labels,
  clause names and membership revisions — never the content the effect was
  carrying, and never an atom's display name.
  """
  def ifc_decision(ctx, decision) do
    safe(fn ->
      if not is_map(decision) or decision == %{} do
        :ok
      else
        record(
          :tool_call,
          %{"ifc" => decision},
          from_context(ctx, ctx[:session_id])
        )
      end
    end)
  end

  @doc """
  Boundary 5, async arm — a tool result that settled after its dispatch window.

  Async tools return `async_running` synchronously and land their terminal
  result later, in the session actor. Without this the archive would be missing
  those results entirely — and because a missed item never consumes a `seq`,
  that omission would be invisible to `mix salix.archive.verify`, which is the
  one failure mode the completeness design cannot tolerate.
  """
  def async_tool_result(agent_id, session_id, pending, result) do
    safe(fn ->
      payload = %{
        "results" => [result],
        "async" => true,
        "tool_name" => pending[:tool_name],
        "tool_call_id" => pending[:tool_call_id],
        "call_index" => pending[:call_index]
      }

      record(:tool_result, payload,
        agent_id: agent_id,
        session_id: session_id,
        # Three sources, in order of how directly they name the tenant. A
        # pending record carries its own `tenant_id` — copied from the tool
        # context at dispatch — and its billing context can be absent
        # entirely, so reading only the billing context left `tenant_id` nil
        # on ordinary async settlements. The row then stored "" and a
        # per-tenant `ALTER TABLE ... DELETE`, the only erasure that works
        # without a key, skipped it.
        tenant_id:
          soft_get(pending, "tenant_id") || billing_tenant(soft_get(pending, "billing_context")) ||
            tenant_from_agent(agent_id)
      )
    end)
  end

  @doc """
  Boundary 5, callback arm — a tool result arriving from off-node.

  Takes `call` and `meta` RAW. Extraction happens inside the guard: `call` here
  can be a keyword list, and `call["tool_name"]` on one raises (keyword Access
  requires atom keys). Doing that in an argument expression put the raise in
  the caller, outside every guard — it broke the JavaScript-host wake path
  before this signature existed.
  """
  def callback_tool_result(agent_id, session_id, call, tool_call_id, meta, result) do
    safe(fn ->
      payload = %{
        "results" => [result],
        "async" => true,
        "callback" => true,
        "tool_call_id" => tool_call_id,
        "tool_name" => soft_get(meta, "tool_name") || soft_get(call, "tool_name"),
        "call" => call,
        "meta" => meta
      }

      record(:tool_result, payload,
        agent_id: agent_id,
        session_id: session_id,
        tenant_id: soft_get(meta, "tenant_id") || tenant_from_agent(agent_id)
      )
    end)
  end

  # Total accessor: any container shape, any key form, never raises. Keyword
  # lists reject binary keys through Access, and structs reject Access outright.
  defp soft_get(container, key) when is_map(container) and not is_struct(container),
    do: Map.get(container, key) || Map.get(container, safe_atom(key))

  defp soft_get(container, key) when is_list(container) do
    case safe_atom(key) do
      nil -> nil
      atom -> if Keyword.keyword?(container), do: Keyword.get(container, atom), else: nil
    end
  end

  defp soft_get(_container, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  @doc "Boundary 6 — what the loop sent to a user-visible surface."
  def egress(context, session_id, payload, reservation \\ nil) do
    safe(fn -> record(:egress, payload, from_context(context, session_id), reservation) end)
  end

  @doc """
  Boundary 6, external-runtime arm — what an off-node loop asserted back to us.

  An external-runtime agent runs its own loop on the customer's infrastructure.
  Its provider traffic (boundaries 2 and 3) happens where we cannot see it, and
  no amount of instrumentation here will change that — that limit is stated in
  `systems/AGENTS.md` rather than papered over. What DOES cross into this
  system is the events the runtime commits, and those are its outputs: they are
  what a reader would otherwise have to take on trust.

  `kind` distinguishes the commit paths (`:commit`, `:append`) so a reader can
  tell a batch from a single appended event.
  """
  def external_runtime_events(agent_id, session_id, kind, events) do
    safe(fn ->
      payload = %{
        "external_runtime" => true,
        "commit" => to_string(kind),
        "events" => events
      }

      record(:egress, payload,
        agent_id: agent_id,
        session_id: session_id,
        tenant_id: tenant_from_agent(agent_id)
      )
    end)
  end

  # `EventArchive.record/1` wraps only the ADAPTER call. Everything else —
  # sanitize/1, scrub_credentials/1, shape_response/1, context extraction —
  # runs in the LOOP's own process, and argument expressions are evaluated
  # before any callee's rescue can apply. So each emitter's whole body runs
  # inside this guard: without it, one unexpected payload shape would raise in
  # the caller and fail a turn. Archiving must never be able to do that.
  #
  # The enabled? check lives here too, so a deployment with no recipients
  # configured pays nothing for payload assembly.
  defp safe(fun) do
    if EventArchive.enabled?(), do: fun.(), else: :ok
  rescue
    exception ->
      Logger.warning("event archive emit failed: #{brief(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("event archive emit exited: #{inspect(kind)}")
      {:error, {kind, reason}}
  end

  defp record(boundary, payload, opts, reservation \\ nil) do
    EventArchive.record(%{
      boundary: boundary,
      payload: sanitize(payload),
      tenant_id: opts[:tenant_id],
      agent_id: opts[:agent_id],
      session_id: opts[:session_id],
      round_id: opts[:round_id],
      reservation: reservation
    })
  end

  # Who a provider dispatch belongs to. Three sources, in order of how directly
  # they name the agent.
  #
  # `identity` is what the CALL SITE knows, and it is authoritative because it
  # is the only source that is always right. `llm_opts` is NOT a fallback for
  # it: those are the template's provider config (model, protocol, api key,
  # base url), resolved per TEMPLATE by `SalixAgent.LlmResolver`, and they
  # carry no identity at all. `SalixAgent.Round` keeps the round's identity in
  # its `meter_ctx` instead, which never reached this seam — so before
  # `identity` existed, EVERY round archived with all four fields empty and
  # landed on the stream `agent::inbox`, one shared run for every agent and
  # tenant on the node. A per-tenant erasure (`ALTER TABLE ... DELETE WHERE
  # tenant_id = ...`) skipped all of it.
  #
  # The billing context is second, and is read under the `salix_`-prefixed
  # names it actually uses (`salix_tenant_id`, `salix_agent_id` — see
  # `SalixIm.AgentDeliveryPayload` and `Comma.Conversations`). The unprefixed
  # reads that were here matched no context this system builds. `agent_id` in
  # particular is set by exactly one producer, BridgeForTeams, and holds ITS
  # OWN record id rather than a Salix agent id — so the prefixed name is
  # PREFERRED over it, not merely added: reading the unprefixed one first put
  # a foreign id in a plaintext, key-free index and named a stream after it,
  # which reads as attribution while being wrong.
  #
  # No billing context carries `session_id` or `round_id` under any name; those
  # come from `identity` or not at all.
  defp from_llm_opts(llm_opts, identity) do
    billing = fetch(llm_opts, :billing_context) || %{}

    agent_id =
      soft_get(identity, "agent_id") || soft_get(billing, "salix_agent_id") ||
        soft_get(billing, "agent_id") || fetch(llm_opts, :agent_id)

    [
      agent_id: agent_id,
      session_id:
        soft_get(identity, "session_id") || soft_get(billing, "session_id") ||
          fetch(llm_opts, :session_id),
      tenant_id:
        soft_get(identity, "tenant_id") || soft_get(billing, "salix_tenant_id") ||
          soft_get(billing, "tenant_id") || tenant_from_agent(agent_id),
      round_id:
        soft_get(identity, "round_id") || soft_get(billing, "round_id") ||
          fetch(llm_opts, :round_id)
    ]
  end

  defp billing_tenant(nil), do: nil

  defp billing_tenant(billing),
    do: soft_get(billing, "salix_tenant_id") || soft_get(billing, "tenant_id")

  defp fetch(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp fetch(opts, key) when is_map(opts), do: Map.get(opts, key) || Map.get(opts, to_string(key))
  defp fetch(_opts, _key), do: nil

  defp maybe_put_deltas(payload, nil), do: payload
  defp maybe_put_deltas(payload, deltas), do: Map.put(payload, "deltas", deltas)

  defp from_context(context, session_id) do
    billing = context[:billing_context] || %{}
    agent_id = context[:agent_id]

    [
      agent_id: agent_id,
      session_id: session_id,
      # `salix_tenant_id` is the name a real billing context uses; the
      # unprefixed one is kept for the single producer that emits it
      # (`SalixAgent.StorageAuthorization`). Read through `soft_get/2` rather
      # than Access: a keyword-list context RAISES on a binary key, and that
      # raise lands in `safe/1`, which would drop the whole item.
      #
      # Falling back to the agent id matters for erasure, not for navigation: a
      # per-tenant purge is `ALTER TABLE ... DELETE WHERE tenant_id = ...`, the
      # only erasure that works without a key, and it silently skips every row
      # that stored "".
      tenant_id:
        soft_get(billing, "salix_tenant_id") || soft_get(billing, "tenant_id") ||
          tenant_from_agent(agent_id),
      round_id: context[:round_id] || context[:trace_ctx][:round_id]
    ]
  end

  defp shape_response(_kind, {:assistant, content, calls}),
    do: %{"kind" => "assistant", "content" => content, "tool_calls" => calls}

  defp shape_response(_kind, {:assistant, content, calls, provider_meta}),
    do: %{
      "kind" => "assistant",
      "content" => content,
      "tool_calls" => calls,
      "provider_meta" => provider_meta
    }

  defp shape_response(_kind, {:assistant, content, calls, provider_meta, trace_meta}),
    do: %{
      "kind" => "assistant",
      "content" => content,
      "tool_calls" => calls,
      "provider_meta" => provider_meta,
      "trace_meta" => trace_meta
    }

  defp shape_response(_kind, {:final, content}), do: %{"kind" => "final", "content" => content}

  defp shape_response(_kind, {:final, content, trace_meta}),
    do: %{"kind" => "final", "content" => content, "trace_meta" => trace_meta}

  defp shape_response(_kind, {:final, content, provider_meta, trace_meta}),
    do: %{
      "kind" => "final",
      "content" => content,
      "provider_meta" => provider_meta,
      "trace_meta" => trace_meta
    }

  defp shape_response(_kind, {:error, meta}), do: %{"kind" => "error", "meta" => meta}

  defp shape_response(_kind, {:unsupported, reason}),
    do: %{"kind" => "unsupported", "reason" => inspect(reason)}

  defp shape_response(:generate_image, {:ok, image}),
    do: %{"kind" => "image", "image" => image}

  defp shape_response(_kind, {:ok, items, trace_meta}),
    do: %{"kind" => "compacted", "output_items" => items, "trace_meta" => trace_meta}

  defp shape_response(_kind, other), do: %{"kind" => "unknown", "value" => inspect(other)}

  # Provider options carry credentials for a THIRD party. Archiving them puts
  # live keys in an object nobody can rotate them out of, so they are the one
  # thing scrubbed on the way in.
  #
  # Scrubbing is RECURSIVE and shape-agnostic. A top-level substring match over
  # key names missed every realistic shape: nested provider config, headers
  # inside a keyword list, a token in a `base_url` query string, and a struct
  # (which raised in Enum, silently losing the whole item through `safe/1`).
  #
  # Deliberately asymmetric with tool results, which are archived raw: the
  # archive's whole point is that redaction belongs to whoever holds the
  # private key. Provider credentials are the exception because they are not
  # agent content and cannot be rotated out of a sealed object.
  # Matched against a name NORMALIZED to underscores and lowercase, so
  # `x-api-key`, `X-Api-Key` and `api_key` are all one case. Header names use
  # hyphens, which a raw underscore match misses entirely.
  @credential_key_parts ~w(api_key apikey secret password passwd token authorization auth
                           credential cookie bearer session_key private_key access_key
                           userinfo)

  # `headers` is redacted by VALUE, not wholesale: anthropic-version,
  # anthropic-beta and routing headers are genuinely useful for reconstructing
  # a request, and dropping the container lost them.
  @credential_container_parts ~w(headers)

  defp scrub_credentials(value), do: scrub(value, nil)

  defp scrub(value, key_hint) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key, scrub_entry(key, inner)} end)
    |> tap_hint(key_hint)
  end

  # Structs are not enumerable as maps; going through Map.from_struct keeps the
  # scrub total instead of raising into `safe/1` and dropping the item.
  defp scrub(%_{} = value, key_hint), do: value |> Map.from_struct() |> scrub(key_hint)

  defp scrub(value, key_hint) when is_list(value) do
    if Keyword.keyword?(value) do
      Enum.map(value, fn {key, inner} -> {key, scrub_entry(key, inner)} end)
    else
      Enum.map(value, &scrub(&1, key_hint))
    end
  end

  defp scrub({k, v}, _key_hint) when is_binary(k), do: {k, scrub_entry(k, v)}
  defp scrub(value, _key_hint) when is_binary(value), do: scrub_url(value)
  defp scrub(value, _key_hint), do: value

  defp tap_hint(value, _key_hint), do: value

  defp scrub_entry(key, value) do
    name = normalize_key(key)

    cond do
      String.contains?(name, @credential_key_parts) -> "[redacted]"
      String.contains?(name, @credential_container_parts) -> redact_container(value)
      true -> scrub(value, name)
    end
  end

  # Redact header VALUES whose name looks like a credential; keep the rest.
  defp redact_container(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {k, v} -> {k, redact_if_credential(k, v)} end)

  defp redact_container(value) when is_list(value) do
    Enum.map(value, fn
      {k, v} -> {k, redact_if_credential(k, v)}
      other -> other
    end)
  end

  defp redact_container(value), do: scrub(value, nil)

  defp redact_if_credential(key, value) do
    if String.contains?(normalize_key(key), @credential_key_parts),
      do: "[redacted]",
      else: value
  end

  defp normalize_key(key) do
    key
    |> to_string()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  # A gateway URL with an embedded token is archived verbatim otherwise. Only
  # the credential-looking query parameters are replaced; the rest of the URL
  # is what makes the request reconstructable.
  defp scrub_url(value) do
    if String.contains?(value, "?") and
         String.contains?(String.downcase(value), ["=", "token", "key"]) do
      case String.split(value, "?", parts: 2) do
        [base, query] -> base <> "?" <> scrub_query(query)
        _ -> value
      end
    else
      value
    end
  end

  defp scrub_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, _secret] ->
          if String.contains?(normalize_key(name), @credential_key_parts),
            do: name <> "=[redacted]",
            else: pair

        _ ->
          pair
      end
    end)
  end

  # Jason cannot encode tuples, PIDs, functions or references, and a raw
  # boundary object can carry any of them (a trace context, a callback). The
  # archive must never fail on shape, so anything unencodable becomes its
  # inspect form rather than raising inside the loop's caller.
  defp sanitize(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), sanitize(inner)} end)

  defp sanitize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp sanitize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp sanitize(%Date{} = value), do: Date.to_iso8601(value)
  defp sanitize(value) when is_struct(value), do: value |> Map.from_struct() |> sanitize()
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)
  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> sanitize()

  defp sanitize(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp sanitize(value) when is_atom(value), do: to_string(value)
  defp sanitize(value), do: inspect(value)

  # Exception messages can carry the offending VALUE (Protocol.UndefinedError
  # appends "Got value: ..."), which is agent content. Logs are unencrypted, so
  # only the exception type and a short prefix are recorded.
  defp brief(exception) do
    exception.__struct__
    |> inspect()
    |> Kernel.<>(": ")
    |> Kernel.<>(exception |> Exception.message() |> String.slice(0, 120))
  end
end
