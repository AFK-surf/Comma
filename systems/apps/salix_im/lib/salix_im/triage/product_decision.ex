defmodule SalixIM.Triage.ProductDecision do
  @moduledoc """
  Closed product decision for one event-driven or scheduled Triage evaluation.

  Communication, context collection and worker delegation are independent
  outcomes of the same frozen evidence. The model may propose them together;
  this module grants no persistence or provider authority. Raw source mapping,
  conflict handling and effect execution remain system-owned boundaries.

  Text limits count Unicode code points, as in the provider schema.

  New evaluations include a bounded factual assessment before these outcomes.
  Its unread references remain in the frozen source closure. The assessment is
  internal data, grants no authority, and is optional for retained decisions.
  """

  @schema "comma.triage-product-decision.v2"
  @legacy_schema "comma.triage-product-decision.v1"
  @silence_reasons ~w(
    worker_pending
    no_actionable_request
    already_answered
    insufficient_evidence
    stale_or_changed
    outside_authority
    low_confidence
    duplicate
  )
  @reaction_emojis ~w(+1 heart joy tada eyes thinking_face clap pray raised_hands sparkles)
  @context_kinds ~w(project_fact decision follow_up follow_up_resolution)
  @context_confidence ~w(explicit inferred)
  @identity_topics ~w(none self_identity other_agent_identity identity_relation ambiguous)
  @max_context_candidates 3
  @max_delegations 2
  @max_subject_length 160
  @max_value_length 2_000
  @max_reply_length 4_000
  @max_task_length 2_000
  @assessment_max_length 1200
  @max_recheck_hours 24 * 30
  @emoji_name ~r/\A[a-z0-9][a-z0-9_+\-]{0,63}\z/

  alias SalixIM.Triage.ExpressionContext

  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "The assessment text limit in Unicode code points, as in JSON Schema maxLength."
  @spec assessment_max_length() :: pos_integer()
  def assessment_max_length, do: @assessment_max_length

  @doc "Returns the bounded standard emoji palette available to product Triage."
  @spec reaction_emojis() :: [String.t()]
  def reaction_emojis, do: @reaction_emojis

  @doc "Returns every projected source ref named by one product decision."
  @spec source_refs(term()) :: [String.t()]
  def source_refs(%{} = decision) do
    communication_refs =
      case decision["communication"] do
        %{"source_refs" => refs} when is_list(refs) -> refs
        _other -> []
      end

    companion_reaction_refs =
      case decision["companion_reaction"] do
        %{"source_refs" => refs} when is_list(refs) -> refs
        _other -> []
      end

    context_refs =
      decision
      |> Map.get("context_candidates", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"source_refs" => refs} when is_list(refs) -> refs
        _other -> []
      end)

    delegation_refs =
      decision
      |> Map.get("delegations", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"source_refs" => refs} = delegation when is_list(refs) ->
          refs ++ List.wrap(delegation["worker_ref"])

        _other ->
          []
      end)

    assessment_refs =
      case decision["assessment"] do
        %{"unread_source_refs" => refs} when is_list(refs) -> refs
        _ -> []
      end

    (communication_refs ++
       companion_reaction_refs ++ context_refs ++ delegation_refs ++ assessment_refs)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def source_refs(_decision), do: []

  @doc "Returns every projected principal ref named by one product decision."
  @spec principal_refs(term()) :: [String.t()]
  def principal_refs(%{"identity_interpretation" => %{"referenced_principal_refs" => refs}})
      when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def principal_refs(_decision), do: []

  @doc "Checks the closed product shape without granting external source authority."
  @spec structurally_valid?(term()) :: boolean()
  def structurally_valid?(decision) do
    validate_with_reaction_authority(
      decision,
      source_refs(decision),
      principal_refs(decision),
      :structural
    ) == :ok
  end

  @spec validate(term(), [String.t()], [String.t()]) ::
          :ok | {:error, :invalid_triage_product_decision}
  def validate(decision, source_closure, principal_closure)
      when is_map(decision) and is_list(source_closure) and is_list(principal_closure) do
    validate_with_reaction_authority(decision, source_closure, principal_closure, :standard)
  end

  def validate(_decision, _source_closure, _principal_closure),
    do: {:error, :invalid_triage_product_decision}

  @doc "Validates one decision against the frozen workspace expression authority."
  @spec validate(term(), [String.t()], [String.t()], term()) ::
          :ok | {:error, :invalid_triage_product_decision}
  def validate(decision, source_closure, principal_closure, expression_context)
      when is_map(decision) and is_list(source_closure) and is_list(principal_closure) do
    validate_with_reaction_authority(
      decision,
      source_closure,
      principal_closure,
      expression_context
    )
  end

  def validate(_decision, _source_closure, _principal_closure, _expression_context),
    do: {:error, :invalid_triage_product_decision}

  defp validate_with_reaction_authority(
         decision,
         source_closure,
         principal_closure,
         reaction_authority
       ) do
    decision
    |> validate_components(source_closure, principal_closure, reaction_authority)
    |> validation_result()
  end

  defp validate_components(decision, source_closure, principal_closure, reaction_authority)
       when is_map(decision) and is_list(source_closure) and is_list(principal_closure) do
    with {:decision_shape, true} <- {:decision_shape, valid_decision_keys?(decision)},
         :ok <- validate_assessment(decision, source_closure),
         {:communication, true} <-
           {:communication,
            valid_communication?(decision["communication"], source_closure, reaction_authority)},
         {:companion_reaction, true} <-
           {:companion_reaction,
            valid_companion_reaction?(decision, source_closure, reaction_authority)},
         {:context_candidates, true} <-
           {:context_candidates,
            valid_context_candidates?(decision["context_candidates"], source_closure)},
         {:delegations, true} <-
           {:delegations, valid_delegations?(decision["delegations"], source_closure)},
         {:identity_interpretation, true} <-
           {:identity_interpretation,
            valid_interpretation?(decision["identity_interpretation"], principal_closure)} do
      :ok
    else
      {check, false} -> {:error, check}
      {:error, _check} = error -> error
    end
  end

  defp validate_components(_decision, _sources, _principals, _authority),
    do: {:error, :decision_shape}

  defp validation_result(:ok), do: :ok
  defp validation_result({:error, _check}), do: {:error, :invalid_triage_product_decision}

  @doc "Validates one Triage decision against the explicit-recipient routing boundary."
  @spec validate_for_target(term(), [String.t()], [String.t()], String.t()) ::
          :ok | {:error, :invalid_triage_product_decision}
  def validate_for_target(decision, source_closure, principal_closure, syntactic_addressee) do
    decision
    |> validate_for_target_detailed(
      source_closure,
      principal_closure,
      syntactic_addressee,
      :standard
    )
    |> validation_result()
  end

  @spec validate_for_target(term(), [String.t()], [String.t()], String.t(), term()) ::
          :ok | {:error, :invalid_triage_product_decision}
  def validate_for_target(
        decision,
        source_closure,
        principal_closure,
        syntactic_addressee,
        expression_context
      ) do
    decision
    |> validate_for_target_detailed(
      source_closure,
      principal_closure,
      syntactic_addressee,
      expression_context
    )
    |> validation_result()
  end

  @doc "Validates a v2 decision against routing and the frozen latest reaction target."
  @spec validate_for_target(term(), [String.t()], [String.t()], String.t(), String.t(), term()) ::
          :ok | {:error, :invalid_triage_product_decision}
  def validate_for_target(
        decision,
        source_closure,
        principal_closure,
        syntactic_addressee,
        target_source_ref,
        expression_context
      ) do
    decision
    |> validate_for_target_detailed(
      source_closure,
      principal_closure,
      syntactic_addressee,
      target_source_ref,
      expression_context
    )
    |> validation_result()
  end

  @doc "Validates the product and recipient route without including rejected values in the error."
  @spec validate_for_target_detailed(term(), [String.t()], [String.t()], String.t(), term()) ::
          :ok | {:error, atom() | {atom(), atom()}}
  def validate_for_target_detailed(decision, sources, principals, route, expression_context) do
    with :ok <- validate_components(decision, sources, principals, expression_context),
         {:target_route, true} <- {:target_route, valid_target_boundary?(decision, route)} do
      :ok
    else
      {check, false} -> {:error, check}
      {:error, _check} = error -> error
    end
  end

  @doc "Also checks the exact frozen reaction target, returning only fixed diagnostic atoms."
  @spec validate_for_target_detailed(
          term(),
          [String.t()],
          [String.t()],
          String.t(),
          String.t(),
          term()
        ) :: :ok | {:error, atom() | {atom(), atom()}}
  def validate_for_target_detailed(
        decision,
        sources,
        principals,
        route,
        target,
        expression_context
      ) do
    with :ok <-
           validate_for_target_detailed(decision, sources, principals, route, expression_context),
         {:reaction_target, true} <-
           {:reaction_target, valid_exact_reaction_target?(decision, target)} do
      :ok
    else
      {check, false} -> {:error, check}
      {:error, _check} = error -> error
    end
  end

  @doc """
  Applies the system-owned communication route for an explicit Slack addressee.

  Periodic patrol is allowed to extract source-backed project context from the
  same frozen evidence, but it never owns visible communication or delegation
  for a message whose syntax already names a recipient. The provider may still
  propose either; this boundary discards those proposals before the effective
  decision is validated or persisted. Unknown target classes remain unchanged
  so the closed validator fails them rather than inventing a route.
  """
  @spec enforce_target_boundary(term(), String.t()) :: term()
  def enforce_target_boundary(decision, "none"), do: decision

  def enforce_target_boundary(decision, "other") when is_map(decision) do
    decision
    |> Map.put("communication", %{
      "kind" => "silence",
      "reason" => "outside_authority",
      "explanation" =>
        "This message explicitly addresses another recipient. Triage does not take over their reply.",
      "source_refs" => []
    })
    |> clear_companion_reaction()
    |> Map.put("delegations", [])
  end

  def enforce_target_boundary(decision, syntactic_addressee)
      when is_map(decision) and syntactic_addressee in ["self", "mixed"] do
    decision
    |> Map.put("communication", %{
      "kind" => "silence",
      "reason" => "duplicate",
      "explanation" =>
        "The direct-message route handles this explicitly addressed message. This patrol does not send a second reply.",
      "source_refs" => []
    })
    |> clear_companion_reaction()
    |> Map.put("delegations", [])
  end

  def enforce_target_boundary(decision, _syntactic_addressee), do: decision

  @doc "Returns the product-owner route for one projected Slack decision target and source lane."
  @spec target_route(map(), String.t() | nil) :: String.t() | nil
  def target_route(%{"decision_target" => target} = slack_context, "clickhouse_etl")
      when is_map(target) do
    addressee = target["syntactic_addressee"]
    target_source_ref = target["source_ref"]
    messages = Map.get(slack_context, "messages", [])

    actor_kind =
      Enum.find_value(List.wrap(messages), fn
        %{"source_ref" => ^target_source_ref, "actor_kind" => kind} -> kind
        _message -> nil
      end)

    if actor_kind == "agent" and addressee in ["self", "mixed"],
      do: "none",
      else: addressee
  end

  def target_route(%{"decision_target" => target}, _source_mode) when is_map(target),
    do: target["syntactic_addressee"]

  def target_route(_slack_context, _source_mode), do: nil

  defp valid_target_boundary?(_decision, "none"), do: true

  defp valid_target_boundary?(decision, "other") do
    Map.delete(decision["communication"], "explanation") == %{
      "kind" => "silence",
      "reason" => "outside_authority",
      "source_refs" => decision["communication"]["source_refs"]
    } and no_companion_reaction?(decision) and decision["delegations"] == []
  end

  defp valid_target_boundary?(decision, syntactic_addressee)
       when syntactic_addressee in ["self", "mixed"] do
    Map.delete(decision["communication"], "explanation") == %{
      "kind" => "silence",
      "reason" => "duplicate",
      "source_refs" => decision["communication"]["source_refs"]
    } and no_companion_reaction?(decision) and decision["delegations"] == []
  end

  defp valid_target_boundary?(_decision, _syntactic_addressee), do: false

  defp valid_exact_reaction_target?(decision, target_source_ref)
       when is_binary(target_source_ref) and target_source_ref != "" do
    primary_exact? =
      case decision["communication"] do
        %{"kind" => "reaction", "source_refs" => refs} -> refs == [target_source_ref]
        _other -> true
      end

    companion_exact? =
      case Map.get(decision, "companion_reaction") do
        nil -> true
        %{"kind" => "reaction", "source_refs" => refs} -> refs == [target_source_ref]
        _other -> false
      end

    primary_exact? and companion_exact?
  end

  defp valid_exact_reaction_target?(_decision, _target_source_ref), do: false

  defp valid_communication?(%{"kind" => "reply"} = communication, source_closure, _authority) do
    exact_keys?(communication, ~w(kind text source_refs)) and
      bounded_text?(communication["text"], @max_reply_length) and
      valid_refs?(communication["source_refs"], source_closure, false)
  end

  defp valid_communication?(%{"kind" => "reaction"} = communication, source_closure, authority) do
    exact_keys?(communication, ~w(kind emoji source_refs)) and
      valid_reaction_emoji?(communication["emoji"], authority) and
      match?([_source_ref], communication["source_refs"]) and
      valid_refs?(communication["source_refs"], source_closure, false)
  end

  defp valid_communication?(%{"kind" => "silence"} = communication, source_closure, _authority) do
    (exact_keys?(communication, ~w(kind reason source_refs)) or
       (exact_keys?(communication, ~w(kind reason explanation source_refs)) and
          bounded_text?(communication["explanation"], 1_000))) and
      communication["reason"] in @silence_reasons and
      valid_refs?(communication["source_refs"], source_closure, true)
  end

  defp valid_communication?(_communication, _source_closure, _authority), do: false

  defp valid_reaction_emoji?(emoji, :standard), do: emoji in @reaction_emojis

  defp valid_reaction_emoji?(emoji, :structural),
    do:
      emoji in @reaction_emojis or
        (is_binary(emoji) and byte_size(emoji) <= 64 and Regex.match?(@emoji_name, emoji))

  defp valid_reaction_emoji?(emoji, expression_context),
    do: ExpressionContext.validate_emoji(expression_context, emoji) == :ok

  defp valid_companion_reaction?(%{"schema" => @legacy_schema}, _source_closure, _authority),
    do: true

  defp valid_companion_reaction?(
         %{
           "schema" => @schema,
           "communication" => %{"kind" => "reply"},
           "companion_reaction" => %{"kind" => "reaction"} = companion_reaction
         },
         source_closure,
         reaction_authority
       ),
       do: valid_communication?(companion_reaction, source_closure, reaction_authority)

  defp valid_companion_reaction?(
         %{"schema" => @schema, "companion_reaction" => nil},
         _closure,
         _authority
       ),
       do: true

  defp valid_companion_reaction?(_decision, _source_closure, _authority), do: false

  defp valid_decision_keys?(%{"schema" => @legacy_schema} = decision),
    do:
      exact_keys?(
        decision,
        ~w(schema communication context_candidates delegations identity_interpretation)
      )

  defp valid_decision_keys?(%{"schema" => @schema} = decision),
    do:
      exact_keys?(
        Map.delete(decision, "assessment"),
        ~w(
          schema communication companion_reaction context_candidates delegations
          identity_interpretation
        )
      )

  defp valid_decision_keys?(_decision), do: false

  defp validate_assessment(decision, source_closure) do
    case Map.fetch(decision, "assessment") do
      :error ->
        :ok

      {:ok, %{} = assessment} ->
        with {:assessment_shape, true} <-
               {:assessment_shape,
                exact_keys?(
                  assessment,
                  ~w(requested_outcome available_evidence unread_source_refs unavailable_input)
                )},
             :ok <- validate_assessment_texts(assessment),
             {:assessment_unread_source_refs, true} <-
               {:assessment_unread_source_refs,
                valid_refs?(assessment["unread_source_refs"], source_closure, true) and
                  length(assessment["unread_source_refs"]) <= 8} do
          :ok
        else
          {check, false} -> {:error, check}
          {:error, _check} = error -> error
        end

      _ ->
        {:error, :assessment_shape}
    end
  end

  defp validate_assessment_texts(assessment) do
    Enum.reduce_while(
      [
        {"requested_outcome", :assessment_requested_outcome},
        {"available_evidence", :assessment_available_evidence},
        {"unavailable_input", :assessment_unavailable_input}
      ],
      :ok,
      fn {field, check}, :ok ->
        case text_length_failure(assessment[field], @assessment_max_length) do
          nil -> {:cont, :ok}
          reason -> {:halt, {:error, {check, reason}}}
        end
      end
    )
  end

  defp text_length_failure(text, max_length) when is_binary(text) do
    cond do
      # A UTF-8 code point occupies at most four bytes. Bound the scan before
      # counting code points; grapheme counts do not match JSON Schema either.
      byte_size(text) > max_length * 4 -> :too_long
      not String.valid?(text) -> :invalid_utf8
      length(String.codepoints(text)) > max_length -> :too_long
      true -> nil
    end
  end

  defp text_length_failure(_text, _max_length), do: :not_text

  defp clear_companion_reaction(%{"schema" => @schema} = decision),
    do: Map.put(decision, "companion_reaction", nil)

  defp clear_companion_reaction(decision), do: decision

  defp no_companion_reaction?(%{"schema" => @schema} = decision),
    do: is_nil(decision["companion_reaction"])

  defp no_companion_reaction?(_decision), do: true

  def valid_context_candidates?(candidates, source_closure)
      when is_list(candidates) and length(candidates) <= @max_context_candidates do
    Enum.all?(candidates, &valid_context_candidate?(&1, source_closure))
  end

  def valid_context_candidates?(_candidates, _source_closure), do: false

  defp valid_context_candidate?(%{"kind" => "follow_up"} = candidate, source_closure) do
    basis = candidate["follow_up_basis"]

    exact_keys?(
      Map.drop(candidate, ~w(follow_up_basis follow_up_ref follow_up_action)),
      ~w(kind subject value confidence source_refs recheck_after_hours)
    ) and common_context_candidate?(candidate, source_closure) and
      basis in [nil, "unconfirmed", "reminder_confirmed", "agent_owned"] and
      (not Map.has_key?(candidate, "follow_up_ref") or
         (is_binary(candidate["follow_up_ref"]) and
            candidate["follow_up_ref"] in candidate["source_refs"])) and
      valid_follow_up_action?(candidate) and
      is_integer(candidate["recheck_after_hours"]) and
      candidate["recheck_after_hours"] in 1..@max_recheck_hours
  end

  defp valid_context_candidate?(%{"kind" => kind} = candidate, source_closure)
       when kind in ~w(project_fact decision follow_up_resolution) do
    basis = candidate["resolution_basis"]
    scope = candidate["knowledge_scope"]

    valid_basis? =
      if kind == "follow_up_resolution",
        do: basis in [nil, "source_confirmation", "reminder_delivery"],
        else: not Map.has_key?(candidate, "resolution_basis")

    exact_keys?(
      Map.drop(candidate, ~w(resolution_basis knowledge_scope)),
      ~w(kind subject value confidence source_refs)
    ) and
      valid_basis? and
      if(kind == "follow_up_resolution",
        do: not Map.has_key?(candidate, "knowledge_scope"),
        else: scope in [nil, "person", "project"]
      ) and
      common_context_candidate?(candidate, source_closure) and
      (kind != "follow_up_resolution" or
         (candidate["confidence"] == "explicit" and
            length(Enum.uniq(candidate["source_refs"])) >= 2))
  end

  defp valid_context_candidate?(_candidate, _source_closure), do: false

  defp valid_follow_up_action?(%{"follow_up_action" => "create"} = candidate),
    do: not Map.has_key?(candidate, "follow_up_ref")

  defp valid_follow_up_action?(%{"follow_up_action" => "update"} = candidate),
    do: Map.has_key?(candidate, "follow_up_ref")

  defp valid_follow_up_action?(candidate), do: not Map.has_key?(candidate, "follow_up_action")

  defp common_context_candidate?(candidate, source_closure) do
    candidate["kind"] in @context_kinds and
      bounded_text?(candidate["subject"], @max_subject_length) and
      bounded_text?(candidate["value"], @max_value_length) and
      candidate["confidence"] in @context_confidence and
      valid_refs?(candidate["source_refs"], source_closure, false)
  end

  defp valid_delegations?(delegations, source_closure)
       when is_list(delegations) and length(delegations) <= @max_delegations do
    Enum.all?(delegations, fn delegation ->
      is_map(delegation) and
        (exact_keys?(delegation, ~w(task source_refs)) or
           (exact_keys?(delegation, ~w(task worker_ref source_refs)) and
              delegation["worker_ref"] in source_closure)) and
        bounded_text?(delegation["task"], @max_task_length) and
        valid_refs?(delegation["source_refs"], source_closure, false)
    end)
  end

  defp valid_delegations?(_delegations, _source_closure), do: false

  defp valid_interpretation?(interpretation, principal_closure) when is_map(interpretation) do
    refs = interpretation["referenced_principal_refs"]
    topic = interpretation["topic"]

    exact_keys?(interpretation, ~w(topic referenced_principal_refs)) and
      topic in @identity_topics and valid_refs?(refs, principal_closure, true) and
      if(topic == "none", do: refs == [], else: refs != [])
  end

  defp valid_interpretation?(_interpretation, _principal_closure), do: false

  defp valid_refs?(refs, closure, allow_empty?) when is_list(refs) do
    (allow_empty? or refs != []) and refs == Enum.uniq(refs) and
      Enum.all?(refs, &(is_binary(&1) and &1 != "" and &1 in closure))
  end

  defp valid_refs?(_refs, _closure, _allow_empty?), do: false

  defp bounded_text?(value, max_length) do
    is_nil(text_length_failure(value, max_length)) and String.trim(value) != ""
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)
end
