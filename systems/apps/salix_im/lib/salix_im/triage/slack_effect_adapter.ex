defmodule SalixIM.Triage.SlackEffectAdapter do
  @moduledoc """
  Production final adapter for native event-driven Triage.

  A reply is recovered by its durable operation reference, freshness-checked,
  prepared without mutating Conversation state, checked again, and delivered
  directly to Slack. A provider-confirmed reply remains delivered even when a
  non-retryable local continuation contract defect prevents admission; the
  degraded admission is retained in result metadata. Retryable local admission
  failures remain pending without reposting. A lightweight emoji reaction uses
  the same durable product obligation claim, checks source freshness immediately
  before Slack's set-like `reactions.add`, and settles only after Slack confirms
  the reaction or reports that it was already present. Silence never creates a
  provider delivery.
  """

  @behaviour SalixIM.Triage.ProductEffectAdapter

  alias SalixIM.Triage.SourceSpeakerLabels
  alias SalixIM.Triage.{ExpressionContext, ProductDecision}
  alias SalixIM.Triage.SlackEffectAdapter.{EffectGuard, Freshness, Reaction, Reply}

  def apply(claim, opts \\ [])

  @impl true
  def apply(%{obligation_id: obligation_id, payload: payload} = claim, opts)
      when is_binary(obligation_id) and is_map(payload) and is_list(opts) do
    freshness_port = Keyword.get(opts, :freshness_port, Freshness)
    reply_port = Keyword.get(opts, :reply_port, Reply)
    reaction_port = Keyword.get(opts, :reaction_port, Reaction)
    effect_guard = Keyword.get(opts, :effect_guard, EffectGuard)
    port_opts = Keyword.get(opts, :port_opts, [])

    result =
      case payload["communication"] do
        %{"kind" => "silence", "reason" => reason} = communication
        when is_binary(reason) and reason != "" ->
          {:ok,
           %{
             adapter: :slack,
             outcome: :applied,
             external_writes: 0,
             communication: %{
               "kind" => "silence",
               "status" => "recorded",
               "reason" => reason,
               "source_refs" => communication["source_refs"] || []
             },
             metadata: %{"obligation_id" => obligation_id}
           }}

        %{"kind" => "reply", "text" => text} = communication
        when is_binary(text) and text != "" ->
          apply_reply(
            claim,
            communication,
            freshness_port,
            reply_port,
            effect_guard,
            port_opts
          )

        %{"kind" => "reaction", "emoji" => emoji} = communication
        when is_binary(emoji) and emoji != "" ->
          apply_reaction(
            claim,
            communication,
            freshness_port,
            reaction_port,
            effect_guard,
            port_opts
          )

        _invalid ->
          {:error, :invalid_communication, false}
      end

    attach_source_speaker_labels(result, payload, opts)
  end

  def apply(_claim, _opts), do: {:error, :invalid_product_obligation, false}

  defp attach_source_speaker_labels({:ok, effect}, payload, opts) do
    resolver = Keyword.get(opts, :speaker_label_resolver, SourceSpeakerLabels)
    resolver_opts = Keyword.get(opts, :speaker_label_opts, [])
    labels = resolver.resolve(payload, resolver_opts)

    {:ok,
     Map.update(effect, :metadata, %{"source_speaker_labels" => labels}, fn metadata ->
       Map.put(metadata, "source_speaker_labels", labels)
     end)}
  rescue
    _exception -> {:ok, effect}
  catch
    _kind, _reason -> {:ok, effect}
  end

  defp attach_source_speaker_labels(other, _payload, _opts), do: other

  defp apply_reply(
         claim,
         communication,
         freshness_port,
         reply_port,
         effect_guard,
         port_opts
       ) do
    case reply_port.lookup(claim, port_opts) do
      {:ok, {:delivered, result}} ->
        delivered_effect(claim, communication, result)

      {:ok, :not_delivered} ->
        with {:ok, %{status: :fresh} = first} <- freshness_port.check(claim, port_opts),
             {:ok, prepared} <- reply_port.prepare(claim, port_opts),
             {:ok, %{status: :fresh} = second} <- freshness_port.check(claim, port_opts),
             true <- same_authority?(first, second),
             {:ok, result} <-
               effect_guard.run(claim, second, port_opts, fn ->
                 with {:ok, provider_result} <- reply_port.deliver(claim, prepared, port_opts) do
                   reply_port.complete(claim, prepared, provider_result, port_opts)
                 end
               end) do
          delivered_effect(claim, communication, result)
        else
          {:ok, %{status: :stale, reason: reason}} ->
            stale_effect(claim, communication, reason)

          {:error, :stale_source, false} ->
            stale_effect(claim, communication, :source_authority_changed)

          false ->
            stale_effect(claim, communication, :authority_changed_during_prepare)

          {:conflict, _owner} ->
            stale_effect(claim, communication, :source_route_changed)

          {:busy, _owner} ->
            {:error, :triage_effect_busy, true}

          :unavailable ->
            {:error, :source_unavailable, true}

          {:error, reason, retryable?} when is_boolean(retryable?) ->
            {:error, reason, retryable?}

          {:error, reason, retryable?, external_writes}
          when is_boolean(retryable?) and is_integer(external_writes) and
                 external_writes >= 0 ->
            {:error, reason, retryable?, external_writes}

          {:error, reason} ->
            {:error, reason, retryable_error?(reason)}

          _other ->
            {:error, :effect_adapter_unavailable, true}
        end

      {:error, :stale_source, false} ->
        stale_effect(claim, communication, :source_authority_changed)

      {:error, reason, retryable?} when is_boolean(retryable?) ->
        {:error, reason, retryable?}

      {:error, reason, retryable?, external_writes}
      when is_boolean(retryable?) and is_integer(external_writes) and external_writes >= 0 ->
        {:error, reason, retryable?, external_writes}

      {:error, reason} ->
        {:error, reason, retryable_error?(reason)}

      _other ->
        {:error, :effect_adapter_unavailable, true}
    end
  end

  defp delivered_effect(claim, communication, result) do
    metadata =
      %{
        "obligation_id" => claim.obligation_id,
        "operation_ref" => result.operation_ref,
        "channel_id" => result.channel_id,
        "message_ts" => result.message_ts,
        "already_delivered" => result[:already_delivered] == true,
        "delivery" => "direct_slack_reply"
      }
      |> maybe_put_continuation_admission(result)

    {:ok,
     %{
       adapter: :slack,
       outcome: :applied,
       external_writes: result[:external_writes] || 0,
       communication: %{
         "kind" => "reply",
         "status" => "delivered",
         "text" => communication["text"],
         "source_refs" => communication["source_refs"] || []
       },
       metadata: metadata
     }}
  end

  defp maybe_put_continuation_admission(metadata, %{continuation_admission: admission})
       when is_map(admission),
       do: Map.put(metadata, "continuation_admission", admission)

  defp maybe_put_continuation_admission(metadata, _result), do: metadata

  defp apply_reaction(
         claim,
         communication,
         freshness_port,
         reaction_port,
         effect_guard,
         port_opts
       ) do
    with :ok <- validate_reaction_authority(claim.payload, communication["emoji"]),
         {:ok, target_ts} <- reaction_target(claim.payload) do
      case reaction_port.lookup(claim, target_ts, communication["emoji"], port_opts) do
        {:ok, :present} ->
          reaction_effect(claim, communication, %{already_reacted: true}, 0)

        {:ok, :missing} ->
          with {:ok, %{status: :fresh} = freshness} <- freshness_port.check(claim, port_opts),
               {:ok, result} <-
                 effect_guard.run(claim, freshness, port_opts, fn ->
                   reaction_port.add(claim, target_ts, communication["emoji"], port_opts)
                 end) do
            reaction_effect(claim, communication, result, 1)
          else
            {:ok, %{status: :stale, reason: reason}} -> stale_effect(claim, communication, reason)
            {:conflict, _owner} -> stale_effect(claim, communication, :source_route_changed)
            {:busy, _owner} -> {:error, :triage_effect_busy, true}
            :unavailable -> {:error, :source_unavailable, true}
            {:error, reason, retryable?} -> {:error, reason, retryable?}
            {:error, reason} -> {:error, reason, retryable_error?(reason)}
            _ -> {:error, :effect_adapter_unavailable, true}
          end

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason, retryable_error?(reason)}
    end
  end

  defp reaction_effect(claim, communication, result, writes) do
    {:ok,
     %{
       adapter: :slack,
       outcome: :applied,
       external_writes: writes,
       communication: %{
         "kind" => "reaction",
         "status" => "added",
         "emoji" => communication["emoji"],
         "source_refs" => communication["source_refs"] || []
       },
       metadata: %{
         "obligation_id" => claim.obligation_id,
         "delivery" => "slack_reaction",
         "already_reacted" => result[:already_reacted] == true
       }
     }}
  end

  @doc false
  def reaction_target(%{
        "target" => target,
        "communication" => communication,
        "target_cutoff" => cutoff
      }),
      do: decision_target_ts(target, communication, cutoff)

  def reaction_target(_payload), do: {:error, :invalid_product_obligation}

  @doc false
  def validate_reaction_authority(payload, emoji) when is_map(payload) do
    case Map.fetch(payload, "reaction_authority") do
      {:ok, authority} ->
        case ExpressionContext.validate_emoji(authority, emoji) do
          :ok -> :ok
          _invalid -> {:error, :invalid_product_obligation}
        end

      :error ->
        if emoji in ProductDecision.reaction_emojis(),
          do: :ok,
          else: {:error, :invalid_product_obligation}
    end
  end

  def validate_reaction_authority(_payload, _emoji),
    do: {:error, :invalid_product_obligation}

  defp stale_effect(claim, communication, reason) do
    communication =
      communication
      |> Map.take(~w(kind text emoji source_refs))
      |> Map.put("status", "suppressed_stale")
      |> Map.put("reason", safe_reason(reason))

    {:ok,
     %{
       adapter: :slack,
       outcome: :stale,
       external_writes: 0,
       communication: communication,
       metadata: %{"obligation_id" => claim.obligation_id}
     }}
  end

  defp decision_target_ts(
         %{
           "workspace_id" => workspace_id,
           "channel_id" => channel_id,
           "thread_ts" => thread_ts
         },
         %{"source_refs" => [source_ref]},
         %{"event_message_timestamps" => timestamps}
       )
       when is_binary(workspace_id) and is_binary(channel_id) and is_binary(thread_ts) and
              is_binary(source_ref) and is_list(timestamps) do
    with [^workspace_id, ^channel_id, ^thread_ts, timestamp] <-
           Regex.run(~r/\Aslack:\/\/([^\/]+)\/([^\/]+)\/([^\/]+)\/([^\/]+)\z/, source_ref,
             capture: :all_but_first
           ),
         {:ok, ^timestamp} <- latest_slack_timestamp(timestamps) do
      {:ok, timestamp}
    else
      _invalid -> {:error, :invalid_product_obligation}
    end
  end

  defp decision_target_ts(_target, _communication, _cutoff),
    do: {:error, :invalid_product_obligation}

  defp latest_slack_timestamp(timestamps) do
    timestamps
    |> Enum.reduce_while({:ok, nil}, fn timestamp, {:ok, latest} ->
      case slack_timestamp(timestamp) do
        {:ok, microseconds} ->
          candidate = {microseconds, timestamp}
          {:cont, {:ok, if(is_nil(latest) or candidate > latest, do: candidate, else: latest)}}

        :error ->
          {:halt, {:error, :invalid_product_obligation}}
      end
    end)
    |> case do
      {:ok, {_microseconds, timestamp}} -> {:ok, timestamp}
      _invalid -> {:error, :invalid_product_obligation}
    end
  end

  defp slack_timestamp(timestamp) when is_binary(timestamp) do
    case String.split(timestamp, ".", parts: 2) do
      [seconds, fraction] when byte_size(fraction) in 1..6 ->
        with {seconds, ""} <- Integer.parse(seconds),
             {fraction, ""} <- fraction |> String.pad_trailing(6, "0") |> Integer.parse() do
          {:ok, seconds * 1_000_000 + fraction}
        else
          _invalid -> :error
        end

      _invalid ->
        :error
    end
  end

  defp slack_timestamp(_timestamp), do: :error

  defp same_authority?(left, right), do: left.authority_ref == right.authority_ref

  defp retryable_error?(reason),
    do:
      reason in [
        :source_unavailable,
        :source_authority_unavailable,
        :slack_triage_authority_unavailable,
        :triage_reply_delivery_unavailable,
        :triage_subscription_unavailable,
        :provider_outcome_ambiguous,
        :timeout,
        :unavailable
      ] or match?({:rate_limited, _}, reason)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "stale_or_changed"
