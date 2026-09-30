defmodule SalixIM.Triage.DelegationAuthorization do
  @moduledoc """
  Revalidates a Router-selected Triage intent before canonical Task creation.

  The model's ref only selects an activation-local server origin. The immutable
  PG obligation and current project/source/Worker owners supply authority. No
  reservation, retry state or Task lifecycle is introduced here.

  Protocol anchors: `tla/salix/TriageRouterHandoff.tla` and
  `tla/salix/TriageRouterHandoffPrecheck.tla`. These are invocation-time
  owner checks, not an atomic lock over independent authority changes.
  """

  alias SalixIM.Ports.TriageDelegation
  alias SalixIM.Triage.SlackEffectAdapter.Freshness
  alias SalixStore.TriageProductRuntime

  @schema "comma.triage-delegation-origin.v1"

  # Generic callers cannot retarget the product-owned source subsequently
  # projected to Worker read context. Modeled by TriageRouterHandoff.tla.
  def protected_source_ref_keys,
    do: [
      "triage_obligation_id",
      "triage_delegation_index",
      "triage_source_refs",
      "triage_investigation"
    ]

  @doc "Returns stable Task attributes, or nil for an ordinary non-Triage call."
  def prepare(scope, context, params, opts \\ []) do
    context = context || %{}

    if triage_call?(context, params) do
      authorize(scope, context, params, opts)
    else
      {:ok, nil}
    end
  end

  defp authorize(scope, context, params, opts) do
    origin = field(context, :trusted_origin) || %{}
    handoff = origin["triage_delegation"] || %{}
    ref = params["triage_delegation_ref"]
    source_ids = field(context, :source_message_ids) || [field(context, :source_message_id)]
    authority = Keyword.get(opts, :authority_port, TriageDelegation)
    freshness = Keyword.get(opts, :freshness_port, Freshness)

    with true <- is_binary(ref) and ref != "",
         true <- valid_origin?(scope, origin, handoff, ref, source_ids),
         true <-
           is_nil(params["schedule"]),
         {:ok, original} <-
           TriageProductRuntime.fetch_delegation(
             handoff["namespace_key"],
             handoff["obligation_id"],
             handoff["index"]
           ),
         true <- original_matches_scope?(original, scope),
         :ok <- authority.authorize_target(original, scope.agent_id, params["agent_id"]),
         {:ok, %{status: :fresh}} <-
           freshness.check(original, Keyword.get(opts, :freshness_opts, [])) do
      {:ok,
       %{
         request_id: ref,
         source_refs: %{
           "origin_agent_id" => scope.agent_id,
           "triage_obligation_id" => original.obligation_id,
           "triage_delegation_index" => original.index,
           "triage_source_refs" => original.delegation["source_refs"]
         }
       }}
    else
      {:ok, %{status: :stale, reason: reason}} ->
        {:error, "triage_delegation_source_stale: #{safe_reason(reason)}"}

      {:error, reason, _retryable} ->
        {:error, "triage_delegation_authority_rejected: #{safe_reason(reason)}"}

      {:error, reason} ->
        {:error, "triage_delegation_authority_rejected: #{safe_reason(reason)}"}

      _invalid ->
        {:error,
         "triage_delegation_origin_invalid: select the exact current handoff ref; ordinary one-shot Tasks only"}
    end
  rescue
    _exception -> {:error, "triage_delegation_authority_unavailable"}
  catch
    :exit, _reason -> {:error, "triage_delegation_authority_unavailable"}
  end

  defp triage_call?(context, params) do
    origins = [field(context, :trusted_origin) | List.wrap(field(context, :trusted_origins))]

    sources =
      List.wrap(field(context, :source_message_ids)) ++ [field(context, :source_message_id)]

    not is_nil(params["triage_delegation_ref"]) or
      Enum.any?(origins, &(is_map(&1) and Map.has_key?(&1, "triage_delegation"))) or
      Enum.any?(sources, &(is_binary(&1) and String.starts_with?(&1, "triage-delegation:")))
  end

  defp valid_origin?(scope, origin, handoff, ref, source_ids) do
    index = handoff["index"]
    obligation_id = handoff["obligation_id"]

    handoff["schema"] == @schema and index in 0..1 and is_binary(obligation_id) and
      ref == "triage-delegation:#{obligation_id}:#{index}" and
      ref == handoff["request_id"] and ref == origin["source_message_id"] and ref in source_ids and
      origin["provider"] == "slack" and origin["source_actor_type"] == "provider_system" and
      origin["agent_group_id"] == scope.group_id and handoff["group_id"] == scope.group_id and
      handoff["router_agent_id"] == scope.agent_id
  end

  defp original_matches_scope?(original, scope) do
    identity = original.payload["product_identity"] || %{}

    identity["project_salix_group_id"] == scope.group_id and
      identity["salix_agent_id"] == scope.agent_id
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, Atom.to_string(key), Map.get(map, key))

  defp field(_map, _key), do: nil
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "unavailable"
end
