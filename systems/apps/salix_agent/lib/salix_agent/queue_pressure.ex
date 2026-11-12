defmodule SalixAgent.QueuePressure do
  @moduledoc """
  Tells a Router that other people's requests are queued behind the request it
  is working on.

  One Router session serves every conversation of a workspace in one queue, and
  a human request that arrives while another human's activation is open waits
  until that activation ends (`VerifiedKernel.Session.StateQuery.materializeBatch`). The model
  cannot see that queue, so a Router that keeps taking direct shell or research
  steps for one request blocks everyone else without knowing it. Measured on
  staging on 2026-09-14: two requests waited 33 minutes behind one Router
  activation of 54 model calls and 24 `env.exec` steps.

  This provider emits a runtime message while such requests wait: how many,
  from which providers, and for how long. It is a signal, not a guard; the
  Router prompt already says to transfer remaining work to a Task. The message
  refreshes at most every `@refresh_seconds`, also when the queued set changes:
  on Chat runtimes each copy is a `get_runtime_message` call in the model's
  history, and a model that sees one per round imitates them instead of ending
  its turn.

  Only people count (`people/1`): a wakeable `user_message` whose trusted
  origin names a person as its sender (`source_actor_type` `provider_user` or
  `user`). The kernel queues every human-source input behind the open
  activation (`human_source_wakeable_queue_item?` in
  `VerifiedKernel.Session.Query.StateCore`), and that set also holds schedule
  and Loop runs that act with their creator's authority (`provider: schedule`
  or `loop`, no sender). Nobody waits on such a run, so it alone sends no
  message. In production a Router read a queued schedule run as "1 human
  request", ended its person's request with nothing sent, and that person
  waited two hours. Runtime notifications and no-wake context never count
  either, so a Router waiting on its own Workers sees nothing.
  `SalixAgent.QueueYieldGuard` uses the same set.
  """

  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @refresh_seconds 60
  @max_listed 5

  @doc """
  `{messages, state}` for the activation about to run. `known` is the provider
  state map the session adopted last time (`known["queue_pressure"]`).
  """
  @spec prepare(term(), map(), map(), DateTime.t()) :: {[map()], map()}
  def prepare(session, session_config, known, now \\ SystemsClock.utc_now()) do
    previous = known["queue_pressure"] || %{}

    if router?(session_config) do
      now_ms = DateTime.to_unix(now, :millisecond)
      waiting = people(session)

      cond do
        waiting == [] ->
          {[], previous}

        is_integer(previous["emitted_at_ms"]) and
            now_ms - previous["emitted_at_ms"] < @refresh_seconds * 1000 ->
          {[], previous}

        true ->
          {[payload(waiting, now_ms)], %{"emitted_at_ms" => now_ms}}
      end
    else
      {[], previous}
    end
  end

  @doc "The people's requests queued behind the open activation, oldest first."
  def people(session),
    do: session |> unacked_items() |> Enum.filter(&(human_source_wakeable?(&1) and person?(&1)))

  @doc "Whether a trusted origin names a person as its sender: a provider user or a Comma user."
  def person_origin?(origin) when is_map(origin),
    do: value(origin, :source_actor_type) in ["provider_user", "user"]

  def person_origin?(_origin), do: false

  defp person?(item), do: item |> origin() |> person_origin?()

  defp router?(session_config) do
    role = value(session_config, :role)
    role == "router" or role == :router
  end

  defp payload(waiting, now_ms) do
    count = length(waiting)

    listed =
      waiting
      |> Enum.take(@max_listed)
      |> Enum.map(fn item ->
        provider = provider(item)
        waited = waited_text(item, now_ms)
        "- #{provider} request, waiting #{waited}"
      end)

    omitted = count - length(listed)

    lines =
      [
        "#{count} human #{plural(count, "request is", "requests are")} queued behind the request you are handling. They cannot start until this activation ends, and only this session serves them:"
      ] ++
        listed ++
        if(omitted > 0, do: ["- #{omitted} more"], else: []) ++
        [
          "Finish the current request without further direct execution or investigation steps. Ending the turn does not continue this request later: nothing wakes you for it again unless its person writes. Before you end, give remaining work to a Task with task.create and wait_for that result, or tell the person what is done and what is blocked. If the current request is complete, call end_turn with outcome=done and reply={tool,params} for its unsent final answer or status note. Include its IFC declaration in reply when needed. If the answer was already sent, omit reply. Queued requests have separate activations and do not prevent the current request from ending. Do not answer them here."
        ]

    content = Enum.join(lines, "\n")

    %{
      "runtime_message_id" => "queue-pressure:" <> SystemsRuntime.Proc.uuid(),
      "runtime_message_type" => "queue_pressure",
      "content_kind" => "model_context",
      "summary" =>
        "#{count} human #{plural(count, "request", "requests")} queued behind the current activation",
      "content" => content,
      "created_at" => div(now_ms, 1000),
      "source_refs" => %{"providers" => ["queue_pressure"]}
    }
  end

  defp plural(1, singular, _plural), do: singular
  defp plural(_count, _singular, plural), do: plural

  defp waited_text(item, now_ms) do
    case delivered_at_ms(item) do
      ms when is_integer(ms) and ms <= now_ms -> duration_text(div(now_ms - ms, 1000))
      _ -> "an unknown time"
    end
  end

  defp duration_text(seconds) when seconds < 60, do: "#{seconds}s"

  defp duration_text(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m#{String.pad_leading(Integer.to_string(rem(seconds, 60)), 2, "0")}s"

  defp duration_text(seconds), do: "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m"

  defp provider(item) do
    origin = origin(item)

    case value(origin, :provider) do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> "unknown"
    end
  end

  # Mirrors `VerifiedKernel.Session.Query.StateCore.humanSourceWakeable`.
  defp human_source_wakeable?(item) when is_map(item) do
    wake = value(item, :wake)
    wake != false and value(item, :kind) == "user_message" and human_source?(item)
  end

  defp human_source_wakeable?(_item), do: false

  defp human_source?(item) do
    origin = origin(item)
    obligation = value(payload_of(item), :provider_reply_obligation)

    human_source_origin?(origin) or
      (is_map(obligation) and external_provider?(value(obligation, :provider)))
  end

  # `origin/1` always yields a map, so no non-map clause.
  defp human_source_origin?(origin) do
    provider = value(origin, :provider)
    actor_type = value(origin, :source_actor_type)
    external_provider?(provider) or (provider == "internal" and actor_type == "user")
  end

  defp external_provider?(provider) when is_binary(provider) do
    trimmed = String.trim(provider)
    trimmed != "" and trimmed != "internal"
  end

  defp external_provider?(_provider), do: false

  defp origin(item) do
    case value(payload_of(item), :trusted_origin) do
      origin when is_map(origin) -> origin
      _ -> %{}
    end
  end

  defp delivered_at_ms(item), do: value(payload_of(item), :delivered_at_ms)

  defp payload_of(item) do
    case value(item, :payload) do
      payload when is_map(payload) -> payload
      _ -> %{}
    end
  end

  defp queue_item_id(item) do
    case value(item, :queue_id) || value(item, :id) do
      id when is_integer(id) -> id
      id when is_binary(id) -> id
      _ -> 0
    end
  end

  defp unacked_items(session) when InternalSession.is_session(session),
    do: List.wrap(InternalSession.unacked_queue_items(session))

  defp unacked_items(session) when is_map(session) do
    ack = value(session, :queue_ack_id) || 0

    session
    |> value(:input_queue)
    |> List.wrap()
    |> Enum.filter(fn item -> compare_ids(queue_item_id(item), ack) end)
  end

  defp unacked_items(_session), do: []

  defp compare_ids(id, ack) when is_integer(id) and is_integer(ack), do: id > ack
  defp compare_ids(_id, _ack), do: true

  defp value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp value(_map, _key), do: nil
end