end

defmodule SalixIM.Triage.SlackEffectAdapter.EffectGuard do
  @moduledoc false

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixStore.Crypto

  def run(
        %{obligation_id: obligation_id, claim_token: claim_token},
        %{
          route_scope: route_scope,
          route_claim_identity: route_claim_identity
        },
        _opts,
        fun
      )
      when is_binary(obligation_id) and obligation_id != "" and is_binary(claim_token) and
             claim_token != "" and is_map(route_scope) and is_binary(route_claim_identity) and
             is_function(fun, 0) do
    effect_identity =
      Crypto.hex([
        "comma.slack-triage-effect.v1",
        obligation_id,
        claim_token
      ])

    ThreadRouteOwner.with_triage_effect(
      route_scope,
      route_claim_identity,
      effect_identity,
      fn _reservation -> fun.() end
    )
  end

  def run(_claim, _freshness, _opts, _fun),
    do: {:error, :invalid_product_obligation, false}
end

defmodule SalixIM.Triage.SlackEffectAdapter.Reaction do
  @moduledoc false

  alias SalixIM.Provider

  @triage_effect_request_timeout_ms 4_000

  def lookup(%{payload: payload}, timestamp, emoji, opts) do
    target = payload["target"] || %{}
    group_id = get_in(payload, ["product_identity", "project_salix_group_id"])
    connects = Keyword.get(opts, :provider_connects, SalixIM.ProviderConnects)
    api = Keyword.get(opts, :reaction_api, SalixIM.Provider.Slack.API)

    with :ok <- SalixIM.Triage.SlackEffectAdapter.validate_reaction_authority(payload, emoji),
         {:ok, ^timestamp} <- SalixIM.Triage.SlackEffectAdapter.reaction_target(payload),
         {:ok, connect} <-
           connects.get_active_connect_by_id(group_id, target["connect_id"], "slack"),
         {:ok, authority} <-
           connects.get_slack_triage_authority(
             connect["tenant_id"],
             group_id,
             target["connect_id"],
             target["channel_id"]
           ),
         true <-
           connect["workspace_id"] == target["workspace_id"] and
             authority["connect_generation"] == target["connect_generation"],
         bot when is_binary(bot) and bot != "" <- connect["bot_user_id"],
         %{
           "ok" => true,
           "type" => "message",
           "channel" => channel,
           "message" => %{"ts" => ^timestamp} = message
         } <-
           api.message_reactions(
             SalixIM.Provider.Slack.API.installation(connect),
             target["channel_id"],
             timestamp,
             timeout_ms: @triage_effect_request_timeout_ms,
             pool_retries: 0
           ),
         true <- channel == target["channel_id"],
         reactions when is_list(reactions) <- Map.get(message, "reactions", []),
         true <- Enum.all?(reactions, &(is_map(&1) and is_list(&1["users"]))) do
      present = Enum.any?(reactions, &(&1["name"] == emoji and bot in &1["users"]))
      {:ok, if(present, do: :present, else: :missing)}
    else
      _ -> {:error, :reaction_verification_unavailable, true}
    end
  rescue
    _ -> {:error, :reaction_verification_unavailable, true}
  catch
    :exit, _ -> {:error, :reaction_verification_unavailable, true}
  end

  def add(%{obligation_id: obligation_id, payload: payload}, timestamp, emoji, opts)
      when is_binary(obligation_id) and is_map(payload) and is_binary(timestamp) and
             is_binary(emoji) and is_list(opts) do
    target = payload["target"] || %{}
    identity = payload["product_identity"] || %{}
    provider = Keyword.get(opts, :provider, Provider)

    with :ok <- SalixIM.Triage.SlackEffectAdapter.validate_reaction_authority(payload, emoji),
         {:ok, ^timestamp} <- SalixIM.Triage.SlackEffectAdapter.reaction_target(payload),
         %{"emoji" => ^emoji} <- payload["communication"] do
      args = %{
        "connect_id" => target["connect_id"],
        "tool_call_id" => obligation_id,
        "params" => %{
          "channel" => target["channel_id"],
          "ts" => timestamp,
          "name" => emoji
        }
      }

      case provider.call_api(
             identity["salix_agent_id"],
             "slack",
             "slack.add_reaction",
             args,
             request_options: [
               timeout_ms: @triage_effect_request_timeout_ms,
               pool_retries: 0
             ]
           ) do
        {:ok, %{"already_reacted" => true}} -> {:ok, %{already_reacted: true}}
        {:ok, _response} -> {:ok, %{already_reacted: false}}
        {:error, reason} -> {:error, normalize_error(reason), retryable?(reason)}
        _other -> {:error, :reaction_unavailable, true}
      end
    else
      _invalid -> {:error, :invalid_product_obligation, false}
    end
  rescue
    _exception -> {:error, :reaction_unavailable, true}
  catch
    :exit, _reason -> {:error, :reaction_unavailable, true}
  end

  def add(_claim, _timestamp, _emoji, _opts),
    do: {:error, :invalid_product_obligation, false}

  defp normalize_error(reason) when is_binary(reason) do
    cond do
      String.contains?(reason, "rate_limited") -> :rate_limited
      String.contains?(reason, "not_in_channel") -> :channel_unavailable
      String.contains?(reason, "message_not_found") -> :message_unavailable
      true -> :reaction_unavailable
    end
  end

  defp normalize_error(reason) when is_atom(reason), do: reason
  defp normalize_error(_reason), do: :reaction_unavailable

  defp retryable?(reason) when is_binary(reason),
    do: not String.contains?(reason, "rate_limited")

  defp retryable?(:rate_limited), do: false
  defp retryable?(_reason), do: true
