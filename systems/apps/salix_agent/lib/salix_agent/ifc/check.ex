defmodule SalixAgent.IFC.Check do
  @moduledoc """
  The information-flow step of `SalixAgent.SessionToolDispatch`
  (`docs/verification.md` §9).

  One step, after schema validation and the recommendation policy, before
  `SalixAgent.Tools.execute/2`, covering every runtime envelope with no
  per-tool code: internal rounds, the external-runtime HTTP path, the
  JavaScript host, and the Triage evaluator's read-tool run.

  Per effect it gathers `Facts`, `Items` and the `Effect` through the
  resolvers, calls `SalixIFC.decide/4` exactly once, archives the verdict,
  and acts on it:

    * `:audit` — the effect executes whatever the verdict says. This is how a
      Group measures would-be denials before anyone is blocked, and why
      audit mode can never change an outcome.
    * `:enforce` — a denial becomes a `guidance` result (rule A) and the call
      never reaches the Tools seam; an allow carries its `Evidence` forward
      so the provider adapter can render the provenance footer (rule B).

  No label logic lives here. Every comparison is inside the pure kernel.
  """

  alias SalixAgent.EventArchive
  alias SalixAgent.IFC
  alias SalixAgent.IFC.{Context, Declaration, Destination, Guidance, Provenance}
  alias SalixIFC.{Codec, Effect, Label, Principal, Reason}

  @decided [:egress, :persist]

  @doc """
  Applies the information-flow decision to a dispatch's authorization
  decisions, in place: `{:execute, call}` entries may become `{:blocked,
  result}`, and surviving calls carry their evidence.
  """
  @spec authorize([{:execute, map()} | {:blocked, map()}], map()) ::
          [{:execute, map()} | {:blocked, map()}]
  def authorize(decisions, ctx) when is_list(decisions) and is_map(ctx) do
    if IFC.facts_mod() == nil or IFC.mode(Map.get(ctx, :ifc_mode)) == :off do
      decisions
    else
      Enum.map(decisions, fn
        {:execute, call} -> decide(call, ctx)
        other -> other
      end)
    end
  end

  def authorize(decisions, _ctx), do: decisions

  @doc """
  The label a tool result carries into the transcript.

  A read tool that labelled its own result keeps that label — that is the
  content's real audience. Everything else is a record the model produced
  this round, so it carries the round's label (§3.3, last row).

  A read that labelled nothing is the one case the round's label must not
  cover. Its result is content the read returned, not a record of this round,
  and the runtime cannot see which audiences the read crossed: a workspace
  search run from a public channel can return a private channel's messages.
  Stamping the round's label there would hand that content the audience of
  whatever the round declared and let an honest citation of it flow straight
  out. Until a read
  adapter labels its own hits (§15), an unlabelled read reads as
  agent-private — it stays in the session, and carrying it further needs a
  person.
  """
  @spec stamp_results([map()], [map()], map()) :: [map()]
  def stamp_results(results, calls, ctx) when is_list(results) and is_list(calls) do
    case round_label(calls, ctx) do
      nil ->
        results

      round ->
        results
        |> Enum.zip(read_flags(results, calls, ctx))
        |> Enum.map(fn {result, read?} ->
          stamp_result_label(result, read?, round)
        end)
    end
  end

  def stamp_results(results, _calls, _ctx), do: results

  @doc false
  def stamp_result(result, call, ctx, round) do
    stamp_result_label(result, read?(call, ctx), round)
  end

  defp stamp_result_label(result, _read?, nil), do: result

  defp stamp_result_label(result, read?, round) do
    case result_label(result) do
      nil when read? -> put_ifc(result, %{"label" => Context.private_wire()})
      nil -> put_ifc(result, %{"label" => round})
      provided -> put_ifc(result, provided)
    end
  end

  @doc """
  The label of any record the model produced in this round, or `nil` when
  this session is not carrying a labelled context at all.

  `nil` matters: a Group with the check off must not stamp its transcript
  with the fail-closed label, or every record written while it was off would
  flow nowhere the day it turns the check on.
  """
  @spec round_label([map()], map()) :: [String.t()] | nil
  def round_label(calls, ctx) when is_list(calls) do
    case Map.get(ctx, :ifc) do
      %{} = wire -> Context.round_label(wire, Declaration.declared_sources(calls))
      _other -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # One effect
  # ---------------------------------------------------------------------------

  defp decide(call, ctx) do
    name = to_string(call[:name] || call["name"] || "")
    args = call[:args] || call["args"] || %{}
    ctx = delegated_request_context(name, args, ctx)

    destinations = [
      Destination.describe(name, args, ctx) | Destination.additional_destinations(name, args)
    ]

    Enum.reduce_while(destinations, {:execute, call}, fn
      {class, descriptor}, {:execute, checked} when class in @decided ->
        case decide_effect(checked, name, args, descriptor, ctx) do
          {:execute, _} = allowed -> {:cont, allowed}
          blocked -> {:halt, blocked}
        end

      _, result ->
        {:cont, result}
    end)
  end

  defp delegated_request_context(name, args, ctx) do
    mod = Application.get_env(:salix_agent, :im_provider_mod)

    if mod && Code.ensure_loaded?(mod) && function_exported?(mod, :task_execution_request, 3) do
      case mod.task_execution_request(name, args, ctx) do
        {:ok, source_id, principal, source_scope} ->
          Map.update(ctx, :ifc, nil, fn wire ->
            delegated = Context.delegate_request(wire, source_id, principal)

            if delegated != wire,
              do: Map.put(delegated, "source_scope", source_scope),
              else: wire
          end)

        {:ok, source_id, principal} ->
          Map.update(ctx, :ifc, nil, &Context.delegate_request(&1, source_id, principal))

        _ ->
          ctx
      end
    else
      ctx
    end
  end

  defp decide_effect(call, name, args, descriptor, ctx) do
    {wire, declaration} =
      SalixAgent.IFC.ChannelOnboarding.prepare(
        call,
        SalixAgent.IFC.Triage.prepare(call, Declaration.from_call(call), ctx),
        ctx
      )

    items = Context.items(wire || %{})

    request =
      declaration.request || Context.default_request(wire || %{}) || ""

    case IFC.resolve(request_payload(descriptor, declaration, items, wire, ctx)) do
      {:ok, reply} ->
        reply = own_audience_destination(reply, descriptor, declaration, items)

        apply_mode(
          IFC.mode(reply),
          call,
          name,
          args,
          request,
          declaration,
          items,
          wire,
          reply,
          ctx
        )

      {:error, reason} ->
        # The resolver could not answer. Fail closed only where a Group asked
        # to be enforced; anywhere else this is an observability problem, not
        # a reason to break the workspace.
        unavailable(call, ctx, reason)
    end
  end

  # A destination whose audience *is* the effect's own sources: the
  # per-audience memory home of §8. The resolver cannot answer for it, because
  # only the dispatcher sees what the model declared — so the join is made
  # here and handed to the kernel as an ordinary destination label. Nothing
  # about the decision is special-cased: with a destination that carries every
  # restriction its sources carry, `flow_ok` simply holds, which is precisely
  # what "this note is not leaving the audience it came from" means.
  #
  # `sources: :context` is the honest fail-closed reading — the model declared
  # nothing, so the note inherits the whole context's audience.
  defp own_audience_destination(reply, %{"kind" => "memory_scoped"}, declaration, items) do
    source_items =
      case declaration.sources do
        :context -> items
        refs -> Enum.filter(items, &(&1.ref in refs))
      end

    label =
      source_items
      |> Enum.map(& &1.label)
      |> Label.join_all()
      |> Codec.encode_label()

    Map.put(reply, "destination", %{"label" => label, "writers" => "any"})
  end

  defp own_audience_destination(reply, _descriptor, _declaration, _items), do: reply

  defp apply_mode(:off, call, _name, _args, _request, _declaration, _items, _wire, _reply, _ctx),
    do: {:execute, call}

  defp apply_mode(mode, call, name, args, request, declaration, items, wire, reply, ctx) do
    facts = Codec.decode_facts(reply)
    destination = destination_label(reply)
    writers = writers(reply)

    effect = %Effect{
      destination: destination,
      writers: writers,
      request: request,
      sources: declaration.sources
    }

    decision =
      case Context.activation(wire || %{}) do
        {:ok, activation} -> kernel_decide(effect, activation, items, facts)
        :error -> {:deny, %Reason{clause: :invalid_input, detail: :activation}}
      end

    archive(ctx, call, name, mode, decision)

    case {mode, decision} do
      # A receipt authorizes one transfer, so the effect that uses it spends
      # it here, between the verdict and the call. Only enforce spends: audit
      # may not change an outcome, and a receipt consumed under audit would
      # change a later one.
      {:enforce, {:allow, evidence}} ->
        case spend_receipts(evidence, ctx) do
          :ok ->
            {:execute, admit(call, name, args, evidence, items, reply)}

          {:error, detail} ->
            {:blocked,
             refuse(
               call,
               %Reason{clause: :invalid_input, detail: detail},
               items,
               facts,
               wire,
               reply
             )}
        end

      {_mode, {:allow, evidence}} ->
        {:execute, admit(call, name, args, evidence, items, reply)}

      {:audit, {:deny, _reason}} ->
        {:execute, call}

      {:enforce, {:deny, reason}} ->
        {:blocked, refuse(call, reason, items, facts, wire, reply)}
    end
  end

  # Every receipt the verdict leaned on, spent before the effect runs. An
  # effect that cannot claim one — already spent by a concurrent effect, or a
  # store that cannot answer — does not get to act on it.
  defp spend_receipts(evidence, ctx) do
    evidence |> SalixIFC.transfer_start() |> spend_receipts_step(ctx)
  end

  defp spend_receipts_step(:ok, _ctx), do: :ok
  defp spend_receipts_step({:error, _detail} = error, _ctx), do: error

  defp spend_receipts_step({:consume, id, cursor}, ctx) do
    request = %{
      "tenant_id" => text(Map.get(ctx, :tenant_id) || Map.get(ctx, "tenant_id")),
      "group_id" => text(Map.get(ctx, :group_id) || Map.get(ctx, "group_id")),
      "receipt_id" => id
    }

    cursor
    |> SalixIFC.transfer_resume(IFC.consume_receipt(request))
    |> spend_receipts_step(ctx)
  end

  # An allowed effect carries its evidence forward: the provenance footer of
  # rule B, the label a durable resource this effect creates must inherit,
  # and the archived clause that admitted each source.
  defp admit(call, name, args, evidence, items, reply) do
    names = declassified_names(evidence, items, reply)

    args = Provenance.apply(name, args, Provenance.footer(names, IFC.language(reply)))

    call
    |> Map.put(:args, args)
    |> Map.put("args", args)
    |> Map.put(:ifc_evidence, %{
      "decision" => Codec.encode_decision({:allow, evidence}),
      "requester" => Codec.encode_principal!(evidence.requester),
      "sources_label" => Codec.encode_label(sources_label(evidence, items)),
      "declassified" => names
    })
  end

  # The join of everything this effect drew on: what a resource created by it
  # must carry so that reading the resource later is no weaker than reading
  # its sources would have been.
  defp sources_label(evidence, items) do
    index = Map.new(items, &{&1.ref, &1})

    evidence.sources
    |> Enum.flat_map(fn {ref, _clause} ->
      case Map.fetch(index, ref) do
        {:ok, item} -> [item.label]
        :error -> []
      end
    end)
    |> Label.join_all()
  end

  defp refuse(call, %Reason{} = reason, items, facts, wire, reply) do
    Guidance.result(call, reason,
      source_name: readable_source_name(reason, items, facts, wire, reply),
      destination_name: display_name(reply, destination_label(reply)),
      destination: Codec.encode_label(destination_label(reply)),
      language: IFC.language(reply)
    )
  end

  # The source is named only when the requester could already read it.
  # Naming it otherwise would disclose that it exists, which is exactly what
  # the refusal is protecting.
  defp readable_source_name(%Reason{ref: ref}, items, facts, wire, reply) when is_binary(ref) do
    with %{} = item <- Enum.find(items, &(&1.ref == ref)),
         {:ok, activation} <- Context.activation(wire || %{}),
         true <- SalixIFC.reader?(activation.requester, item.label, facts) == true do
      display_name(reply, item.label)
    else
      _other -> nil
    end
  end

  defp readable_source_name(_reason, _items, _facts, _wire, _reply), do: nil

  # An origin with no display name still has to be said. Dropping it would
  # turn "this came from somewhere else" into silence, which is the one thing
  # rule B exists to prevent.
  defp declassified_names(evidence, items, reply) do
    refs = Provenance.declassified_refs(evidence)
    index = Map.new(items, &{&1.ref, &1})

    names =
      refs
      |> Enum.flat_map(fn ref ->
        case Map.fetch(index, ref) do
          {:ok, item} -> List.wrap(display_name(reply, item.label))
          :error -> []
        end
      end)
      |> Enum.uniq()

    cond do
      names != [] -> names
      refs == [] -> []
      IFC.language(reply) == :en -> ["another conversation"]
      true -> ["其他对话"]
    end
  end

  # ---------------------------------------------------------------------------
  # Resolver payload and reply
  # ---------------------------------------------------------------------------

  defp request_payload(descriptor, declaration, items, wire, ctx) do
    %{
      "tenant_id" => text(Map.get(ctx, :tenant_id)),
      "group_id" => text(Map.get(ctx, :group_id)),
      "agent_id" => text(Map.get(ctx, :agent_id)),
      "session_id" => text(Map.get(ctx, :session_id)),
      "requester" => Map.get(wire || %{}, "requester"),
      "destination" => descriptor,
      "atoms" => atoms(declaration, items, wire),
      "trusted_origin" => Map.get(ctx, :trusted_origin) || Map.get(ctx, "trusted_origin"),
      "now" => System.system_time(:millisecond)
    }
  end

  # Everything the decision can touch: the sources the effect declared (or
  # the whole context when it declared none) plus the activation's own scope.
  defp atoms(declaration, items, wire) do
    source_items =
      case declaration.sources do
        :context -> items
        refs -> Enum.filter(items, &(&1.ref in refs))
      end

    scope = Map.get(wire || %{}, "source_scope", [])

    source_items
    |> Enum.flat_map(&Codec.encode_label(&1.label))
    |> Enum.concat(List.wrap(scope))
    |> Enum.uniq()
  end

  defp destination_label(reply) do
    reply
    |> Map.get("destination", %{})
    |> case do
      %{} = destination -> Codec.decode_label(Map.get(destination, "label"), Context.private())
      _other -> Context.private()
    end
  end

  defp writers(reply) do
    reply
    |> Map.get("destination", %{})
    |> case do
      %{} = destination -> decode_writers(Map.get(destination, "writers"))
      _other -> :unknown
    end
  end

  defp decode_writers("any"), do: :any
  defp decode_writers(:any), do: :any

  defp decode_writers(writers) when is_list(writers) do
    writers
    |> Enum.flat_map(fn writer ->
      case Codec.decode_principal(writer) do
        {:ok, principal} -> [Principal.key(principal)]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  defp decode_writers(_writers), do: :unknown

  # A label's display name is the resolver's to give: a channel name, "私聊",
  # a tag's label. The kernel only ever sees opaque ids.
  defp display_name(reply, %Label{} = label) do
    names = Map.get(reply, "display_names", %{})

    label
    |> Codec.encode_label()
    |> Enum.flat_map(fn atom ->
      case Map.get(names, atom) do
        name when is_binary(name) and name != "" -> [name]
        _other -> []
      end
    end)
    |> case do
      [] -> nil
      found -> Enum.join(found, " / ")
    end
  end

  defp display_name(_reply, _label), do: nil

  # ---------------------------------------------------------------------------
  # Archive and failure
  # ---------------------------------------------------------------------------

  defp kernel_decide(effect, activation, items, facts) do
    started = System.monotonic_time()

    try do
      result = SalixIFC.decide(effect, activation, items, facts)

      outcome =
        case result do
          {:allow, _} -> "ok"
          {:deny, _} -> "rejected"
        end

      emit_kernel_operation(outcome, started)
      result
    catch
      kind, reason ->
        emit_kernel_operation("error", started)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_kernel_operation(outcome, started) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "ifc_decide",
      SystemsObservability.Context.current_surface(),
      outcome,
      System.monotonic_time() - started
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp archive(ctx, call, name, mode, decision) do
    EventArchive.Emit.ifc_decision(ctx, %{
      "tool" => name,
      "tool_call_id" => to_string(call[:id] || call["id"] || ""),
      "call_index" => call[:call_index] || call["call_index"],
      "mode" => Atom.to_string(mode),
      "decision" => Codec.encode_decision(decision)
    })
  end

  # The resolver could not answer. A Group that asked to be enforced is
  # enforced: no facts means no permission, and the refusal says so. Audit
  # mode records the outage and changes nothing, which is its whole contract.
  defp unavailable(call, ctx, reason) do
    EventArchive.Emit.ifc_decision(ctx, %{
      "tool" => to_string(call[:name] || call["name"] || ""),
      "tool_call_id" => to_string(call[:id] || call["id"] || ""),
      "mode" => Atom.to_string(IFC.mode(Map.get(ctx, :ifc_mode))),
      "outcome" => "unavailable",
      "error" => inspect(reason)
    })

    if IFC.mode(Map.get(ctx, :ifc_mode)) == :enforce do
      {:blocked,
       Guidance.result(call, %Reason{clause: :invalid_input, detail: :facts_unavailable})}
    else
      {:execute, call}
    end
  end

  # `SessionToolDispatch` merges executed results back over the dispatch's
  # decisions, so results arrive in the order of the calls they came from.
  # When that correspondence does not hold there is no way to tell which
  # result came from a read, so nothing claims to be one.
  defp read_flags(results, calls, ctx) do
    if length(results) == length(calls) do
      Enum.map(calls, &read?(&1, ctx))
    else
      Enum.map(results, fn _result -> false end)
    end
  end

  defp read?(call, ctx) do
    name = to_string(call[:name] || call["name"] || "")
    args = call[:args] || call["args"] || %{}

    case Destination.describe(name, args, ctx) do
      {:read, _descriptor} -> true
      _other -> false
    end
  end

  defp result_label(result) when is_map(result) do
    case Map.get(result, :ifc) || Map.get(result, "ifc") do
      %{"label" => label} = block when is_list(label) -> block
      _other -> nil
    end
  end

  defp result_label(_result), do: nil

  defp put_ifc(result, block) when is_map(result), do: Map.put(result, :ifc, block)
  defp put_ifc(result, _block), do: result

  defp text(value), do: IFC.text(value)
end
