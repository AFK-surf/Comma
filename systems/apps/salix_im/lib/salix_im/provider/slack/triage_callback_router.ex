defmodule SalixIM.Provider.Slack.TriageCallbackRouter do
  @moduledoc """
  Routes explicit human commands and their continuations from verified Slack
  callbacks.

  Triage content callbacks are observation-only at this boundary. The ClickHouse
  patrol is the sole producer of new Triage content receipts. This router
  retains only the human command owner contract: a new command may establish the
  legacy owner, while a command addressed on a thread owned by another family
  uses a recipient-scoped command lane without rewriting that ambient owner.

  A thread this app already speaks in is the one exception for agent-authored
  callbacks. The patrol admits bot roots but never a reply, so without this lane
  another Slack app (a peer assistant, a relay) can post into an ongoing thread
  and never reach the inbound agent at all. Such a reply joins the same
  recipient-scoped continuation lane an ordinary human reply uses. It stays
  ordinary input: `ProviderHTTP` withholds command authority from every
  app-authored message, so relayed text cannot run a control command.
  """

  alias SalixIM.Provider.Slack.{Addressee, ThreadRouteOwner, TriageThreadSubscription}
  alias SalixIM.ProviderConnects
  alias SalixStore.SlackRouterThreadParticipations

  @agent_body_subtypes ["", "bot_message", "thread_broadcast", "file_share"]

  @doc "True only for an authoritative human app mention or App Home DM command callback."
  def human_command?(connect, envelope) when is_map(connect) and is_map(envelope) do
    event = envelope["event"] || %{}

    not agent_authored?(event) and admissible_human_command?(event) and
      (human_app_mention?(connect, event) or human_direct_message?(event))
  end

  def human_command?(_connect, _envelope), do: false

  @doc "Selects and pins the command route without changing an existing ambient owner."
  def route_human_command(connect, envelope, deliver)
      when is_map(connect) and is_map(envelope) and is_function(deliver, 1) do
    if human_command?(connect, envelope) do
      case select_human_command_route(connect, envelope) do
        {:ok, route} -> deliver.(route)
        other -> other
      end
    else
      {:ok, :ignored}
    end
  end

  def route_human_command(_connect, _envelope, _deliver),
    do: {:error, :slack_route_unavailable}

  @doc "Keeps ordinary human replies in a root command's recipient lane."
  def route_human_command_continuation(connect, envelope, continuation, ambient)
      when is_map(connect) and is_map(envelope) and is_function(continuation, 1) and
             is_function(ambient, 0) do
    if human_command_continuation_candidate?(connect, envelope) do
      continue_owned_thread(
        connect,
        envelope,
        continuation,
        ambient,
        &continue_legacy_command/2
      )
    else
      ambient.()
    end
  end

  def route_human_command_continuation(_connect, _envelope, _continuation, _ambient),
    do: {:error, :slack_route_unavailable}

  @doc "Keeps another app's reply in the lane of the thread this app speaks in."
  def route_agent_thread_continuation(connect, envelope, continuation, ambient)
      when is_map(connect) and is_map(envelope) and is_function(continuation, 1) and
             is_function(ambient, 0) do
    if agent_thread_continuation_candidate?(connect, envelope) do
      continue_owned_thread(
        connect,
        envelope,
        continuation,
        ambient,
        &continue_pinned_command/2
      )
    else
      ambient.()
    end
  end

  def route_agent_thread_continuation(_connect, _envelope, _continuation, _ambient),
    do: {:error, :slack_route_unavailable}

  # Ambient ownership and recipient participation are different facts. A human
  # command can enlist this Router without replacing a Triage/other app owner.
  # Continue that recipient lane using the existing durable participation row;
  # never manufacture a Triage subscription from an inbound bot message.
  defp continue_owned_thread(connect, envelope, continuation, ambient, legacy_lane) do
    scope = command_scope(connect, envelope)
    owner = ThreadRouteOwner.lookup(scope)

    cond do
      owner == :unavailable ->
        {:error, :slack_route_unavailable}

      owner == {:ok, :legacy} ->
        legacy_lane.(scope, continuation)

      router_participating?(connect, scope) ->
        continue_command(scope, owner, continuation)

      owner in [{:ok, :triage}, {:owned_elsewhere, :triage}] ->
        continue_triage_thread(scope, owner, continuation, ambient)

      true ->
        ambient.()
    end
  end

  defp router_participating?(connect, scope) do
    SlackRouterThreadParticipations.status(
      scope["group_id"],
      scope["connect_id"],
      scope["workspace_id"],
      connect["bot_user_id"],
      scope["channel_id"],
      scope["root_thread_ts"]
    ) == :participating
  end

  # Triage subscriptions use the channel's authority generation, not the
  # installation generation used to authenticate this callback. Keep the
  # installation scope as the command pin and leave its credentials untouched.
  defp continue_triage_thread(scope, owner, continuation, ambient) do
    with {:ok, authority} <-
           ProviderConnects.get_slack_triage_authority(
             scope["tenant_id"],
             scope["group_id"],
             scope["connect_id"],
             scope["channel_id"]
           ),
         triage_scope = Map.put(scope, "connect_generation", authority["connect_generation"]),
         {:ok, :triage} <- ThreadRouteOwner.lookup(triage_scope),
         :admit <- TriageThreadSubscription.continuation(authority, triage_scope) do
      continue_command(scope, owner, continuation)
    else
      {:error, reason}
      when reason in [:slack_triage_authority_unavailable, :unavailable] ->
        {:error, :slack_route_unavailable}

      :unavailable ->
        {:error, :slack_route_unavailable}

      _not_subscribed ->
        ambient.()
    end
  end

  defp continue_command(scope, owner, continuation) do
    with {:ok, route} <- command_route(scope, true, owner), do: continuation.(route)
  end

  # An agent reply rides the recipient-scoped lane pinned to the legacy owner.
  # Only a person's own continuation asserts that command's claim identity.
  defp continue_pinned_command(scope, continuation) do
    with {:ok, route} <- command_route(scope, true, {:ok, :legacy}),
         do: continuation.(route)
  end

  defp continue_legacy_command(scope, continuation) do
    case ThreadRouteOwner.lookup_claim(scope) do
      {:ok, :legacy, claim_identity} ->
        continuation.(%{
          owner: :legacy,
          kind: :reply,
          scope: scope,
          claim_identity: claim_identity
        })

      :unavailable ->
        {:error, :slack_route_unavailable}
    end
  end

  defp select_human_command_route(connect, envelope) do
    event = envelope["event"] || %{}
    message_ts = trim(event["ts"])
    reply? = thread_reply?(event)
    scope = command_scope(connect, envelope)

    case ThreadRouteOwner.lookup(scope) do
      :unavailable ->
        {:error, :slack_route_unavailable}

      :unbound ->
        claim_legacy_command(envelope, scope, message_ts, reply?)

      {:ok, :legacy} ->
        existing_legacy_command(scope, envelope, message_ts, reply?)

      owner_state ->
        command_route(scope, reply?, owner_state)
    end
  end

  defp claim_legacy_command(envelope, scope, message_ts, reply?) do
    kind = if(reply?, do: :mention_reply, else: :root)
    root_thread_ts = if(reply?, do: scope["root_thread_ts"], else: message_ts)

    with {:ok, claim_identity} <- verified_root_identity(scope, envelope, root_thread_ts) do
      case ThreadRouteOwner.claim_legacy(scope, claim_identity) do
        {:ok, :legacy} ->
          {:ok,
           %{
             owner: :legacy,
             kind: kind,
             scope: scope,
             claim_identity: claim_identity
           }}

        {:conflict, _winner} ->
          command_route_after_conflict(scope, reply?)

        _unavailable ->
          {:error, :slack_route_unavailable}
      end
    else
      _invalid -> {:error, :slack_route_unavailable}
    end
  end

  defp existing_legacy_command(scope, _envelope, _message_ts, true) do
    case ThreadRouteOwner.lookup_claim(scope) do
      {:ok, :legacy, claim_identity} ->
        {:ok,
         %{
           owner: :legacy,
           kind: :mention_reply,
           scope: scope,
           claim_identity: claim_identity
         }}

      _unavailable ->
        {:error, :slack_route_unavailable}
    end
  end

  defp existing_legacy_command(scope, envelope, message_ts, false) do
    with {:ok, claim_identity} <- verified_root_identity(scope, envelope, message_ts) do
      case ThreadRouteOwner.verify_claim(scope, :legacy, claim_identity) do
        {:ok, :legacy} ->
          {:ok,
           %{
             owner: :legacy,
             kind: :root,
             scope: scope,
             claim_identity: claim_identity
           }}

        {:conflict, _winner} ->
          command_route_after_conflict(scope, false)

        _unavailable ->
          {:error, :slack_route_unavailable}
      end
    else
      _invalid -> {:error, :slack_route_unavailable}
    end
  end

  defp command_route_after_conflict(scope, reply?) do
    command_route(scope, reply?, ThreadRouteOwner.lookup(scope))
  end

  defp command_route(scope, reply?, owner_pin)
       when owner_pin == :unbound or
              owner_pin in [{:ok, :triage}, {:ok, :assistant}, {:ok, :legacy}, {:ok, :task}] do
    {:ok,
     %{
       owner: :command,
       kind: if(reply?, do: :reply, else: :root),
       scope: scope,
       owner_pin: owner_pin
     }}
  end

  defp command_route(scope, reply?, {:owned_elsewhere, owner} = owner_pin)
       when owner in [:triage, :legacy, :assistant, :task] do
    {:ok,
     %{
       owner: :command,
       kind: if(reply?, do: :reply, else: :root),
       scope: scope,
       owner_pin: owner_pin
     }}
  end

  defp command_route(_scope, _reply?, _owner_state),
    do: {:error, :slack_route_unavailable}

  defp verified_root_identity(scope, envelope, root_thread_ts) do
    ThreadRouteOwner.verified_root_claim_identity(scope, %{
      "provider_event_id" => trim(envelope["event_id"]),
      "callback_app_id" => trim(envelope["api_app_id"]),
      "workspace_id" => trim(envelope["team_id"]),
      "channel_id" => scope["channel_id"],
      "root_thread_ts" => root_thread_ts
    })
  end

  defp human_command_continuation_candidate?(connect, envelope) do
    event = envelope["event"] || %{}

    trim(event["type"]) == "message" and thread_reply?(event) and
      not agent_authored?(event) and admissible_message?(event) and
      not mentions_bot?(connect, event)
  end

  defp agent_thread_continuation_candidate?(connect, envelope) do
    event = envelope["event"] || %{}

    trim(event["type"]) in ["message", "app_mention"] and thread_reply?(event) and
      agent_authored?(event) and not from_own_connect?(connect, event) and
      admissible_agent_message?(event)
  end

  defp command_scope(connect, envelope) do
    event = envelope["event"] || %{}
    message_ts = trim(event["ts"])

    %{
      "tenant_id" => trim(connect["tenant_id"]),
      "group_id" => trim(connect["group_id"]),
      "connect_id" => trim(connect["connect_id"]),
      "connect_generation" => trim(connect["connect_generation"]),
      "workspace_id" => trim(connect["workspace_id"]),
      "channel_id" => first_nonblank([event["channel"], event["channel_id"]]),
      "root_thread_ts" => first_nonblank([event["thread_ts"], message_ts])
    }
  end

  defp human_app_mention?(connect, event),
    do: trim(event["type"]) == "app_mention" and mentions_bot?(connect, event)

  defp human_direct_message?(event),
    do: trim(event["type"]) == "message" and trim(event["channel_type"]) == "im"

  defp admissible_human_command?(event) do
    admissible_message?(event) or
      (actor_id(event) != "" and trim(event["text"]) != "" and
         trim(event["subtype"]) in ["", "file_share"] and
         Enum.any?(List.wrap(event["files"]), &is_map/1))
  end

  defp admissible_message?(event) do
    trim(event["subtype"]) == "" and actor_id(event) != "" and trim(event["text"]) != "" and
      List.wrap(event["files"]) == []
  end

  # An app that posts with its own name or icon, or through an incoming
  # webhook, has no `user` and arrives under the `bot_message` subtype. Reading
  # only `user` and the empty subtype drops exactly those senders, which is why
  # a peer app could sit in a thread unanswered. Take the same identity
  # `ProviderHTTP` records as the app author, and the same body subtypes the
  # ClickHouse patrol treats as message content.
  defp admissible_agent_message?(event) do
    trim(event["subtype"]) in @agent_body_subtypes and agent_actor_id(event) != "" and
      (trim(event["text"]) != "" or Enum.any?(List.wrap(event["files"]), &is_map/1))
  end

  defp agent_actor_id(event) do
    bot_profile = if is_map(event["bot_profile"]), do: event["bot_profile"], else: %{}

    first_nonblank([actor_id(event), event["bot_id"], bot_profile["id"], event["app_id"]])
  end

  defp thread_reply?(event) do
    thread_ts = trim(event["thread_ts"])
    thread_ts != "" and thread_ts != trim(event["ts"])
  end

  defp mentions_bot?(connect, event), do: Addressee.mentions_self?(connect, event)

  defp agent_authored?(event),
    do: trim(event["bot_id"]) != "" or is_map(event["bot_profile"])

  defp from_own_connect?(connect, event) do
    actor_id(event) == trim(connect["bot_user_id"]) or
      (trim(event["bot_id"]) != "" and trim(event["bot_id"]) == trim(connect["bot_id"])) or
      (trim(event["app_id"]) != "" and trim(event["app_id"]) == trim(connect["app_id"]))
  end

  defp actor_id(%{"user" => %{"id" => id}}), do: trim(id)
  defp actor_id(%{"user" => user_id}), do: trim(user_id)
  defp actor_id(_event), do: ""

  defp first_nonblank(values), do: Enum.find_value(values, "", &(trim(&1) != "" && trim(&1)))
  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
