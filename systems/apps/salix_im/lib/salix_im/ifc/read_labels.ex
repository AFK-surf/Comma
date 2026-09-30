defmodule SalixIM.IFC.ReadLabels do
  @moduledoc """
  The audience a read actually returned
  (`docs/verification.md` §3.3, §15).

  A read is never filtered — the model sees every hit it is allowed to see
  (§7). What this decides is what those hits are *labelled*, so that an effect
  citing one can be checked against the audience the content really came from.

  Without it the runtime knows nothing about a read's audience, and
  `SalixAgent.IFC.Check.stamp_results/3` has to fall back to `agent_private`:
  correct, but blunt enough that under `enforce` a search cannot be answered
  from at all. With it a workspace search over a public channel and a private
  one comes back labelled per hit, so quoting the public hit flows and quoting
  the private one is refused — which is the whole point of labelling rather
  than filtering.

  Two shapes, because reads come in two:

    * **one scope** — `get_channel_history`, `get_thread_replies`,
      `semantic_search`. Every message shares the channel's audience, so the
      result carries one label and no per-hit items.
    * **many scopes** — `search` across the workspace. Each hit is labelled by
      the channel it came from, and the result's own label is the join of all
      of them, so citing the whole result is as restrictive as citing its most
      private hit while citing one hit by ref is exactly as restrictive as that
      hit.

  Off unless the Group asked for it. A Group with the check off pays one
  cached mode read and nothing else — no projection lookup, no `conversations.info`.
  """

  require Logger

  alias SalixIM.IFC.{Facts, Ingress}
  alias SalixIFC.{Codec, Label}

  @doc """
  The `ifc` block for a read whose hits all come from one scope, or `nil` when
  this Group is not labelling.
  """
  @spec for_scope(map(), term()) :: map() | nil
  def for_scope(connect, scope_id) when is_map(connect) do
    with %{} = scope <- labelling_scope(connect),
         atoms when is_list(atoms) <- Ingress.scope_atoms(scope, scope_id) do
      %{"label" => Enum.sort(atoms)}
    else
      _not_labelled -> nil
    end
  end

  def for_scope(_connect, _scope_id), do: nil

  @doc """
  The `ifc` block for one indivisible thing that lives in several scopes at
  once — a file shared into three channels, a canvas attached to one.

  The label is the join of every scope it lives in, which is *more* restrictive
  than any one of them. That over-approximates: someone in only one of those
  channels can in fact see the file. It is the safe direction, and it is the
  only one available without a per-reader membership answer, so a file shared
  into a public channel and a sealed one is treated as belonging to both.

  A scope that cannot be labelled contributes the fail-closed label rather than
  being skipped, and an empty list is `nil` — nothing was established, so
  nothing is claimed.
  """
  @spec for_scopes(map(), [term()]) :: map() | nil
  def for_scopes(connect, scope_ids) when is_map(connect) and is_list(scope_ids) do
    ids = scope_ids |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    with false <- ids == [],
         %{} = scope <- labelling_scope(connect) do
      %{"label" => join(Enum.map(ids, &scope_label(scope, &1)))}
    else
      _not_labelled -> nil
    end
  end

  def for_scopes(_connect, _scope_ids), do: nil

  @doc """
  The `ifc` block for a read whose hits come from different scopes.

  `messages` is the list as it will be rendered, so a hit's index here is the
  index the model can cite (`src:t-<id>#<index>`). A hit whose channel cannot
  be labelled contributes the fail-closed label rather than being skipped:
  an unknown audience must not quietly make the aggregate looser.
  """
  @spec for_messages(map(), [map()], String.t()) :: map() | nil
  def for_messages(connect, messages, key \\ "channel")

  def for_messages(connect, messages, key) when is_map(connect) and is_list(messages) do
    case labelling_scope(connect) do
      %{} = scope -> messages_block(scope, messages, key)
      _off -> nil
    end
  end

  def for_messages(_connect, _messages, _key), do: nil

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp messages_block(scope, messages, key) do
    # One projection read per distinct channel, not per hit: a 200-row search
    # over four channels asks four times.
    labels =
      messages
      |> Enum.map(&channel_of(&1, key))
      |> Enum.uniq()
      |> Map.new(&{&1, scope_label(scope, &1)})

    items =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {message, index} ->
        %{"index" => index, "label" => Map.fetch!(labels, channel_of(message, key))}
      end)

    %{"label" => join(Map.values(labels)), "items" => items}
  end

  defp channel_of(message, key) when is_map(message), do: text(message[key])
  defp channel_of(_message, _key), do: ""

  defp scope_label(scope, scope_id) do
    case Ingress.scope_atoms(scope, scope_id) do
      atoms when is_list(atoms) -> Enum.sort(atoms)
      _unknown -> private()
    end
  end

  # The join is computed through the kernel's own label algebra rather than by
  # concatenating strings, so "the whole result" means exactly what it means
  # everywhere else.
  defp join([]), do: private()

  defp join(encoded_labels) do
    encoded_labels
    |> Enum.map(&Codec.decode_label(&1, Label.new([:agent_private])))
    |> Label.join_all()
    |> Codec.encode_label()
  end

  defp private, do: ["agent_private"]

  # The Group's own answer, cached, and the tenant/group the projection reads
  # under. `off` short-circuits before any projection work.
  defp labelling_scope(connect) do
    tenant_id = text(connect["tenant_id"])
    group_id = text(connect["group_id"])
    connect_id = text(connect["connect_id"])

    if group_id == "" or connect_id == "" or Facts.mode(tenant_id, group_id) == "off" do
      nil
    else
      %{tenant_id: tenant_id, group_id: group_id, connect_id: connect_id}
    end
  rescue
    exception ->
      # A labelling fault must never fail the read. Returning nil leaves the
      # result unlabelled, which reads as agent-private downstream.
      Logger.warning("ifc read labelling unavailable: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason -> nil
  end

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
