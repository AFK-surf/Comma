defmodule SalixAgent.IFC.Context do
  @moduledoc """
  The labelled view of one session that a decision reads: every transcript
  item with its `src:` ref and label, plus the current activation's
  requester, source scope and consumed request refs.

  This is built once per dispatch, from the session the caller already holds,
  and travels on the tool context as plain JSON-able data (`SalixIFC.Codec`
  encoding) so it can cross the external-runtime and JavaScript host seams and
  be archived verbatim.

  Nothing is filtered. The model sees the whole context (§7); this structure
  exists so that an *effect* can be checked against what it says it used, not
  so that anything can be withheld from the prompt.

  Labels come from three places, in order:

    * an input's sealed `trusted_origin["ifc"]`, written by provider ingress;
    * a tool result's or assistant record's `ifc` field, written by the
      dispatcher and the round when they commit;
    * nothing, which reads as `agent_private` — no human reader. That is the
      fail-closed default for pre-cutover records, and the reason enforce mode
      ships together with one Router session rotation (§13).
  """

  require SalixAgent.InternalSession

  alias SalixAgent.InternalSession
  alias SalixIFC.{Activation, Codec, Item, Label}

  @private ["agent_private"]

  @type wire :: %{optional(String.t()) => term()}

  @doc """
  Builds the wire context for one dispatch.

  `opts` carries what the caller already resolved for this activation:
  `:source_message_id` (the singular current wakeable authority),
  `:source_message_ids` (the activation-wide set) and `:trusted_origin`.

  The projection over the transcript — every record's `src:` ref, label,
  integrity and principal, the consumed command refs, and the activation's
  request — is the `ifc_context` kernel query. Only `opts` crosses as data.
  """
  @spec build(term(), keyword()) :: wire()
  def build(session, opts \\ []) do
    InternalSession.query(
      handle(session),
      :ifc_context,
      {Keyword.get(opts, :source_message_id),
       opts |> Keyword.get(:source_message_ids, []) |> List.wrap(),
       Keyword.get(opts, :trusted_origin)}
    )
  end

  @doc "Use a provider-validated delegated command for one effect, without changing the transcript."
  def delegate_request(wire, source_id, principal) when is_map(wire) do
    with ref when is_binary(ref) <- get_in(wire, ["input_refs", source_id]),
         item when is_map(item) <- Enum.find(wire["items"] || [], &(&1["ref"] == ref)) do
      wire
      |> Map.put("requester", principal)
      |> Map.put("request", ref)
      |> Map.put("source_scope", item["label"])
      |> Map.put("consumed_refs", Enum.uniq([ref] ++ List.wrap(wire["consumed_refs"])))
      |> Map.update!("items", fn items ->
        Enum.map(items, fn current ->
          if current["ref"] == ref,
            do: Map.merge(current, %{"integrity" => "command", "principal" => principal}),
            else: current
        end)
      end)
    else
      _ -> wire
    end
  end

  def delegate_request(wire, _source_id, _principal), do: wire

  @doc "Organization grants on consumed commands, independent of the latest input or IFC mode."
  def organization_scopes(session, source_message_ids, kind \\ "meeting_preparation") do
    InternalSession.query(
      handle(session),
      :ifc_organization_scopes,
      {List.wrap(source_message_ids), kind}
    )
  end

  @doc "The kernel items of a wire context."
  @spec items(wire()) :: [Item.t()]
  def items(%{} = wire) do
    wire
    |> Map.get("items", [])
    |> List.wrap()
    |> Enum.flat_map(fn item ->
      with true <- is_map(item),
           ref when is_binary(ref) and ref != "" <- item["ref"] do
        [
          %Item{
            ref: ref,
            label: Codec.decode_label(item["label"], private()),
            integrity: integrity(item["integrity"]),
            principal: decode_principal(item["principal"])
          }
        ]
      else
        _other -> []
      end
    end)
  end

  def items(_wire), do: []

  @doc """
  The kernel activation of a wire context, or `:error` when it names no
  requester. An activation without an authorized principal can command nothing.
  """
  @spec activation(wire()) :: {:ok, Activation.t()} | :error
  def activation(%{} = wire) do
    case decode_principal(wire["requester"]) do
      nil ->
        :error

      requester ->
        {:ok,
         %Activation{
           requester: requester,
           source_scope: Codec.decode_label(wire["source_scope"], private()),
           consumed_refs: wire |> Map.get("consumed_refs", []) |> List.wrap() |> MapSet.new()
         }}
    end
  end

  def activation(_wire), do: :error

  @doc "The ref the model's declaration defaults to: this activation's singular source."
  @spec default_request(wire()) :: String.t() | nil
  def default_request(%{} = wire), do: wire["request"]
  def default_request(_wire), do: nil

  @doc """
  The label a record the model produced in this round must carry: the join of
  the labels of every source declared on the round's effects (§3.3, last
  row).

  Only data flow is labelled. The activation's source scope — where the
  request came from — is control flow: it says who asked and where, not what
  the record contains, and is deliberately not joined. An answer built from a
  public page is public even when it was asked for in a DM; the DM is among
  its sources only if the model declared it, which it does exactly when the
  DM's own content is in the answer (§4).

  A round that declares nothing anywhere — no effect at all, or an effect
  with `sources: "context"` — joins the whole context, which is the same
  fail-closed reading `sources: "context"` gets at the effect.
  """
  @spec round_label(wire(), [term()]) :: [String.t()]
  def round_label(wire, declarations) when is_list(declarations) do
    index = Map.new(items(wire), &{&1.ref, &1})
    everything = Enum.map(Map.values(index), & &1.label)

    labels =
      case declarations do
        [] ->
          everything

        declarations ->
          Enum.flat_map(declarations, fn
            refs when is_list(refs) -> Enum.flat_map(refs, &label_of(index, &1))
            _context -> everything
          end)
      end

    Codec.encode_label(Label.join_all(labels))
  end

  @doc "The label of one item in a wire context, encoded; `nil` when absent."
  @spec label_for(wire(), String.t()) :: [String.t()] | nil
  def label_for(wire, ref) do
    wire
    |> items()
    |> Enum.find(&(&1.ref == ref))
    |> case do
      nil -> nil
      item -> Codec.encode_label(item.label)
    end
  end

  @doc "The fail-closed label: readable by the runtime and no human."
  @spec private() :: Label.t()
  def private, do: Label.new([:agent_private])

  @doc "The wire form of the fail-closed label."
  @spec private_wire() :: [String.t()]
  def private_wire, do: @private

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp label_of(index, ref) do
    case Map.fetch(index, ref) do
      {:ok, item} -> [item.label]
      # A declared ref that names nothing is not a licence to ignore it: the
      # kernel refuses the effect anyway, and the round's own label must not
      # get looser because a ref was mistyped.
      :error -> [private()]
    end
  end

  defp integrity("command"), do: :command
  defp integrity(:command), do: :command
  defp integrity(_other), do: :data

  # Callers hold either the opaque session handle or a plain state map: the
  # external runtime assembles one, and tools and tests pass one directly. The
  # kernel owns the projection either way; a map is admitted for the one read.
  defp handle(session) when InternalSession.is_session(session), do: session
  defp handle(session) when is_map(session), do: InternalSession.open_envelope(session)
  defp handle(_session), do: InternalSession.open(%{})

  defp decode_principal(value) do
    case Codec.decode_principal(value) do
      {:ok, principal} -> principal
      :error -> nil
    end
  end
end
