defmodule SalixIM.Triage.DelegationEffect do
  @moduledoc """
  Applies bounded Triage delegations through the canonical Task owner.

  Source authority and cited versions are checked around target preparation.
  Ordinary assignments read new messages in the Worker before public effects.
  The immutable obligation and ordinal identify one Task across retries.
  New selected-Worker decisions return created with that Task identity.
  Historical Router handoffs retain routed receipts, which do not prove creation.

  Protocol anchor: `tla/salix/TriageProductEffect.tla`.
  """

  alias SalixIM.Ports.TriageDelegation
  alias SalixIM.Triage.SlackEffectAdapter.Freshness

  @type result ::
          {:ok, [map()]}
          | {:error, term(), boolean(), [map()]}

  @spec apply(map(), keyword()) :: result()
  def apply(claim, opts \\ [])

  def apply(%{obligation_id: obligation_id, payload: payload} = claim, opts)
      when is_binary(obligation_id) and is_map(payload) and is_list(opts) do
    freshness_port = Keyword.get(opts, :freshness_port, Freshness)
    delegation_port = Keyword.get(opts, :delegation_port, TriageDelegation)
    port_opts = Keyword.get(opts, :port_opts, [])

    payload
    |> Map.get("delegations", [])
    |> normalize_delegations()
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {delegation, index}, {:ok, acc} ->
      case execute_one(
             claim,
             delegation,
             index,
             freshness_port,
             delegation_port,
             port_opts
           ) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc]}}

        {:error, reason, retryable?, result} ->
          {:halt, {:error, reason, retryable?, Enum.reverse([result | acc])}}
      end
    end)
    |> reverse_success()
  end

  def apply(_claim, _opts), do: {:error, :invalid_product_obligation, false, []}

  defp normalize_delegations(delegations) when is_list(delegations), do: delegations
  defp normalize_delegations(_delegations), do: []

  defp execute_one(
         claim,
         %{"task" => task} = delegation,
         index,
         freshness_port,
         delegation_port,
         port_opts
       )
       when is_binary(task) and task != "" do
    case delegation_anchor_status(claim, delegation) do
      :unanchored ->
        {:ok, suppressed(index, delegation, :unanchored_delegation)}

      anchor_status ->
        request_id = "triage-delegation:#{claim.obligation_id}:#{index}"
        # Only the materializer's domain-assignment marker permits current-source
        # intake. Public effects and historical model decisions keep strict checks.
        port_opts = Keyword.put(port_opts, :purpose, :worker_intake)

        with {:ok, %{status: :fresh} = first} <- freshness_port.check(claim, port_opts),
             :ok <- verify_live_anchor(anchor_status, claim, delegation, first),
             {:ok, prepared} <- delegation_port.prepare(claim, delegation, request_id),
             {:ok, %{status: :fresh} = second} <- freshness_port.check(claim, port_opts),
             :commit <-
               SalixVerifiedKernel.Proactive.decide_delegation_effect(
                 {:fresh, authority_bytes(first)},
                 :prepared,
                 {:fresh, authority_bytes(second)}
               ),
             {:ok, receipt} <- delegation_port.commit(prepared) do
          delegation_receipt(receipt, request_id, index, delegation)
        else
          {:error, :unanchored_delegation} ->
            {:ok, suppressed(index, delegation, :unanchored_delegation)}

          {:ok, %{status: :stale, reason: reason}} ->
            {:ok, suppressed(index, delegation, reason)}

          :suppress_authority_drift ->
            {:ok, suppressed(index, delegation, :authority_changed_during_prepare)}

          {:error, reason, retryable?} when is_boolean(retryable?) ->
            result = blocked(index, delegation, reason, retryable?)

            if retryable?,
              do: {:error, reason, true, result},
              else: {:ok, result}

          {:error, reason} ->
            retryable? = retryable_error?(reason)
            result = blocked(index, delegation, reason, retryable?)

            if retryable?,
              do: {:error, reason, true, result},
              else: {:ok, result}

          _other ->
            {:error, :delegation_unavailable, true,
             blocked(index, delegation, :delegation_unavailable, true)}
        end
    end
  rescue
    _exception ->
      {:error, :delegation_unavailable, true,
       blocked(index, delegation, :delegation_unavailable, true)}
  catch
    :exit, _reason ->
      {:error, :delegation_unavailable, true,
       blocked(index, delegation, :delegation_unavailable, true)}
  end

  defp execute_one(_claim, delegation, index, _freshness, _port, _opts),
    do: {:ok, blocked(index, delegation, :invalid_delegation, false)}

  # Protects against historical persisted obligations whose delegation cited only
  # retained cross-thread context or a sibling ChannelBatch thread rather than
  # the current Slack target thread or a due scheduled recheck ref. Ordinary
  # domain-owned intake assignments are already bound to the current target and
  # verified by freshness checks. Suppresses in place without shifting sibling
  # ordinals.
  defp delegation_anchor_status(%{payload: %{"ordinary_worker_assignment" => true}}, _delegation),
    do: :anchored

  defp delegation_anchor_status(%{payload: payload}, %{"source_refs" => refs})
       when is_map(payload) and is_list(refs) do
    recheck_refs =
      payload
      |> Map.get("recheck_context_refs", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    target = payload["target"]

    statuses =
      Enum.map(refs, fn
        "slack://" <> _rest = ref ->
          slack_ref_anchor_status(ref, target)

        ref when is_binary(ref) ->
          if MapSet.member?(recheck_refs, ref), do: :anchored, else: :unanchored

        _other ->
          :unanchored
      end)

    cond do
      :anchored in statuses -> :anchored
      :check_live_roots in statuses -> :check_live_roots
      true -> :unanchored
    end
  end

  defp delegation_anchor_status(_claim, _delegation), do: :unanchored

  defp verify_live_anchor(:anchored, _claim, _delegation, _fresh), do: :ok

  defp verify_live_anchor(
         :check_live_roots,
         %{payload: %{"target" => %{"thread_ts" => target_thread_ts} = target}},
         %{"source_refs" => refs},
         %{message_roots: %{} = roots}
       )
       when is_binary(target_thread_ts) and target_thread_ts != "" and is_list(refs) do
    anchored? =
      Enum.any?(refs, fn
        "slack://" <> rest ->
          case String.split(rest, "/") do
            [ws, ch, "channel", msg_ts] ->
              target["workspace_id"] in [nil, "", ws] and
                target["channel_id"] in [nil, "", ch] and
                Map.get(roots, msg_ts) == target_thread_ts

            _other ->
              false
          end

        _other ->
          false
      end)

    if anchored?, do: :ok, else: {:error, :unanchored_delegation}
  end

  defp verify_live_anchor(:check_live_roots, _claim, _delegation, _fresh),
    do: {:error, :unanchored_delegation}

  defp slack_ref_anchor_status("slack://" <> rest, target) do
    case String.split(rest, "/") do
      [ws, ch, scope, msg_ts] when ws != "" and ch != "" and scope != "" and msg_ts != "" ->
        cond do
          not is_map(target) ->
            :anchored

          target["workspace_id"] not in [nil, "", ws] or
              target["channel_id"] not in [nil, "", ch] ->
            :unanchored

          target["thread_ts"] in [nil, ""] ->
            :anchored

          scope == target["thread_ts"] ->
            :anchored

          scope == "channel" ->
            if msg_ts == target["thread_ts"], do: :anchored, else: :check_live_roots

          true ->
            :unanchored
        end

      _other ->
        :unanchored
    end
  end

  defp slack_ref_anchor_status(_ref, _target), do: :unanchored

  defp reverse_success({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_success(other), do: other

  defp delegation_receipt(
         %{
           "disposition" => "created",
           "request_id" => request_id,
           "conversation_id" => conversation_id,
           "worker_agent_id" => worker_id
         },
         request_id,
         index,
         delegation
       )
       when is_binary(conversation_id) and is_binary(worker_id),
       do:
         {:ok,
          %{
            "index" => index,
            "status" => "created",
            "conversation_id" => conversation_id,
            "worker_agent_id" => worker_id,
            "source_count" => source_count(delegation)
          }}

  defp delegation_receipt(
         %{"disposition" => "routed", "request_id" => request_id},
         request_id,
         index,
         delegation
       ),
       do:
         {:ok,
          %{"index" => index, "status" => "routed", "source_count" => source_count(delegation)}}

  defp delegation_receipt(_receipt, _request_id, index, delegation),
    do:
      {:error, :invalid_delegation_receipt, false,
       blocked(index, delegation, :invalid_delegation_receipt, false)}

  defp suppressed(index, delegation, reason),
    do: %{
      "index" => index,
      "status" => "suppressed_stale",
      "reason" => safe_reason(reason),
      "source_count" => source_count(delegation)
    }

  defp blocked(index, delegation, reason, retryable?),
    do: %{
      "index" => index,
      "status" => if(retryable?, do: "retry_scheduled", else: "proposed"),
      "reason" => safe_reason(reason),
      "source_count" => source_count(delegation)
    }

  defp source_count(%{"source_refs" => refs}) when is_list(refs), do: length(refs)
  defp source_count(_delegation), do: 0

  defp authority_bytes(check), do: :erlang.term_to_binary(Map.get(check, :authority_ref))

  defp retryable_error?(reason),
    do:
      reason in [
        :source_unavailable,
        :source_authority_unavailable,
        :slack_triage_authority_unavailable,
        :task_create_unavailable,
        :timeout,
        :unavailable
      ] or match?({:rate_limited, _}, reason)

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "delegation_unavailable"
end
