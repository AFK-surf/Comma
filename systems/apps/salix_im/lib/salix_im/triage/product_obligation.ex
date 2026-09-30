defmodule SalixIM.Triage.ProductObligation do
  @moduledoc """
  Materializes one source-authorized product effect obligation.

  The model sees pseudonymous references. This module runs only after the
  terminal fence revalidates, reverses those references to sealed provider
  authority, and creates the immutable payload committed beside the terminal.
  New Slack investigations with a selected Worker defer initial communication
  to that Task. Scheduled rechecks retain their existing delivery obligations.
  It performs no provider or context mutation.
  """

  alias SalixIM.Triage.ChannelBatch
  alias SalixIM.Triage.CanonicalJSON
  alias SalixIM.Triage.ExpressionContext
  alias SalixIM.Triage.FileAttachments
  alias SalixIM.Triage.IdentityContract
  alias SalixIM.Triage.ProductDecision
  alias SalixIM.Triage.RunFence.AuthorizedProductEffects

  @schema "comma.triage-product-obligation.v1"
  @required_authority ~w(connect_id connect_generation workspace_id channel_id thread_ts)
  @required_identity ~w(project_id project_salix_group_id agent_id salix_agent_id)
  @source_actor_kinds ~w(agent human system unknown)
  @source_excerpt_graphemes 280
  @source_message_limit 3
  @source_authority_limit 200

  @spec prepare(String.t(), String.t(), AuthorizedProductEffects.t()) ::
          {:ok, map()} | {:error, :invalid_triage_product_obligation}
  def prepare(namespace, fence_key, %AuthorizedProductEffects{} = authorization)
      when is_binary(namespace) and namespace != "" and is_binary(fence_key) and
             fence_key != "" do
    decision = get_in(authorization.fence, ["terminal", "decision"])
    authority = authorization.raw_bundle["source_authority"]
    identity = authorization.raw_bundle["product_identity"]
    cutoff = effect_cutoff(authorization.raw_bundle["target_cutoff"])
    aliases = get_in(authorization.alias_map, ["sources"])

    expression_context =
      get_in(authorization.raw_bundle, ["raw_context", "slack_context", "expression_context"])

    target =
      if is_map(authority),
        do:
          authority
          |> ChannelBatch.target(authorization.raw_bundle["sealed_events"])
          |> Map.take(@required_authority),
        else: authority

    product_identity =
      if is_map(identity), do: Map.take(identity, @required_identity), else: identity

    with true <- valid_authority?(target),
         true <- valid_identity?(product_identity),
         true <- valid_cutoff?(cutoff),
         {:ok, sources} <- invert_aliases(aliases),
         {:ok, communication} <- restore_refs(decision["communication"], sources),
         {:ok, reaction_authority} <-
           communication_reaction_authority(communication, expression_context),
         {:ok, context_candidates} <- restore_refs(decision["context_candidates"], sources),
         {:ok, context_candidates} <-
           bind_recheck_context(
             context_candidates,
             recheck_refs(authorization.raw_bundle),
             Map.values(sources)
           ),
         {:ok, delegations} <- restore_refs(decision["delegations"], sources),
         {:ok, delegations} <-
           SalixIM.Triage.WorkerSelection.restore(
             delegations,
             authorization.raw_bundle["product_context"],
             aliases
           ),
         {:ok, cited_slack_refs} <- cited_slack_refs(decision, sources),
         {:ok, source_messages, source_authority} <-
           source_evidence(authorization.raw_bundle, cited_slack_refs) do
      base = %{
        "schema" => @schema,
        "namespace" => namespace,
        "fence_key" => fence_key,
        "run_id" => authorization.run_id,
        "target" => target,
        "product_identity" => product_identity,
        "source_messages" => source_messages,
        "source_authority" => source_authority,
        "communication" => communication,
        "context_candidates" => attribute_context(context_candidates, authorization.raw_bundle),
        "delegations" => delegations,
        "target_cutoff" => cutoff,
        "settled_at" => get_in(authorization.fence, ["terminal", "settled_at"])
      }

      base
      |> put_expression_context(expression_context)
      |> put_context_sources(authorization.raw_bundle)
      |> put_source_window(authorization.raw_bundle)
      |> put_recheck_events(authorization.raw_bundle)
      |> maybe_put_reaction_authority(reaction_authority)
      |> withhold_initial_investigation_communication()
      |> put_ordinary_worker_assignment(authorization.fence)
      |> put_obligation_id()
    else
      _invalid -> {:error, :invalid_triage_product_obligation}
    end
  end

  def prepare(_namespace, _fence_key, _authorization),
    do: {:error, :invalid_triage_product_obligation}

  defp put_ordinary_worker_assignment(obligation, fence) do
    if get_in(fence, ["terminal", "evaluator", "schema"]) ==
         "comma.triage-worker-assignment.v1" and ordinary_assignment_shape?(obligation),
       do: Map.put(obligation, "ordinary_worker_assignment", true),
       else: obligation
  end

  @doc "Identifies domain-assigned intake; historical model decisions remain strict."
  def ordinary_worker_assignment?(obligation) when is_map(obligation),
    do:
      obligation["ordinary_worker_assignment"] == true and ordinary_assignment_shape?(obligation)

  def ordinary_worker_assignment?(_), do: false

  defp ordinary_assignment_shape?(obligation) do
    obligation["communication"] == SalixIM.Triage.WorkerSelection.pending_communication() and
      obligation["context_candidates"] == [] and
      Map.get(obligation, "recheck_event_ids", []) == [] and
      not Map.has_key?(obligation, "reaction_authority") and
      match?(
        [%{"worker_ref" => "comma-agent://" <> worker}] when worker != "",
        obligation["delegations"]
      )
  end

  defp put_expression_context(obligation, nil), do: obligation

  defp put_expression_context(obligation, context),
    do: Map.put(obligation, "expression_context", context)

  # Retain the already bounded project Knowledge projection for the selected
  # Worker. It is read separately because its audience differs from Slack.
  defp put_context_sources(obligation, raw_bundle) do
    sources =
      get_in(raw_bundle, ["product_context", "facts"])
      |> List.wrap()
      |> Enum.filter(
        &(&1["kind"] in ~w(retained_project_fact retained_decision retained_follow_up))
      )
      |> Enum.take(20)
      |> Enum.map(&Map.take(&1, ~w(kind text source_ref)))

    if sources == [], do: obligation, else: Map.put(obligation, "context_sources", sources)
  end

  def attribute_context(candidates, raw_bundle) do
    messages = get_in(raw_bundle, ["raw_context", "slack_context", "messages"]) || []
    workspace = get_in(raw_bundle, ["source_authority", "workspace_id"])
    project_id = get_in(raw_bundle, ["product_identity", "project_id"])

    Enum.map(candidates, fn candidate ->
      if candidate["knowledge_scope"] in ["person", "project"] do
        cited = Enum.filter(messages, &(&1["source_ref"] in candidate["source_refs"]))
        attribution = Enum.map(cited, &Map.take(&1, ~w(source_ref actor_id message_ts)))
        authors = cited |> Enum.map(&{&1["actor_kind"], &1["actor_id"]}) |> Enum.uniq()
        candidate = Map.put(candidate, "source_attribution", attribution)

        case {candidate["knowledge_scope"], authors} do
          {"person", [{"human", actor}]} when is_binary(actor) and actor != "" ->
            Map.put(candidate, "scope_owner", %{
              "kind" => "person",
              "id" => "slack-user://#{workspace}/#{actor}"
            })

          {"project", _} ->
            Map.put(candidate, "scope_owner", %{"kind" => "project", "id" => project_id})

          _ ->
            Map.put(candidate, "knowledge_scope", "unattributed")
        end
      else
        candidate
      end
    end)
  end

  @doc "Materializes the legacy-compatible primary obligation and optional companion reaction."
  @spec prepare_all(String.t(), String.t(), AuthorizedProductEffects.t()) ::
          {:ok, %{primary: map(), companion: map() | nil}}
          | {:error, :invalid_triage_product_obligation}
  def prepare_all(namespace, fence_key, %AuthorizedProductEffects{} = authorization) do
    companion_reaction =
      get_in(authorization.fence, ["terminal", "decision", "companion_reaction"])

    with {:ok, primary} <- prepare(namespace, fence_key, authorization),
         {:ok, companion} <- companion_obligation(primary, companion_reaction, authorization) do
      # Validate the original companion before withholding its provider effect.
      companion = if initial_worker_investigation?(primary), do: nil, else: companion
      {:ok, %{primary: primary, companion: companion}}
    end
  end

  def prepare_all(_namespace, _fence_key, _authorization),
    do: {:error, :invalid_triage_product_obligation}

  defp withhold_initial_investigation_communication(obligation) do
    if initial_worker_investigation?(obligation) and
         obligation["communication"]["kind"] != "silence" do
      obligation
      |> Map.delete("reaction_authority")
      |> Map.put("communication", %{
        "kind" => "silence",
        "reason" => "insufficient_evidence",
        "explanation" =>
          "The Worker owns the investigation result; no preliminary message is sent.",
        "source_refs" => obligation["communication"]["source_refs"] || []
      })
    else
      obligation
    end
  end

  defp initial_worker_investigation?(obligation) do
    # A scheduled reminder has an existing delivery/settlement contract. Its
    # Worker completion cannot settle the original reminder obligation.
    Map.get(obligation, "recheck_event_ids", []) == [] and
      Enum.any?(obligation["delegations"], &is_binary(&1["worker_ref"]))
  end

  @spec valid?(term()) :: boolean()
  def valid?(%{} = obligation) do
    base = Map.delete(obligation, "obligation_id")

    base_keys =
      ~w(
        schema obligation_id namespace fence_key run_id target product_identity communication
        context_candidates delegations target_cutoff settled_at
      )

    accepted_keys = [
      base_keys,
      ["source_messages" | base_keys],
      ["source_authority", "source_messages" | base_keys],
      ["reaction_authority" | base_keys],
      ["reaction_authority", "source_messages" | base_keys],
      ["reaction_authority", "source_authority", "source_messages" | base_keys]
    ]

    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["recheck_event_ids" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["recheck_context_refs" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["source_window" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["context_sources" | &1])
    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["expression_context" | &1])

    accepted_keys = accepted_keys ++ Enum.map(accepted_keys, &["ordinary_worker_assignment" | &1])

    Enum.any?(accepted_keys, &exact_keys?(obligation, &1)) and
      (not Map.has_key?(obligation, "ordinary_worker_assignment") or
         ordinary_worker_assignment?(obligation)) and
      (not Map.has_key?(obligation, "expression_context") or
         ExpressionContext.valid?(obligation["expression_context"])) and
      valid_context_sources?(Map.get(obligation, "context_sources", [])) and
      valid_source_window?(obligation) and
      valid_recheck_events?(Map.get(obligation, "recheck_event_ids", [])) and
      valid_recheck_refs?(Map.get(obligation, "recheck_context_refs", [])) and
      obligation["schema"] == @schema and
      is_binary(obligation["namespace"]) and obligation["namespace"] != "" and
      is_binary(obligation["fence_key"]) and obligation["fence_key"] != "" and
      is_binary(obligation["run_id"]) and obligation["run_id"] != "" and
      valid_authority?(obligation["target"]) and
      valid_identity?(obligation["product_identity"]) and
      valid_source_messages?(Map.get(obligation, "source_messages", [])) and
      valid_source_authority?(Map.get(obligation, "source_authority", [])) and
      valid_communication?(
        obligation["communication"],
        Map.get(obligation, "reaction_authority")
      ) and
      valid_reaction_authority?(obligation) and
      is_list(obligation["context_candidates"]) and
      Enum.all?(obligation["context_candidates"], &valid_effect_refs?/1) and
      is_list(obligation["delegations"]) and
      Enum.all?(obligation["delegations"], &valid_effect_refs?/1) and
      valid_cutoff?(obligation["target_cutoff"]) and
      is_integer(obligation["settled_at"]) and obligation["settled_at"] > 0 and
      match?({:ok, _bytes}, CanonicalJSON.encode(base)) and
      obligation["obligation_id"] == obligation_id(base)
  end

  def valid?(_obligation), do: false

  defp valid_context_sources?(sources) when is_list(sources) and length(sources) <= 20 do
    Enum.all?(sources, fn source ->
      is_map(source) and exact_keys?(source, ~w(kind text source_ref)) and
        source["kind"] in ~w(retained_project_fact retained_decision retained_follow_up) and
        is_binary(source["text"]) and byte_size(source["text"]) <= 16_000 and
        is_binary(source["source_ref"]) and
        String.starts_with?(source["source_ref"], "triage-context://")
    end)
  end

  defp valid_context_sources?(_), do: false

  defp put_source_window(obligation, raw_bundle) do
    if ChannelBatch.channel?(raw_bundle["source_authority"]),
      do: Map.put(obligation, "source_window", ChannelBatch.window(raw_bundle["sealed_events"])),
      else: obligation
  end

  defp valid_source_window?(%{"source_window" => window} = obligation) when is_map(window) do
    roots = window["thread_roots"]
    oldest = window["oldest_ts_us"]
    latest = window["latest_ts_us"]
    timestamps = get_in(obligation, ["target_cutoff", "event_message_timestamps"])

    exact_keys?(window, ~w(oldest_ts_us latest_ts_us thread_roots)) and
      is_integer(oldest) and oldest >= 0 and is_integer(latest) and latest >= oldest and
      is_list(roots) and length(roots) in 1..200 and roots == Enum.sort(Enum.uniq(roots)) and
      Enum.all?(roots, &(is_binary(&1) and Regex.match?(~r/\A[0-9]{1,12}\.[0-9]{1,6}\z/, &1))) and
      get_in(obligation, ["target", "thread_ts"]) in roots and
      valid_cutoff?(obligation["target_cutoff"]) and
      oldest == timestamps |> Enum.map(&ChannelBatch.micros/1) |> Enum.min() and
      latest == timestamps |> Enum.map(&ChannelBatch.micros/1) |> Enum.max()
  end

  defp valid_source_window?(%{"source_window" => _invalid}), do: false
  defp valid_source_window?(_obligation), do: true

  defp put_recheck_events(obligation, raw_bundle) do
    event_ids =
      raw_bundle
      |> Map.get("sealed_events", [])
      |> Enum.filter(&(&1["source_mode"] == "scheduled_recheck"))
      |> Enum.map(& &1["event_id"])
      |> Enum.uniq()

    if event_ids == [] do
      obligation
    else
      obligation
      |> Map.put("recheck_event_ids", event_ids)
      |> Map.put("recheck_context_refs", recheck_refs(raw_bundle))
    end
  end

  # The receipt owns the identity of scheduled work. Rewording a candidate
  # cannot turn a recheck into new work. An independent goal must say create.
  defp recheck_refs(raw_bundle) do
    raw_bundle
    |> Map.get("sealed_events", [])
    |> Enum.filter(&(&1["source_mode"] == "scheduled_recheck"))
    |> Enum.map(& &1["recheck_context_ref"])
    |> Enum.uniq()
  end

  @doc false
  def bind_recheck_context(candidates, refs, sources) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      if candidate["kind"] == "follow_up" and refs != [] and
           candidate["follow_up_action"] != "create" and
           not Map.has_key?(candidate, "follow_up_ref") do
        with ["triage-context://" <> _ = ref] <- refs,
             true <- ref in sources,
             source_refs = Enum.uniq([ref | candidate["source_refs"]]),
             true <- length(source_refs) <= 20 do
          updated =
            candidate |> Map.put("follow_up_ref", ref) |> Map.put("source_refs", source_refs)

          {:cont, {:ok, [updated | acc]}}
        else
          _ -> {:halt, {:error, :invalid_triage_product_obligation}}
        end
      else
        {:cont, {:ok, [candidate | acc]}}
      end
    end)
    |> case do
      {:ok, bound} -> {:ok, Enum.reverse(bound)}
      error -> error
    end
  end

  defp valid_recheck_refs?(refs) when is_list(refs) do
    length(refs) <= @source_authority_limit and
      Enum.all?(refs, fn
        nil -> true
        "triage-context://" <> id -> byte_size(id) in 1..2000
        _ -> false
      end)
  end

  defp valid_recheck_refs?(_), do: false

  defp valid_recheck_events?(event_ids) when is_list(event_ids) do
    length(event_ids) <= @source_authority_limit and
      Enum.all?(event_ids, &(is_binary(&1) and String.starts_with?(&1, "recheck:")))
  end

  defp valid_recheck_events?(_event_ids), do: false

  defp obligation_id(base) do
    {:ok, bytes} = CanonicalJSON.encode(base)
    "triage-product-" <> CanonicalJSON.sha256(bytes)
  end

  defp companion_obligation(_primary, nil, _authorization), do: {:ok, nil}

  defp companion_obligation(primary, %{"kind" => "reaction"} = reaction, authorization) do
    expression_context =
      get_in(authorization.raw_bundle, ["raw_context", "slack_context", "expression_context"])

    with {:ok, sources} <- invert_aliases(get_in(authorization.alias_map, ["sources"])),
         {:ok, restored_reaction} <- restore_refs(reaction, sources),
         {:ok, reaction_authority} <-
           reaction_authority(expression_context, restored_reaction["emoji"]) do
      primary
      |> Map.delete("obligation_id")
      |> Map.put("communication", restored_reaction)
      |> maybe_put_reaction_authority(reaction_authority)
      |> Map.put("context_candidates", [])
      |> Map.put("delegations", [])
      |> put_obligation_id()
    end
  end

  defp companion_obligation(_primary, _reaction, _authorization),
    do: {:error, :invalid_triage_product_obligation}

  defp reaction_authority(nil, emoji) do
    if emoji in ProductDecision.reaction_emojis(),
      do: {:ok, nil},
      else: {:error, :invalid_triage_product_obligation}
  end

  defp reaction_authority(expression_context, emoji) do
    case ExpressionContext.validate_emoji(expression_context, emoji) do
      :ok -> {:ok, expression_context}
      _invalid -> {:error, :invalid_triage_product_obligation}
    end
  end

  defp communication_reaction_authority(
         %{"kind" => "reaction", "emoji" => emoji},
         expression_context
       ),
       do: reaction_authority(expression_context, emoji)

  defp communication_reaction_authority(_communication, _expression_context), do: {:ok, nil}

  defp maybe_put_reaction_authority(obligation, nil), do: obligation

  defp maybe_put_reaction_authority(obligation, reaction_authority),
    do: Map.put(obligation, "reaction_authority", reaction_authority)

  defp valid_reaction_authority?(%{
         "communication" => %{"kind" => "reaction", "emoji" => emoji},
         "reaction_authority" => authority
       }),
       do: ExpressionContext.validate_emoji(authority, emoji) == :ok

  defp valid_reaction_authority?(%{"communication" => %{"kind" => "reaction", "emoji" => emoji}}),
    do: emoji in ProductDecision.reaction_emojis()

  defp valid_reaction_authority?(obligation),
    do: not Map.has_key?(obligation, "reaction_authority")

  defp put_obligation_id(base) do
    with {:ok, bytes} <- CanonicalJSON.encode(base) do
      {:ok, Map.put(base, "obligation_id", "triage-product-" <> CanonicalJSON.sha256(bytes))}
    else
      _error -> {:error, :invalid_triage_product_obligation}
    end
  end

  defp source_evidence(raw_bundle, cited_slack_refs) do
    messages = get_in(raw_bundle, ["raw_context", "slack_context", "messages"])

    if is_list(messages) and is_list(cited_slack_refs) do
      messages
      |> Enum.reduce_while({:ok, []}, fn
        %{
          "actor_id" => actor_id,
          "actor_kind" => actor_kind,
          "message_ts" => message_ts,
          "source_ref" => source_ref,
          "text" => text
        } = message,
        {:ok, source_messages}
        when is_binary(actor_id) and byte_size(actor_id) <= 128 and
               actor_kind in @source_actor_kinds and is_binary(message_ts) and message_ts != "" and
               is_binary(source_ref) and source_ref != "" and is_binary(text) ->
          source_message = %{
            "actor_id" => actor_id,
            "actor_kind" => actor_kind,
            "message_ts" => message_ts,
            "excerpt" => source_excerpt(text)
          }

          with {:ok, source_message} <-
                 source_state(source_message, Map.get(raw_bundle, "raw_context", %{}), message_ts),
               {:ok, source_message} <-
                 source_file_attachments(source_message, message["file_attachments"]) do
            {:cont, {:ok, [{source_ref, source_message} | source_messages]}}
          else
            :error -> {:halt, {:error, :invalid_triage_product_obligation}}
          end

        _invalid, _source_messages ->
          {:halt, {:error, :invalid_triage_product_obligation}}
      end)
      |> case do
        {:ok, source_messages} ->
          source_messages = Enum.reverse(source_messages)
          cited_slack_refs = Enum.uniq(cited_slack_refs)

          with {:ok, source_authority} <-
                 select_source_authority(source_messages, cited_slack_refs),
               {:ok, display_messages} <-
                 select_source_messages(source_messages, cited_slack_refs) do
            {:ok, display_messages, source_authority}
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :invalid_triage_product_obligation}
    end
  end

  defp cited_slack_refs(decision, sources) do
    decision
    # Internal assessment refs are validated against the frozen closure, but
    # do not select effect evidence or add send-time freshness dependencies.
    |> Map.delete("assessment")
    |> ProductDecision.source_refs()
    |> Enum.reduce_while({:ok, []}, fn projected_ref, {:ok, refs} ->
      case Map.fetch(sources, projected_ref) do
        {:ok, "slack://" <> _rest = raw_ref} -> {:cont, {:ok, [raw_ref | refs]}}
        {:ok, _non_slack_ref} -> {:cont, {:ok, refs}}
        :error -> {:halt, {:error, :invalid_triage_product_obligation}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, refs |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp select_source_messages(messages, cited_refs) do
    available_refs = MapSet.new(messages, &elem(&1, 0))

    cond do
      not Enum.all?(cited_refs, &MapSet.member?(available_refs, &1)) ->
        {:error, :invalid_triage_product_obligation}

      true ->
        cited = MapSet.new(cited_refs)

        selected_cited =
          messages
          |> Enum.filter(fn {source_ref, _message} -> MapSet.member?(cited, source_ref) end)
          |> Enum.take(-@source_message_limit)

        selected_cited_refs = MapSet.new(selected_cited, &elem(&1, 0))
        remaining = @source_message_limit - length(selected_cited)

        fillers =
          messages
          |> Enum.reject(fn {source_ref, _message} ->
            MapSet.member?(selected_cited_refs, source_ref)
          end)
          |> Enum.take(-remaining)
          |> MapSet.new(&elem(&1, 0))

        selected = MapSet.union(selected_cited_refs, fillers)

        {:ok,
         for(
           {source_ref, message} <- messages,
           MapSet.member?(selected, source_ref),
           do: message
         )}
    end
  end

  defp select_source_authority(messages, cited_refs) do
    by_ref = Map.new(messages)

    if length(messages) <= @source_authority_limit and
         length(cited_refs) <= @source_authority_limit and
         Enum.all?(cited_refs, &Map.has_key?(by_ref, &1)) do
      # Freshness compares the complete frozen input, not the model's citations
      # or the three-message display summary. Uncited evidence was also read.
      {:ok,
       Enum.map(messages, fn {_source_ref, message} ->
         Map.take(message, ~w(message_ts message_ts_us observed_version))
       end)}
    else
      {:error, :invalid_triage_product_obligation}
    end
  end

  defp source_excerpt(text) do
    text =
      text
      |> IdentityContract.redact_untrusted_text()
      |> String.split()
      |> Enum.join(" ")

    if String.length(text) > @source_excerpt_graphemes do
      String.slice(text, 0, @source_excerpt_graphemes - 1) <> "…"
    else
      text
    end
  end

  defp source_state(source_message, raw_context, message_ts) do
    message =
      raw_context
      |> get_in(["slack_context", "messages"])
      |> List.wrap()
      |> Enum.find(&(&1["message_ts"] == message_ts))

    case message do
      %{"message_ts_us" => message_ts_us, "observed_version" => observed_version}
      when is_integer(message_ts_us) and message_ts_us >= 0 and is_integer(observed_version) and
             observed_version >= 0 ->
        {:ok,
         source_message
         |> Map.put("message_ts_us", message_ts_us)
         |> Map.put("observed_version", observed_version)}

      %{} ->
        {:ok, source_message}

      _invalid ->
        :error
    end
  end

  # The catalogue describes the selected excerpt only. Old obligations remain
  # readable without it; absence is not a claim that the source had no files.
  defp source_file_attachments(message, nil), do: {:ok, message}

  defp source_file_attachments(message, catalogue) do
    if FileAttachments.valid?(catalogue) do
      projected = FileAttachments.project(catalogue, &IdentityContract.redact_untrusted_text/1)
      {:ok, Map.put(message, "file_attachments", projected)}
    else
      :error
    end
  end

  defp valid_source_messages?(messages) when is_list(messages) do
    length(messages) <= @source_message_limit and
      Enum.all?(messages, fn
        %{
          "actor_kind" => actor_kind,
          "message_ts" => message_ts,
          "excerpt" => excerpt
        } = message ->
          actor_id = Map.get(message, "actor_id")
          source_shape = Map.delete(message, "file_attachments")

          valid_shape =
            exact_keys?(source_shape, ~w(actor_kind message_ts excerpt)) or
              (exact_keys?(source_shape, ~w(actor_id actor_kind message_ts excerpt)) and
                 is_binary(actor_id) and byte_size(actor_id) <= 128) or
              (exact_keys?(
                 source_shape,
                 ~w(actor_id actor_kind message_ts message_ts_us observed_version excerpt)
               ) and is_binary(actor_id) and byte_size(actor_id) <= 128 and
                 is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
                 is_integer(message["observed_version"]) and message["observed_version"] >= 0)

          valid_catalogue =
            not Map.has_key?(message, "file_attachments") or
              FileAttachments.valid_projected?(message["file_attachments"])

          valid_shape and valid_catalogue and
            actor_kind in @source_actor_kinds and is_binary(message_ts) and message_ts != "" and
            is_binary(excerpt) and String.length(excerpt) <= @source_excerpt_graphemes

        _invalid ->
          false
      end)
  end

  defp valid_source_messages?(_messages), do: false

  defp valid_source_authority?(messages) when is_list(messages) do
    length(messages) <= @source_authority_limit and
      Enum.all?(messages, fn
        %{"message_ts" => message_ts} = message ->
          (exact_keys?(message, ~w(message_ts)) or
             (exact_keys?(message, ~w(message_ts message_ts_us observed_version)) and
                is_integer(message["message_ts_us"]) and message["message_ts_us"] >= 0 and
                is_integer(message["observed_version"]) and message["observed_version"] >= 0)) and
            is_binary(message_ts) and message_ts != ""

        _invalid ->
          false
      end)
  end

  defp valid_source_authority?(_messages), do: false

  defp valid_authority?(authority) when is_map(authority) do
    exact_keys?(authority, @required_authority) and
      Enum.all?(@required_authority, &(is_binary(authority[&1]) and authority[&1] != "")) and
      authority["thread_ts"] != "__channel__"
  end

  defp valid_authority?(_authority), do: false

  defp valid_identity?(identity) when is_map(identity) do
    exact_keys?(identity, @required_identity) and
      Enum.all?(@required_identity, &(is_binary(identity[&1]) and identity[&1] != ""))
  end

  defp valid_identity?(_identity), do: false

  # Distinct scheduled occurrences can cite the same Slack message. Keep every
  # event in the sealed input and recheck IDs; the effect cutoff needs each
  # timestamp only once for its send-time source check.
  defp effect_cutoff(%{"event_message_timestamps" => timestamps} = cutoff)
       when is_list(timestamps),
       do: Map.put(cutoff, "event_message_timestamps", Enum.uniq(timestamps))

  defp effect_cutoff(cutoff), do: cutoff

  defp valid_cutoff?(%{"event_message_timestamps" => timestamps} = cutoff) do
    exact_keys?(cutoff, ["event_message_timestamps"]) and is_list(timestamps) and
      timestamps != [] and timestamps == Enum.uniq(timestamps) and
      Enum.all?(timestamps, &(is_binary(&1) and &1 != ""))
  end

  defp valid_cutoff?(_cutoff), do: false

  defp invert_aliases(aliases) when is_map(aliases) do
    values = Map.values(aliases)

    if values == Enum.uniq(values) and
         Enum.all?(aliases, fn {raw, projected} ->
           is_binary(raw) and raw != "" and is_binary(projected) and projected != ""
         end) do
      {:ok, Map.new(aliases, fn {raw, projected} -> {projected, raw} end)}
    else
      {:error, :invalid_triage_product_obligation}
    end
  end

  defp invert_aliases(_aliases), do: {:error, :invalid_triage_product_obligation}

  defp restore_refs(value, sources) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, restored} ->
      case restore_refs(item, sources) do
        {:ok, next} -> {:cont, {:ok, [next | restored]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, restored} -> {:ok, Enum.reverse(restored)}
      {:error, _reason} = error -> error
    end
  end

  defp restore_refs(%{} = value, sources) do
    value
    |> Enum.reduce_while({:ok, %{}}, fn
      {"source_refs", refs}, {:ok, restored} when is_list(refs) ->
        mapped = Enum.map(refs, &Map.fetch(sources, &1))

        if Enum.all?(mapped, &match?({:ok, _}, &1)) do
          {:cont,
           {:ok, Map.put(restored, "source_refs", Enum.map(mapped, fn {:ok, raw} -> raw end))}}
        else
          {:halt, {:error, :invalid_triage_product_obligation}}
        end

      {"follow_up_ref", ref}, {:ok, restored} ->
        case Map.fetch(sources, ref) do
          {:ok, "triage-context://" <> _ = raw} ->
            {:cont, {:ok, Map.put(restored, "follow_up_ref", raw)}}

          _ ->
            {:halt, {:error, :invalid_triage_product_obligation}}
        end

      {key, nested}, {:ok, restored} ->
        case restore_refs(nested, sources) do
          {:ok, next} -> {:cont, {:ok, Map.put(restored, key, next)}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp restore_refs(value, _sources)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp restore_refs(_value, _sources), do: {:error, :invalid_triage_product_obligation}

  defp valid_communication?(%{"kind" => "reaction"} = communication, reaction_authority) do
    exact_keys?(communication, ~w(kind emoji source_refs)) and
      valid_obligation_emoji?(communication["emoji"], reaction_authority) and
      match?([_source_ref], communication["source_refs"]) and
      valid_effect_refs?(communication)
  end

  defp valid_communication?(%{"kind" => kind} = communication, nil)
       when kind in ["reply", "silence"],
       do: valid_effect_refs?(communication)

  defp valid_communication?(_communication, _reaction_authority), do: false

  defp valid_obligation_emoji?(emoji, nil), do: emoji in ProductDecision.reaction_emojis()

  defp valid_obligation_emoji?(emoji, reaction_authority),
    do: ExpressionContext.validate_emoji(reaction_authority, emoji) == :ok

  defp valid_effect_refs?(%{"source_refs" => refs}) when is_list(refs),
    do: Enum.all?(refs, &(is_binary(&1) and &1 != ""))

  defp valid_effect_refs?(_effect), do: false

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
