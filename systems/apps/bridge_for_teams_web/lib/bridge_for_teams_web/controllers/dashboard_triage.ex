defmodule BridgeForTeamsWeb.DashboardTriage do
  @moduledoc """
  Slack triage pages for `DashboardAPIController`: Overview (the Slack sources
  of a router Agent, their channels and monitoring switch, AI evaluation status
  and the Worker for Triage), Timeline (activity feed, batch details, heatmap)
  and Knowledge.

  The controller admits owners and admins only. A request reads the org's
  router-Agent roster once (the bounded fan-out of `Triage.router_agents/1`),
  checks the requested Agent against it, and makes at most a few bounded Salix
  reads through `BridgeForTeams.Triage`.

  Slack message text never appears in a list. `reveal/3` reads the requested
  messages, records one access audit row per message, and returns only the text
  whose audit row was stored (RFC §7).
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{ProjectKnowledge, SlackHistoryOnboarding, Triage}
  alias BridgeForTeams.SourcedContext.Grounding

  @kinds ~w(all reply reaction silence investigation)
  @max_reveal_refs 20
  @max_new_channels 20
  @max_ref_bytes 512
  @window_ms 7 * 24 * 3_600_000
  @window_quantum_ms 60_000

  # ---- Overview ----

  @doc "Every router Agent with its Slack sources: the picker and the Overview."
  def overview(org) do
    [agents, posture] =
      [fn -> Triage.router_agents(org) end, fn -> Triage.connect_posture(org) end]
      |> Enum.map(&Task.async(fn -> safely(&1) end))
      |> Task.await_many(:infinity)

    {:ok,
     %{
       "agents_status" => status(agents),
       "agents" => Enum.map(ok_list(agents), &public_agent(&1, posture)),
       "posture_status" => status(posture),
       "has_sources" => match?({:ok, %{connects: [_ | _]}}, posture),
       "unavailable_projects" =>
         case posture do
           {:ok, %{unavailable_groups: groups}} -> Enum.map(groups, & &1[:project_name])
           _ -> []
         end
     }}
  end

  @doc "The selected Agent's AI evaluation status; `refresh` drops its cached answer first."
  def evaluation(org, params) do
    with {:ok, agent, _roster} <- agent(org, params) do
      if params["refresh"] in ["1", "true"],
        do: Triage.refresh_evaluation_status(agent.salix_agent_id)

      ring = safely(fn -> Triage.ring_status(agent.salix_agent_id) end)

      {:ok,
       %{
         "readiness" =>
           case ring do
             {:ok, %{evaluation_readiness: readiness}}
             when readiness in [:ready, :unavailable, :unknown] ->
               Atom.to_string(readiness)

             # A fault or an old response shape is "unknown", never "down".
             _ ->
               "unknown"
           end,
         "checked_at_ms" =>
           case ring do
             {:ok, %{runtime: %{observed_at_ms: ms}}} when is_integer(ms) -> ms
             _ -> nil
           end
       }}
    end
  end

  @doc "One page (at most 100) of the Slack channels a source can add."
  def channels(org, params) do
    cursor = bounded(params["cursor"], 1_024)

    with {:ok, agent, _roster} <- agent(org, params),
         {:ok, connect} <- source(org, agent, params["connect"]),
         true <- channel_controls?(connect) || channels_unavailable(),
         {:ok, page} <- Triage.list_slack_channels(org, connect_ref(connect), cursor) do
      {:ok,
       %{
         "channels" =>
           for(
             channel <- page[:channels] || [],
             do: %{
               "id" => channel.id,
               "name" => channel.name,
               "private" => channel[:private?] == true
             }
           ),
         "next_cursor" => page[:next_cursor]
       }}
    else
      {:error, _status, _code, _message, _details} = error -> error
      _unavailable -> channels_unavailable()
    end
  end

  @doc "Turns a source's monitoring on or off (`enabled`)."
  def set_source(org, user, connect_id, params) do
    action = %{true => :enable, false => :disable}[params["enabled"]]

    with {:ok, agent, _roster} <- agent(org, params),
         {:ok, connect} <- source(org, agent, connect_id),
         true <- (action && switch_available?(connect, action)) || switch_denied() do
      write(org, user, connect, action)
    end
  end

  @doc "Pauses or resumes one configured channel (`enabled`)."
  def set_channel(org, user, connect_id, channel_id, params) do
    with {:ok, agent, _roster} <- agent(org, params),
         {:ok, connect} <- source(org, agent, connect_id),
         true <- is_boolean(params["enabled"]) || switch_denied(),
         true <- channel_controls?(connect) || switch_denied(),
         true <-
           Enum.any?(connect[:configured_channels] || [], &(&1.channel_id == channel_id)) ||
             switch_denied() do
      write(org, user, connect, {:set_channel, channel_id, params["enabled"]})
    end
  end

  @doc "Adds up to #{@max_new_channels} channels to a source; each is one audited write."
  def add_channels(org, user, connect_id, params) do
    ids =
      case params["channel_ids"] do
        ids when is_list(ids) -> ids |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1)
        _ -> []
      end

    with {:ok, agent, _roster} <- agent(org, params),
         {:ok, connect} <- source(org, agent, connect_id),
         true <- channel_controls?(connect) || channels_invalid(),
         ids = ids |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
         true <- (ids != [] and length(ids) <= @max_new_channels) || channels_invalid() do
      failed =
        for id <- ids,
            {:error, reason} <- [
              Triage.set_connect_triage(org, user, connect_ref(connect), {:provision, id})
            ],
            do: reason

      added = length(ids) - length(failed)

      cond do
        failed == [] ->
          {:ok,
           %{
             "notice" =>
               ngettext("1 Slack channel added.", "%{count} Slack channels added.", added)
           }}

        added > 0 ->
          {:error, 409, "partially_added",
           gettext(
             "%{added} channels were added; %{failed} could not be added. The current state was re-read.",
             added: added,
             failed: length(failed)
           ), %{}}

        true ->
          switch_error(hd(failed))
      end
    end
  end

  defp write(org, user, connect, action) do
    case Triage.set_connect_triage(org, user, connect_ref(connect), action) do
      {:ok, _posture} -> {:ok, %{"notice" => switch_notice(action)}}
      {:error, reason} -> switch_error(reason)
    end
  end

  # ProviderConnects treats disable as fail-safe: it needs no readiness or
  # channel authority. Enable needs a complete, valid source with a channel.
  defp switch_available?(connect, :disable), do: connect[:triage_enabled] == true

  defp switch_available?(connect, :enable) do
    complete?(connect) and connect[:triage_enabled] != true and
      connect[:authority_valid?] == true and (connect[:configured_channels] || []) != []
  end

  defp channel_controls?(connect) do
    complete?(connect) and connect[:channel_scope_complete?] == true and
      connect[:channel_controls_available?] == true
  end

  defp complete?(connect), do: connect[:posture_complete?] != false

  defp connect_ref(connect), do: Map.take(connect, [:connect_id, :project_id, :group_id])

  defp configured_channels(org, agent) do
    case safely(fn -> Triage.connect_posture(org) end) do
      {:ok, %{connects: connects}} ->
        for connect <- connects,
            same_ref?(connect[:inbound_agent_id], agent.salix_agent_id),
            channel <- connect[:configured_channels] || [],
            do: channel.channel_id

      _ ->
        []
    end
  end

  # The connect must be one of the selected Agent's own Slack sources.
  defp source(org, agent, connect_id) do
    with true <- is_binary(connect_id),
         {:ok, %{connects: connects}} <- Triage.connect_posture(org),
         %{} = connect <-
           Enum.find(connects, fn connect ->
             connect.connect_id == connect_id and
               same_ref?(connect[:inbound_agent_id], agent.salix_agent_id)
           end) do
      {:ok, connect}
    else
      _ ->
        {:error, 404, "source_not_found", gettext("That Slack assistant is no longer available."),
         %{}}
    end
  end

  defp switch_notice(:enable), do: gettext("Triage monitoring enabled for this assistant.")

  defp switch_notice(:disable),
    do:
      gettext(
        "Triage monitoring disabled for this assistant. Ambient messages will no longer be received, recorded, or processed. Explicit human @bot commands remain available."
      )

  defp switch_notice({:set_channel, _channel_id, true}),
    do: gettext("This channel is active in Triage.")

  defp switch_notice({:set_channel, _channel_id, false}),
    do: gettext("This channel is paused. Other configured channels are unchanged.")

  defp switch_denied,
    do:
      {:error, 422, "switch_unavailable",
       gettext("Only organization owners and admins can change Triage switches."), %{}}

  defp channels_invalid,
    do:
      {:error, 422, "invalid_channels",
       gettext("Choose one or more Slack channels from the list."), %{}}

  defp channels_unavailable,
    do:
      {:error, 503, "runtime_unavailable",
       gettext(
         "Slack's channel list cannot be refreshed right now. Your configured channels are still shown and can be managed; try adding channels again later."
       ), %{}}

  defp switch_error(:forbidden),
    do: {:error, 403, "forbidden", elem(switch_denied(), 3), %{}}

  defp switch_error(:connect_not_found),
    do:
      {:error, 404, "source_not_found",
       gettext("That connect is no longer part of this organization."), %{}}

  defp switch_error(:invalid_action),
    do:
      {:error, 422, "switch_unavailable",
       gettext("An approved channel is required before Triage authority can be provisioned."),
       %{}}

  defp switch_error(:tenant_not_ready),
    do:
      {:error, 409, "tenant_not_ready",
       gettext("This organization is not connected to Salix yet."), %{}}

  # A timeout is not an outcome: the write may have landed and lost its answer.
  defp switch_error(:timeout),
    do:
      {:error, 504, "unconfirmed",
       gettext(
         "Salix did not answer in time, so the result is unconfirmed: the change may or may not have landed. The state below was re-read after the attempt — check it before retrying."
       ), %{}}

  defp switch_error(:unavailable),
    do:
      {:error, 503, "runtime_unavailable",
       gettext(
         "Salix could not be reached, so the switch was not changed. This is a transient fault, not a missing connect — the state below was re-read; try again."
       ), %{}}

  defp switch_error(reason),
    do:
      {:error, 409, "switch_failed",
       gettext("The Triage switch could not be changed (%{reason}).",
         reason: reason_text(reason)
       ), %{}}

  # ---- Worker for Triage ----

  @doc "The Worker for new Triage tasks, one 20-row page of candidates and a preview."
  def worker(org, user, params) do
    opts = [
      filter: String.slice(text(params["query"]), 0, 128),
      inspect_worker_id: blank_to_nil(params["preview"]),
      cursor: blank_to_nil(params["cursor"])
    ]

    with {:ok, agent, _roster} <- agent(org, params) do
      case Triage.worker_configuration(org, agent, user.id, opts) do
        {:ok, view} ->
          binding = view["binding"] || %{}

          {:ok,
           %{
             "can_manage" => view["can_manage"] == true,
             "worker_id" => binding["worker_agent_id"],
             "revision" => binding["revision"],
             "worker" => public_worker(view["worker"]),
             "preview" => public_worker(view["preview_worker"]),
             "candidates" => for(worker <- view["candidates"] || [], do: public_worker(worker)),
             "next_cursor" => view["next_cursor"],
             "tools_ready" =>
               case view["capabilities"] do
                 %{} = tools -> Enum.all?(tools, fn {_tool, enabled} -> enabled == true end)
                 _ -> nil
               end
           }}

        _error ->
          {:error, 503, "runtime_unavailable", gettext("Worker configuration is unavailable."),
           %{}}
      end
    end
  end

  @doc "Saves the Worker (`worker_id`, or null to pause) against the `revision` read."
  def save_worker(org, user, params) do
    with {:ok, agent, _roster} <- agent(org, params) do
      case Triage.configure_worker(
             org,
             agent,
             user.id,
             blank_to_nil(params["worker_id"]),
             params["revision"]
           ) do
        {:ok, %{"audit_recorded" => true}} ->
          {:ok,
           %{
             "notice" => gettext("Triage Worker updated. Existing assignments keep their Worker.")
           }}

        {:ok, _result} ->
          {:ok,
           %{
             "notice" =>
               gettext(
                 "Worker updated. The audit attempt is saved, but the audit completion could not be written."
               )
           }}

        {:error, :triage_worker_conflict} ->
          {:error, 409, "worker_conflict",
           gettext(
             "The Worker selection changed in another session. Review the current selection before saving again."
           ), %{}}

        {:error, :triage_worker_unavailable} ->
          {:error, 422, "worker_unavailable",
           gettext(
             "This Worker is unavailable. Choose an active Worker in this Swarm with a ready runtime."
           ), %{}}

        {:error, :forbidden} ->
          {:error, 403, "forbidden",
           gettext("Only project administrators can change the Triage Worker."), %{}}

        {:error, :audit_unavailable} ->
          {:error, 503, "audit_unavailable",
           gettext("The audit record could not be saved. The Worker selection was not changed."),
           %{}}

        _unconfirmed ->
          {:error, 503, "unconfirmed",
           gettext(
             "Worker change was not confirmed. Check the current selection and availability before retrying."
           ), %{}}
      end
    end
  end

  defp public_worker(%{"agent_id" => id} = worker),
    do: %{
      "id" => id,
      "name" => worker["name"],
      "status" => get_in(worker, ["availability", "status"])
    }

  defp public_worker(_worker), do: nil

  # ---- Timeline ----

  @doc """
  One page of the selected Agent's activity: at most 20 outcomes and, on the
  first unfiltered page, the received messages still in processing. Source
  messages carry a reveal `ref` instead of their text.
  """
  def activity(org, params) do
    with {:ok, agent, roster} <- agent(org, params),
         {:ok, page} <- activity_page(org, agent, roster, activity_params(params)) do
      {:ok, page |> Map.update!("items", &Enum.map(&1, fn item -> Map.delete(item, :texts) end))}
    end
  end

  defp activity_params(params) do
    %{
      kind: if(params["kind"] in @kinds, do: params["kind"], else: "all"),
      channel: bounded(params["channel"], 64),
      before:
        case Integer.parse(text(params["before"])) do
          {ms, ""} when ms >= 0 -> ms
          _ -> nil
        end,
      cursor: bounded(params["cursor"], 1_024)
    }
  end

  defp activity_page(org, agent, roster, nav) do
    # Only a channel configured for the Agent's Slack sources filters; any
    # other value reads all channels.
    nav =
      if nav.channel && nav.channel not in configured_channels(org, agent),
        do: %{nav | channel: nil},
        else: nav

    opts =
      [
        limit: 20,
        context_limit: 20,
        page: true,
        include_intake: true,
        include_follow_ups: true,
        kind: nav.kind,
        router_agents: roster
      ] ++
        if(nav.cursor, do: [cursor: nav.cursor], else: []) ++
        if(nav.channel, do: [channel_id: nav.channel], else: []) ++
        if(nav.before && is_nil(nav.cursor), do: [before_ms: nav.before], else: [])

    case safely(fn -> Triage.product_activity(org, agent, opts) end) do
      {:ok, activity} ->
        {intake, intake_status} =
          case activity[:intake] do
            {:ok, %{items: items}} -> {items, "ok"}
            _ -> {[], "unavailable"}
          end

        outcomes = Enum.map(Enum.take(activity[:outcomes] || [], 20), &public_outcome(&1, intake))

        processing =
          if nav.kind == "all" and is_nil(nav.cursor),
            do:
              for(item <- intake, not is_binary(item[:outcome_ref]), do: public_processing(item)),
            else: []

        {:ok,
         %{
           "items" => Enum.sort_by(processing ++ outcomes, &{&1["at"], &1["id"]}, :desc),
           "next_cursor" => activity[:next_cursor],
           "intake_status" => intake_status,
           "follow_ups" =>
             case activity[:follow_ups] do
               {:ok, entries} -> Enum.map(entries, &public_context/1)
               _ -> nil
             end,
           "context" => Enum.map(Enum.take(activity[:context] || [], 20), &public_context/1)
         }}

      _error ->
        {:error, 503, "runtime_unavailable",
         gettext(
           "Triage activity is temporarily unavailable. Listening settings are unchanged; refresh to check again."
         ), %{}}
    end
  end

  # An outcome's source messages are matched to the received messages of its
  # batch by Slack timestamp, so they reveal (and audit) by receipt.
  defp public_outcome(item, intake) do
    received = Enum.filter(intake, &(&1[:outcome_ref] == item.event_ref))
    source = item[:source] || %{}

    messages =
      case source[:messages] || [] do
        [] ->
          received
          |> Enum.take(3)
          |> Enum.map(
            &%{
              excerpt: &1[:source_text],
              receipt_ref: &1.receipt_ref,
              connect_id: &1[:connect_id],
              actor_kind: :unknown,
              occurred_at_ms: &1[:source_at_ms],
              url: &1[:source_url]
            }
          )

        messages ->
          Enum.map(messages, fn message ->
            case Enum.find(
                   received,
                   &(is_binary(message[:message_ts]) and
                       &1[:source_message_ts] == message[:message_ts])
                 ) do
              nil ->
                message

              receipt ->
                Map.merge(message, %{
                  excerpt: receipt[:source_text],
                  receipt_ref: receipt.receipt_ref,
                  connect_id: receipt[:connect_id]
                })
            end
          end)
      end
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        ref =
          message[:receipt_ref] ||
            "outcome:#{item.event_ref}:#{message[:message_ts] || index}"

        Map.merge(message, %{ref: ref, connect_id: message[:connect_id] || source[:connect_id]})
      end)

    %{
      "kind" => "outcome",
      "id" => item.event_ref,
      "obligation_id" => item[:obligation_id],
      "at" => item[:inserted_at_ms],
      "updated_at" => item[:updated_at_ms],
      "state" => atom_text(item[:state]),
      "attempts" => item[:attempts],
      "source" => %{
        "connect_id" => source[:connect_id],
        "channel_id" => source[:channel_id],
        "thread_ts" => source[:thread_ts],
        "message_count" => source[:message_count],
        "latest_activity_at_ms" => source[:latest_activity_at_ms],
        "url" => source[:url] || Enum.find_value(messages, & &1[:url])
      },
      "messages" =>
        Enum.map(messages, fn message ->
          %{
            "ref" => message.ref,
            "speaker" => message[:speaker_label],
            "actor_kind" => atom_text(message[:actor_kind]),
            "at" => message[:occurred_at_ms],
            "files" => public_files(message[:file_attachments])
          }
        end),
      "communication" =>
        item
        |> Map.get(:communication, %{})
        |> Map.take([:kind, :reason, :status, :text, :emoji, :explanation])
        |> stringify(),
      "effect" =>
        item
        |> Map.get(:effect, %{})
        |> Map.take([:adapter, :status, :external_writes])
        |> stringify(),
      "companion" =>
        case item[:companion_reaction] do
          %{} = reaction ->
            effect = item[:companion_effect] || %{}

            %{
              "kind" => atom_text(reaction[:kind]),
              "emoji" => reaction[:emoji],
              "state" => atom_text(effect[:state]),
              "external_writes" => effect[:external_writes]
            }

          _ ->
            nil
        end,
      "evidence" => stringify(item[:evidence] || %{}),
      "context" => stringify(item[:context] || %{}),
      "related_context" => Enum.map(item[:related_context] || [], &public_context/1),
      "delegations" =>
        for(
          delegation <- item[:delegations] || [],
          do: stringify(Map.take(delegation, [:index, :status, :task]))
        ),
      texts: Map.new(messages, &{&1.ref, {&1[:excerpt], &1[:connect_id]}})
    }
  end

  defp public_processing(item) do
    %{
      "kind" => "processing",
      "id" => item.receipt_ref,
      "at" => item[:received_at_ms],
      "state" => atom_text(item[:state]),
      "terminal_status" => item[:terminal_status],
      "suggested_action" => item[:suggested_action],
      "source" => %{
        "connect_id" => item[:connect_id],
        "channel_id" => item[:source_channel],
        "thread_ts" => item[:source_thread_ts],
        "url" => item[:source_url]
      },
      "messages" => [
        %{
          "ref" => item.receipt_ref,
          "speaker" => nil,
          "actor_kind" => "human",
          "at" => item[:source_at_ms],
          "files" => nil
        }
      ],
      texts: %{item.receipt_ref => {item[:source_text], item[:connect_id]}}
    }
  end

  defp public_files(%{"total_count" => count} = catalogue) when is_integer(count) and count > 0 do
    %{
      "total" => count,
      "truncated" => catalogue["truncated"] == true,
      "items" => for(file <- catalogue["items"] || [], do: Map.take(file, ["name", "kind"]))
    }
  end

  defp public_files(_catalogue), do: nil

  defp public_context(entry) do
    %{
      "id" => entry[:context_ref],
      "kind" => entry[:kind],
      "state" => atom_text(entry[:state]),
      "resolved_reason" => entry[:resolved_reason],
      "subject" => entry[:subject],
      "value" => entry[:value],
      "confidence" => entry[:confidence],
      "source_count" => entry[:source_count],
      "basis" => entry[:follow_up_basis],
      "next_check_at_ms" => entry[:next_check_at_ms]
    }
  end

  @doc """
  Reveals up to #{@max_reveal_refs} source messages. With `activity` (the
  Timeline page the messages are on) they are read from that page; without
  it, from the messages the selected Agent's Slack sources received in the
  last 7 days (Knowledge). The audit rows are written before any text is
  returned, and a message whose row was not stored stays hidden.
  """
  def reveal(org, user, params) do
    refs = params["refs"]

    with {:ok, agent, roster} <- agent(org, params),
         true <-
           (is_list(refs) and refs != [] and length(refs) <= @max_reveal_refs and
              Enum.all?(refs, &(is_binary(&1) and byte_size(&1) <= @max_ref_bytes))) ||
             reveal_missing(),
         {:ok, texts, surface} <- reveal_source(org, agent, roster, params["activity"]) do
      found =
        for ref <- Enum.uniq(refs),
            {text, connect_id} <- [texts[ref]],
            is_binary(text),
            do: %{receipt_ref: ref, connect_id: connect_id}

      recorded =
        if found == [],
          do: MapSet.new(),
          else: Triage.record_text_reveals(org, user, found, surface: surface)

      cond do
        found == [] ->
          reveal_missing()

        MapSet.size(recorded) == 0 ->
          {:error, 503, "audit_unavailable",
           gettext("The message text could not be revealed: the access record failed to write."),
           %{}}

        true ->
          shown = Enum.filter(found, &MapSet.member?(recorded, &1.receipt_ref))
          labels = presentation(org, agent, roster, surface, shown)

          {:ok,
           %{
             "messages" =>
               Map.new(shown, fn %{receipt_ref: ref} ->
                 label = labels[ref] || %{}

                 {ref,
                  %{
                    "parts" => slack_parts(elem(texts[ref], 0), label[:mentions] || %{}),
                    "speaker" => label[:speaker_label]
                  }}
               end)
           }}
      end
    end
  end

  defp reveal_source(org, agent, roster, %{} = nav) do
    with {:ok, page} <- activity_page(org, agent, roster, activity_params(nav)) do
      {:ok, page["items"] |> Enum.map(& &1.texts) |> Enum.reduce(%{}, &Map.merge/2),
       "triage_timeline"}
    end
  end

  # Knowledge: only messages received by the selected Agent's own Slack
  # sources, so one Agent's page cannot open another Agent's messages.
  defp reveal_source(org, agent, _roster, _nav) do
    since =
      div(System.system_time(:millisecond) - @window_ms, @window_quantum_ms) * @window_quantum_ms

    with {:ok, %{connects: connects}} <- safely(fn -> Triage.connect_posture(org) end),
         {:ok, %{receipts: receipts}} <- safely(fn -> Triage.recent_window(org, since) end) do
      own =
        for connect <- connects,
            same_ref?(connect[:inbound_agent_id], agent.salix_agent_id),
            into: MapSet.new(),
            do: connect.connect_id

      {:ok,
       for(
         receipt <- receipts,
         MapSet.member?(own, receipt["connect_id"]),
         into: %{},
         do:
           {receipt["receipt_ref"],
            {get_in(receipt, ["triage_event", "text"]), receipt["connect_id"]}}
       ), "triage_knowledge"}
    else
      _error ->
        {:error, 503, "runtime_unavailable",
         gettext(
           "Slack receipt details are unavailable, so source references remain visible but message text cannot be opened."
         ), %{}}
    end
  end

  # Received Slack messages carry the sender's display name and mention labels
  # in a separate read, made only for messages that were revealed.
  defp presentation(org, agent, roster, "triage_timeline", shown) do
    refs = for %{receipt_ref: ref} <- shown, not String.starts_with?(ref, "outcome:"), do: ref

    case refs != [] && safely(fn -> Triage.source_presentation(org, agent, refs, roster) end) do
      {:ok, labels} when is_map(labels) -> labels
      _ -> %{}
    end
  end

  defp presentation(_org, _agent, _roster, _surface, _shown), do: %{}

  defp reveal_missing,
    do:
      {:error, 404, "message_not_found", gettext("That timeline item is no longer available."),
       %{}}

  @tokens ~r/<(?:@[UW][A-Z0-9]{2,31}(?:\|[^>]*)?|https?:\/\/[^>]+)>/

  # Slack markup as text, mention and link parts. A mention without a known
  # label never shows the raw member id, and only http(s) links are links.
  defp slack_parts(text, mentions) do
    @tokens
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn token ->
      if Regex.run(@tokens, token) == [token],
        do: token_part(token, mentions),
        else: %{"kind" => "text", "text" => decode(token)}
    end)
  end

  defp token_part("<@" <> rest, mentions) do
    actor = rest |> String.trim_trailing(">") |> String.split("|") |> hd()
    label = mentions[actor]

    label =
      if is_binary(label) and label != "" and label != actor,
        do: label,
        else: gettext("Slack participant")

    %{"kind" => "mention", "text" => "@" <> String.trim_leading(label, "@")}
  end

  defp token_part("<" <> rest = token, _mentions) do
    [url | label] = rest |> String.trim_trailing(">") |> String.split("|", parts: 2)
    url = decode(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        %{"kind" => "link", "url" => url, "text" => decode(List.first(label) || url)}

      _ ->
        %{"kind" => "text", "text" => decode(token)}
    end
  end

  defp decode(text),
    do:
      text
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&amp;", "&")

  @doc "Hourly outcome counts per channel for the last 7 days."
  def heatmap(org, params) do
    with {:ok, agent, roster} <- agent(org, params) do
      case Triage.product_heatmap(org, agent, roster) do
        {:ok, heatmap} ->
          {:ok,
           %{
             "since_ms" => heatmap[:since_ms],
             "truncated" => heatmap[:truncated] == true,
             "cells" =>
               for(
                 cell <- heatmap[:cells] || [],
                 do:
                   cell
                   |> Map.take([
                     :connect_id,
                     :channel_id,
                     :at_ms,
                     :reply,
                     :reaction,
                     :silence,
                     :total
                   ])
                   |> stringify()
               )
           }}

        _error ->
          {:error, 503, "runtime_unavailable",
           gettext("Processing status is unavailable. Refresh to retry."), %{}}
      end
    end
  end

  @doc "The processing evidence of one received message."
  def processing(org, params) do
    with {:ok, agent, roster} <- agent(org, params),
         ref when is_binary(ref) and byte_size(ref) <= @max_ref_bytes <- params["ref"],
         {:ok, %{state: state} = item} when state != :unavailable <-
           safely(fn -> Triage.processing_detail(org, agent, ref, roster) end) do
      diagnostics = item[:diagnostics] || %{}
      evaluator = diagnostics[:evaluator]

      {:ok,
       %{
         "state" => atom_text(state),
         "terminal_status" => item[:terminal_status],
         "suggested_action" => item[:suggested_action],
         "source" =>
           diagnostics
           |> Map.get(:source, %{})
           |> Map.take([:thread_ts, :addressing_kind, :source_mode, :trigger_kind])
           |> stringify(),
         "milestones" => stringify(diagnostics[:milestones] || %{}),
         "evaluator" =>
           evaluator &&
             evaluator
             |> Map.take([
               :model,
               :provider,
               :prompt_ref,
               :policy_ref,
               :request_count,
               :tool_names,
               :retry
             ])
             |> stringify(),
         "trace_ref" => diagnostics[:trace_ref],
         "decision_reason" => diagnostics[:decision_reason]
       }}
    else
      {:error, _status, _code, _message, _details} = error ->
        error

      _unavailable ->
        {:error, 503, "runtime_unavailable",
         gettext("Batch evidence is unavailable. The recorded processing status is still shown."),
         %{}}
    end
  end

  @doc "The Task of one delegation (index 0 or 1) and its latest 20 messages."
  def delegation(org, user, params) do
    with {:ok, agent, roster} <- agent(org, params),
         obligation when is_binary(obligation) and obligation != "" <-
           bounded(params["obligation"], 256),
         index when index in [0, 1] <- %{"0" => 0, "1" => 1, 0 => 0, 1 => 1}[params["index"]] do
      case Triage.delegation_task_preview(org, agent, user.id, obligation, index, roster) do
        {:ok, %{"disposition" => "created", "conversation_id" => id} = task}
        when is_binary(id) and id != "" ->
          {:ok,
           %{
             "state" => "created",
             "href" => "/orgs/#{org.slug}/projects/#{agent.project_id}/tasks/#{id}",
             "preview" => task_preview(task)
           }}

        {:ok, %{"disposition" => "not_created"}} ->
          {:ok, %{"state" => "not_created", "href" => nil, "preview" => nil}}

        {:ok, %{"disposition" => "reserved_task_unavailable"}} ->
          {:ok, %{"state" => "unavailable", "href" => nil, "preview" => nil}}

        _error ->
          {:error, 503, "runtime_unavailable", gettext("Task lookup is unavailable. Try again."),
           %{}}
      end
    else
      {:error, _status, _code, _message, _details} = error ->
        error

      _invalid ->
        {:error, 404, "delegation_not_found", gettext("That delegation is no longer available."),
         %{}}
    end
  end

  defp task_preview(%{"conversation" => %{} = conversation} = task) do
    %{
      "title" => conversation["title"],
      "status" => conversation["status"],
      "delivery_error" =>
        is_map(get_in(conversation, ["metadata", "triage_investigation_state", "delivery_error"])),
      "participation" => task["participation_result"],
      "messages" =>
        for message <- task["messages"] || [] do
          %{
            "id" => message["message_id"],
            "actor" =>
              if(message["actor_type"] == "agent",
                do: message["agent_name"] || message["role_label"],
                else: message["display_name"] || message["role_label"]
              ),
            "at" => message["created_at"],
            "text" =>
              for(
                %{"type" => "text", "text" => text} <- List.wrap(message["content"]),
                is_binary(text),
                do: text
              )
              |> Enum.join("\n")
          }
        end
    }
  end

  defp task_preview(_task), do: nil

  # ---- Knowledge ----

  @doc "The selected Agent's project knowledge, Triage context and imported Slack knowledge."
  def knowledge(org, user, params) do
    with {:ok, agent, _roster} <- agent(org, params) do
      [knowledge, imported] =
        [
          fn -> ProjectKnowledge.list_for_agent(agent.agent_id) end,
          fn -> Grounding.list_active_context_for_agent(agent.agent_id, user.id) end
        ]
        |> Enum.map(&Task.async(fn -> safely(&1) end))
        |> Task.await_many(:infinity)

      {:ok,
       knowledge
       |> public_knowledge()
       |> Map.put("imported", %{
         "status" =>
           case imported do
             {:ok, _} -> "ok"
             :none -> "off"
             _ -> "unavailable"
           end,
         "grounding" => SlackHistoryOnboarding.readiness().grounding?,
         "items" =>
           case imported do
             {:ok, %{items: items}} -> Enum.map(items, &public_imported/1)
             _ -> []
           end
       })}
    end
  end

  defp public_knowledge({:ok, result}) do
    %{
      "status" => "ok",
      "assertions" =>
        for assertion <- result.assertions do
          %{
            "id" => assertion.id,
            "kind" => Atom.to_string(assertion.kind),
            "content" => assertion.content,
            "observed_at" => assertion.observed_at,
            "source" => assertion.source,
            "subjects" =>
              for(
                subject <- assertion.subjects,
                do: Map.take(subject, [:kind, :id, :name]) |> stringify()
              ),
            "uses" =>
              for use <- assertion.uses do
                %{
                  "id" =>
                    Enum.join(
                      [use["session_id"], use["retrieval_id"], use["assistant_message_id"]],
                      ":"
                    ),
                  "session_id" => use["session_id"],
                  "used_at" => use["used_at"],
                  "excerpt" => use["assistant_excerpt"]
                }
              end
          }
        end,
      "members" =>
        for(
          member <- result.members,
          do: %{
            "id" => member.id,
            "name" => member.name,
            "role" => member.role,
            "source_ref" => member.source.ref
          }
        ),
      "retained" =>
        for(
          item <- result.retained_context,
          do:
            item
            |> Map.take([:id, :kind, :name, :content, :confidence, :source_count, :updated_at_ms])
            |> stringify()
        ),
      "usage" => if(result.usage_status == :available, do: "available", else: "unavailable"),
      "usage_complete" => result.usage_complete,
      "retained_status" =>
        if(result.retained_context_status == :available, do: "available", else: "unavailable"),
      "incomplete" =>
        not result.assertions_complete or not result.entities_complete or
          not result.members_complete or
          (result.retained_context_status == :available and not result.retained_context_complete)
    }
  end

  defp public_knowledge(_error), do: %{"status" => "unavailable"}

  defp public_imported(item) do
    %{
      "id" => item.id,
      "kind" => atom_text(item.kind),
      "name" => Map.get(item, :name) || Map.get(item, :content),
      "aliases" => Map.get(item, :aliases, []),
      "source_refs" =>
        for(%{type: "sourced_context_object", ref: ref} <- item.source_refs, do: ref)
    }
  end

  # ---- Agents ----

  # The requested router Agent, checked against the org's current roster.
  defp agent(org, params) do
    case safely(fn -> Triage.router_agents(org) end) do
      {:ok, agents} ->
        case Enum.find(agents, &(&1.agent_id == params["agent"])) do
          nil ->
            {:error, 404, "agent_not_found", gettext("That Agent is no longer available."), %{}}

          agent ->
            {:ok, agent, {:ok, agents}}
        end

      _error ->
        {:error, 503, "runtime_unavailable",
         gettext("%{label} is unavailable", label: gettext("Agents")), %{}}
    end
  end

  defp public_agent(agent, posture) do
    {sources, incomplete?} =
      case posture do
        {:ok, %{connects: connects, unavailable_groups: groups}} ->
          {connects
           |> Enum.filter(&same_ref?(&1[:inbound_agent_id], agent.salix_agent_id))
           |> Enum.sort_by(&{bot_name(&1) || "", &1[:workspace_name] || "", &1.connect_id}),
           Enum.any?(
             groups,
             &(same_ref?(&1[:project_id], agent.project_id) or
                 same_ref?(&1[:group_id], agent.group_id))
           )}

        _ ->
          {[], true}
      end

    %{
      "id" => agent.agent_id,
      "name" => agent_name(agent),
      "project_id" => agent.project_id,
      "project_name" => agent.project_name,
      "state" =>
        cond do
          incomplete? and sources == [] -> "unavailable"
          incomplete? -> "partial"
          sources == [] -> "empty"
          true -> "ready"
        end,
      "sources" =>
        for connect <- sources do
          %{
            "connect_id" => connect.connect_id,
            "bot_name" => bot_name(connect),
            "bot_username" => present(connect[:bot_username]),
            "workspace_name" => present(connect[:workspace_name]),
            "complete" => complete?(connect),
            "enabled" => connect[:triage_enabled] == true,
            "authority_valid" => connect[:authority_valid?] == true,
            "channel_scope_complete" => connect[:channel_scope_complete?],
            "channel_controls" => connect[:channel_controls_available?] == true,
            "channels" =>
              for(
                channel <- connect[:configured_channels] || [],
                do: %{
                  "id" => channel.channel_id,
                  "name" => channel[:channel_name],
                  "enabled" => channel[:enabled] == true
                }
              )
          }
        end
    }
  end

  # "Router" is an execution role, not a name; such an Agent goes by its project.
  defp agent_name(%{agent_name: name, project_name: project}) do
    if is_binary(name) and String.trim(name) != "" and
         String.downcase(String.trim(name)) != "router",
       do: name,
       else: project
  end

  defp bot_name(connect), do: present(connect[:app_name]) || present(connect[:bot_username])

  # ---- helpers ----

  defp safely(read) do
    read.()
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp status({:ok, _value}), do: "ok"
  defp status(_error), do: "unavailable"

  defp ok_list({:ok, list}) when is_list(list), do: list
  defp ok_list(_error), do: []

  defp stringify(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), atom_text(value)} end)

  defp atom_text(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp atom_text(value), do: value

  defp same_ref?(left, right) when not is_nil(left) and not is_nil(right),
    do: to_string(left) == to_string(right)

  defp same_ref?(_left, _right), do: false

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  # A JSON body carries numbers (the Timeline's `before`), a query string text.
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_value), do: ""

  defp blank_to_nil(value), do: present(text(value))

  defp bounded(value, max) do
    case blank_to_nil(value) do
      text when is_binary(text) and byte_size(text) <= max -> text
      _ -> nil
    end
  end

  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