end

defmodule SalixIM.Triage.SlackEffectAdapter.Freshness do
  @moduledoc false

  alias SalixIM.Provider.Slack.ThreadRouteOwner
  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixIM.Triage.ClickHouseReader

  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/

  def check(%{payload: payload}, opts) when is_map(payload) and is_list(opts) do
    group_directory = Keyword.get(opts, :group_directory, GroupDirectory)
    provider_connects = Keyword.get(opts, :provider_connects, ProviderConnects)
    route_owner = Keyword.get(opts, :route_owner, ThreadRouteOwner)
    clickhouse_reader = Keyword.get(opts, :clickhouse_reader, ClickHouseReader.impl())
    target = payload["target"] || %{}
    identity = payload["product_identity"] || %{}
    group_id = identity["project_salix_group_id"]

    with {:ok, group} <- group_directory.get_group(group_id),
         tenant_id when is_binary(tenant_id) and tenant_id != "" <- group["tenant_id"],
         {:ok, product_authority} <-
           provider_connects.get_slack_triage_authority(
             tenant_id,
             group_id,
             target["connect_id"],
             target["channel_id"]
           ),
         :ok <- expected_product_authority(product_authority, target),
         {:ok, route} <-
           current_route_owner(
             route_owner,
             tenant_id,
             group_id,
             target
           ),
         {:ok, cutoff_ts_us} <- cutoff(payload["target_cutoff"]),
         true <-
           is_atom(clickhouse_reader) and not is_nil(clickhouse_reader) and
             function_exported?(clickhouse_reader, :read_thread, 3),
         {:ok, page} <-
           current_source_page(
             clickhouse_reader,
             %{
               "tenant_id" => tenant_id,
               "workspace_id" => target["workspace_id"],
               "channel_id" => target["channel_id"]
             },
             target,
             payload
           ) do
      authority_ref = authority_ref(product_authority, route.claim_identity)

      observed_sources =
        source_versions(payload["source_authority"] || payload["source_messages"])

      cond do
        page.complete? != true ->
          {:ok, %{status: :stale, reason: :freshness_window_incomplete}}

        source_state_changed?(
          payload["source_authority"] || payload["source_messages"],
          page.messages
        ) ->
          {:ok, %{status: :stale, reason: :source_state_changed}}

        not current_source_intake?(payload, opts) and
            Enum.any?(page.messages, fn message ->
              message["message_ts_us"] > cutoff_ts_us and
                not self_message?(message, product_authority) and
                  not MapSet.member?(
                    observed_sources,
                    {message["message_ts_us"], message["version"]}
                  )
            end) ->
          {:ok, %{status: :stale, reason: :new_source_message}}

        true ->
          {:ok,
           %{
             status: :fresh,
             authority_ref: authority_ref,
             route_scope: route.scope,
             route_claim_identity: route.claim_identity
           }}
      end
    else
      {:error, reason}
      when reason in [
             :stale_source,
             :channel_ineligible,
             :channel_authority_changed,
             :source_route_changed,
             :slack_triage_authority_ineligible
           ] ->
        {:ok, %{status: :stale, reason: reason}}

      {:error, reason} ->
        {:error, reason, retryable?(reason)}

      _invalid ->
        {:error, :invalid_product_authority, false}
    end
  rescue
    _exception -> {:error, :source_unavailable, true}
  catch
    :exit, _reason -> {:error, :source_unavailable, true}
  end

  def check(_claim, _opts), do: {:error, :invalid_product_obligation, false}

  defp current_source_intake?(payload, opts),
    do:
      Keyword.get(opts, :purpose) == :worker_intake and
        SalixIM.Triage.ProductObligation.ordinary_worker_assignment?(payload)

  defp current_source_page(reader, scope, _target, %{"source_window" => window}) do
    # Re-read all cited threads and channel activity through now in one bounded
    # query. A thread-only read would incorrectly discard sibling source refs.
    window =
      Map.put(
        window,
        "latest_ts_us",
        max(window["latest_ts_us"], System.system_time(:microsecond))
      )

    reader.read_channel(scope, window, limit: 200, max_bytes: 1_048_576)
  end

  defp current_source_page(reader, scope, target, _payload) do
    reader.read_thread(scope, target["thread_ts"], limit: 200, max_bytes: 1_048_576)
  end

  defp expected_product_authority(authority, target) do
    if authority["triage_enabled"] == true and
         authority["connect_id"] == target["connect_id"] and
         authority["connect_generation"] == target["connect_generation"] and
         authority["workspace_id"] == target["workspace_id"] and
         authority["approved_channel_id"] == target["channel_id"],
       do: :ok,
       else: {:error, :stale_source}
  end

  defp current_route_owner(route_owner, tenant_id, group_id, target) do
    scope = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => target["connect_id"],
      "connect_generation" => target["connect_generation"],
      "workspace_id" => target["workspace_id"],
      "channel_id" => target["channel_id"],
      "root_thread_ts" => target["thread_ts"]
    }

    case route_owner.lookup_claim(scope) do
      {:ok, :triage, claim_identity} when is_binary(claim_identity) ->
        {:ok, %{scope: scope, claim_identity: claim_identity}}

      {:ok, _owner, _claim_identity} ->
        {:error, :source_route_changed}

      :unavailable ->
        {:error, :source_unavailable}

      _other ->
        {:error, :source_route_changed}
    end
  end

  defp cutoff(%{"event_message_timestamps" => timestamps}) when is_list(timestamps) do
    timestamps
    |> Enum.reduce_while({:ok, nil}, fn timestamp, {:ok, latest} ->
      case slack_timestamp(timestamp) do
        {:ok, microseconds} ->
          candidate = {microseconds, timestamp}
          {:cont, {:ok, if(is_nil(latest) or candidate > latest, do: candidate, else: latest)}}

        :error ->
          {:halt, {:error, :invalid_product_obligation}}
      end
    end)
    |> case do
      {:ok, {microseconds, _timestamp}} ->
        {:ok, microseconds}

      _invalid ->
        {:error, :invalid_product_obligation}
    end
  end

  defp cutoff(_cutoff), do: {:error, :invalid_product_obligation}

  defp slack_timestamp(timestamp) when is_binary(timestamp) do
    if Regex.match?(@slack_ts, timestamp) do
      [seconds, fraction] = String.split(timestamp, ".", parts: 2)

      {:ok,
       String.to_integer(seconds) * 1_000_000 +
         String.to_integer(String.pad_trailing(fraction, 6, "0"))}
    else
      :error
    end
  end

  defp slack_timestamp(_timestamp), do: :error

  # SlackMessageMirror.Row retains bot/app attribution in actor_kind, but
  # prefers the stable Slack user principal for actor_id when it is present.
  defp self_message?(%{"actor_kind" => kind, "actor_id" => actor}, authority)
       when kind in ["app", "bot", "user"] and is_binary(actor) and actor != "" do
    actor == authority["bot_user_id"] or
      (kind == "bot" and actor == authority["bot_id"]) or
      (kind == "app" and actor == authority["app_id"])
  end

  defp self_message?(_message, _authority), do: false

  defp source_state_changed?(messages, current) when is_list(messages) and is_list(current) do
    expected =
      Enum.filter(messages, fn message ->
        is_map(message) and is_integer(message["message_ts_us"]) and
          is_integer(message["observed_version"])
      end)

    current_by_key = Map.new(current, &{&1["message_ts_us"], &1})

    Enum.any?(expected, fn message ->
      case current_by_key[message["message_ts_us"]] do
        %{"version" => version} -> version != message["observed_version"]
        _missing -> true
      end
    end)
  end

  defp source_state_changed?(_messages, _current), do: false

  defp source_versions(messages) when is_list(messages) do
    for %{"message_ts_us" => timestamp, "observed_version" => version} <- messages,
        is_integer(timestamp) and is_integer(version),
        into: MapSet.new(),
        do: {timestamp, version}
  end

  defp source_versions(_messages), do: MapSet.new()

  defp authority_ref(product, route_claim_identity) do
    {
      product["connect_generation"],
      product["workspace_id"],
      product["approved_channel_id"],
      route_claim_identity
    }
  end

  defp retryable?(reason),
    do:
      reason in [
        :source_unavailable,
        :slack_triage_authority_unavailable,
        :unavailable
      ] or match?({:rate_limited, _}, reason)
end

defmodule SalixIM.Triage.SlackEffectAdapter.Reply do
  @moduledoc false

  alias SalixIM.{GroupDirectory, ProviderConnects}
  alias SalixIM.Ports.SlackTriageReplyDelivery
  alias SalixIM.Provider.Slack.TriageThreadSubscription

  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{6}\z/

  def lookup(%{payload: payload} = claim, opts) when is_map(payload) and is_list(opts) do
    case prepare_lookup(claim, opts) do
      {:ok, prepared} ->
        with {:ok, existing} <- find_existing(prepared, opts) do
          case existing do
            nil ->
              {:ok, :not_delivered}

            status ->
              case complete(claim, prepared, status, true, 0, opts) do
                {:ok, result} -> {:ok, {:delivered, result}}
                error -> error
              end
          end
        end

      {:error, :stale_source, false} ->
        {:ok, :not_delivered}

      error ->
        error
    end
  end

  def lookup(_claim, _opts), do: {:error, :invalid_product_obligation, false}

  def prepare(%{obligation_id: obligation_id, payload: payload}, opts)
      when is_binary(obligation_id) and obligation_id != "" and is_map(payload) and
             is_list(opts) do
    provider_connects = Keyword.get(opts, :provider_connects, ProviderConnects)

    with {:ok, prepared} <-
           prepare_lookup(%{obligation_id: obligation_id, payload: payload}, opts),
         {:ok, authority} <-
           provider_connects.get_slack_triage_authority(
             prepared.tenant_id,
             prepared.group_id,
             prepared.target["connect_id"],
             prepared.target["channel_id"]
           ),
         :ok <- expected_authority(authority, prepared.target, prepared.agent_id),
         {:ok, connect} <-
           provider_connects.get_active_connect_by_id(
             prepared.group_id,
             prepared.target["connect_id"],
             "slack"
           ),
         :ok <-
           expected_connect(
             connect,
             prepared.tenant_id,
             prepared.group_id,
             prepared.target
           ) do
      {:ok, %{prepared | connect: connect}}
    else
      {:error, reason, retryable?} when is_boolean(retryable?) ->
        {:error, reason, retryable?}

      {:error, reason} ->
        normalized = normalize_prepare_error(reason)
        {:error, normalized, retryable?(normalized)}

      _invalid ->
        {:error, :invalid_product_obligation, false}
    end
  rescue
    _exception -> {:error, :triage_reply_delivery_unavailable, true}
  catch
    :exit, _reason -> {:error, :triage_reply_delivery_unavailable, true}
  end

  def prepare(_claim, _opts), do: {:error, :invalid_product_obligation, false}

  defp prepare_lookup(%{obligation_id: obligation_id, payload: payload}, opts)
       when is_binary(obligation_id) and obligation_id != "" and is_map(payload) and
              is_list(opts) do
    target = payload["target"] || %{}
    identity = payload["product_identity"] || %{}
    communication = payload["communication"] || %{}
    group_id = identity["project_salix_group_id"]
    agent_id = identity["salix_agent_id"]
    group_directory = Keyword.get(opts, :group_directory, GroupDirectory)
    provider_connects = Keyword.get(opts, :provider_connects, ProviderConnects)

    with :ok <- valid_contract(target, identity, communication, payload["run_id"]),
         {:ok, group} <- group_directory.get_group(group_id),
         tenant_id when is_binary(tenant_id) and tenant_id != "" <- group["tenant_id"],
         {:ok, connect} <-
           provider_connects.get_active_connect_by_id(group_id, target["connect_id"], "slack"),
         :ok <- expected_connect(connect, tenant_id, group_id, target) do
      {:ok,
       %{
         tenant_id: tenant_id,
         group_id: group_id,
         agent_id: agent_id,
         connect: connect,
         target: target,
         operation_ref: obligation_id,
         text: communication["text"]
       }}
    else
      {:error, reason} ->
        normalized = normalize_prepare_error(reason)
        {:error, normalized, retryable?(normalized)}

      _invalid ->
        {:error, :invalid_product_obligation, false}
    end
  rescue
    _exception -> {:error, :triage_reply_delivery_unavailable, true}
  catch
    :exit, _reason -> {:error, :triage_reply_delivery_unavailable, true}
  end

  def deliver(%{payload: payload} = claim, prepared, opts)
      when is_map(payload) and is_map(prepared) and is_list(opts) do
    post(claim, prepared, opts)
  rescue
    _exception -> {:error, :triage_reply_delivery_unavailable, true}
  catch
    :exit, _reason -> {:error, :triage_reply_delivery_unavailable, true}
  end

  def deliver(_claim, _prepared, _opts),
    do: {:error, :invalid_product_obligation, false}

  def complete(claim, prepared, {:confirmed, status}, opts),
    do: complete(claim, prepared, status, false, 1, opts)

  def complete(claim, prepared, :ambiguous, opts),
    do: verify_ambiguous(claim, prepared, opts)

  def complete(_claim, _prepared, _provider_result, _opts),
    do: {:error, :invalid_provider_confirmation, false}

  defp post(_claim, prepared, opts) do
    delivery_port = Keyword.get(opts, :reply_delivery_port, SlackTriageReplyDelivery)

    params = %{
      "channel" => prepared.target["channel_id"],
      "thread_ts" => prepared.target["thread_ts"],
      "text" => prepared.text,
      "metadata" => %{
        "event_type" => "salix_triage_reply_delivery",
        "event_payload" => %{"operation_ref" => prepared.operation_ref}
      }
    }

    case delivery_port.post_message(prepared.tenant_id, prepared.connect, params) do
      {:ok, status} ->
        {:ok, {:confirmed, status}}

      {:error, {:ambiguous, _reason}} ->
        {:ok, :ambiguous}

      {:error, reason} ->
        {:error, normalize_delivery_error(reason), retryable?(reason)}

      _other ->
        {:error, :triage_reply_delivery_unavailable, true}
    end
  end

  defp verify_ambiguous(claim, prepared, opts) do
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    sleep_fun.(verify_grace_ms(opts))

    with {:ok, existing} <- find_existing(prepared, opts) do
      case existing do
        nil -> {:error, :provider_outcome_ambiguous, true}
        status -> complete(claim, prepared, status, true, 1, opts)
      end
    end
  end

  defp find_existing(prepared, opts) do
    delivery_port = Keyword.get(opts, :reply_delivery_port, SlackTriageReplyDelivery)

    case delivery_port.find_message(
           prepared.tenant_id,
           prepared.connect,
           prepared.target["channel_id"],
           prepared.target["thread_ts"],
           prepared.operation_ref
         ) do
      {:ok, status} -> {:ok, status}
      {:error, reason} -> {:error, normalize_delivery_error(reason), retryable?(reason)}
      _other -> {:error, :triage_reply_delivery_unavailable, true}
    end
  end

  defp complete(claim, prepared, status, already_delivered?, external_writes, opts) do
    subscription_port =
      Keyword.get(opts, :triage_thread_subscription_port, TriageThreadSubscription)

    case subscription_port.after_reply(claim, {:ok, status}, opts) do
      {:ok, completed_status} ->
        case delivered_result(
               prepared,
               completed_status,
               already_delivered?,
               external_writes
             ) do
          {:ok, _result} = success ->
            success

          {:error, reason, retryable?} ->
            {:error, reason, retryable?, external_writes}
        end

      {:completion_later, _provider_result, _reason} ->
        {:error, :triage_subscription_unavailable, true, external_writes}

      {:unknown, _status, :invalid_subscription} ->
        case delivered_result(prepared, status, already_delivered?, external_writes) do
          {:ok, result} ->
            {:ok,
             Map.put(result, :continuation_admission, %{
               "status" => "not_activated",
               "reason" => "invalid_subscription"
             })}

          {:error, reason, retryable?} ->
            {:error, reason, retryable?, external_writes}
        end

      {:unknown, _status, reason} ->
        {:error, normalize_delivery_error(reason), false, external_writes}

      {:error, reason} ->
        {:error, normalize_delivery_error(reason), retryable?(reason), external_writes}

      _other ->
        {:error, :triage_subscription_unavailable, true, external_writes}
    end
  end

  defp delivered_result(prepared, status, already_delivered?, external_writes) do
    expected_channel_id = prepared.target["channel_id"]
    channel_id = status_value(status, "channel")
    message_ts = status_value(status, "ts")

    if channel_id == expected_channel_id and is_binary(message_ts) and
         Regex.match?(@slack_ts, message_ts) do
      {:ok,
       %{
         operation_ref: prepared.operation_ref,
         channel_id: channel_id,
         message_ts: message_ts,
         already_delivered: already_delivered?,
         external_writes: external_writes
       }}
    else
      {:error, :invalid_provider_confirmation, false}
    end
  end

  defp status_value(status, "channel") when is_map(status),
    do: status["channel"] || status[:channel]

  defp status_value(status, "ts") when is_map(status),
    do: status["ts"] || status[:ts]

  defp status_value(_status, _key), do: nil

  defp valid_contract(target, identity, communication, run_id) do
    required = [
      target["connect_id"],
      target["connect_generation"],
      target["workspace_id"],
      target["channel_id"],
      target["thread_ts"],
      identity["project_salix_group_id"],
      identity["salix_agent_id"],
      communication["text"],
      run_id
    ]

    if Enum.all?(required, &canonical_nonblank?/1) and
         Regex.match?(@slack_ts, target["thread_ts"]),
       do: :ok,
       else: {:error, :invalid_product_obligation}
  end

  defp expected_authority(authority, target, agent_id) do
    if authority["triage_enabled"] == true and
         authority["connect_id"] == target["connect_id"] and
         authority["connect_generation"] == target["connect_generation"] and
         authority["workspace_id"] == target["workspace_id"] and
         authority["approved_channel_id"] == target["channel_id"] and
         authority["inbound_agent_id"] == agent_id,
       do: :ok,
       else: {:error, :stale_source}
  end

  defp expected_connect(connect, tenant_id, group_id, target) do
    if connect["tenant_id"] == tenant_id and connect["group_id"] == group_id and
         connect["provider"] == "slack" and connect["connect_id"] == target["connect_id"] and
         connect["workspace_id"] == target["workspace_id"],
       do: :ok,
       else: {:error, :stale_source}
  end

  defp verify_grace_ms(opts) do
    case Keyword.get(
           opts,
           :provider_verify_grace_ms,
           Application.get_env(:salix_im, :provider_verify_grace_ms, 1_000)
         ) do
      value when is_integer(value) and value in 0..10_000 -> value
      _invalid -> 1_000
    end
  end

  defp normalize_prepare_error(reason)
       when reason in [:stale_source, :invalid_product_obligation],
       do: reason

  defp normalize_prepare_error(:slack_triage_authority_ineligible), do: :stale_source
  defp normalize_prepare_error(_reason), do: :triage_reply_delivery_unavailable

  defp normalize_delivery_error({:retry_after, _delay_ms, _reason}), do: :rate_limited
  defp normalize_delivery_error({:ambiguous, _reason}), do: :provider_outcome_ambiguous
  defp normalize_delivery_error(:verification_window_incomplete), do: :source_unavailable
  defp normalize_delivery_error(reason) when is_atom(reason), do: reason
  defp normalize_delivery_error(_reason), do: :triage_reply_delivery_unavailable

  defp retryable?(reason),
    do:
      reason not in [
        :invalid_product_obligation,
        :invalid_provider_confirmation,
        :stale_source,
        :channel_unavailable,
        :message_unavailable
      ]

  defp canonical_nonblank?(value),
    do: is_binary(value) and value != "" and value == String.trim(value)
end
