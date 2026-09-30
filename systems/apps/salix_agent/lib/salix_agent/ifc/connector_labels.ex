defmodule SalixAgent.IFC.ConnectorLabels do
  @moduledoc """
  The audience a connector read returned
  (`docs/verification.md` §3.3, §15).

  An MCP binding and a Composio connection are both configured per Group and
  authorized as the Group — Composio's `user_id` *is* the group id, and an MCP
  binding is a group binding — so anyone in the Group could have made the same
  call themselves. That is exactly the audience `{:group, id}` names, the same
  one Group memory has.

  Saying so matters more than it looks. Without a label of its own a connector
  result is not a *read* in `SalixAgent.IFC.Destination`'s sense — the call
  sends arguments out, so it is classified as egress — and
  `SalixAgent.IFC.Check.stamp_results/3` would give it **the round's** label:
  the join of what the model declared this round. A round that honestly
  declared `sources: []` would therefore stamp a private page fetched through
  a connector as `{public}`, and an honest citation of it would flow anywhere.
  The round's label describes records the model produced, and content returned
  from outside is not one of those.

  Fail-closed when there is no Group to name: a connector call with no group in
  context reads as agent-private, which flows nowhere.
  """

  alias SalixIFC.{Codec, Label}

  @doc """
  Attaches the Group's audience to a connector result.

  Silent for a session that is not labelling, exactly as
  `SalixAgent.IFC.FileLabels` is: stamping there would put a label on results
  that predate the decision to have one.
  """
  @spec group_audience(term(), map()) :: term()
  def group_audience(result, ctx) when is_map(ctx) do
    if is_map(Map.get(ctx, :ifc)) do
      attach(result, %{"label" => label(ctx)})
    else
      result
    end
  end

  def group_audience(result, _ctx), do: result

  defp label(ctx) do
    case SalixAgent.IFC.text(Map.get(ctx, :group_id) || Map.get(ctx, "group_id")) do
      "" -> Codec.encode_label(Label.new([:agent_private]))
      group_id -> encode({:group, group_id})
    end
  end

  defp encode(atom) do
    case Codec.encode_atom(atom) do
      {:ok, encoded} -> [encoded]
      :error -> Codec.encode_label(Label.new([:agent_private]))
    end
  end

  defp attach({content, events}, ifc) when is_binary(content) and is_list(events),
    do: {:tool_ifc, content, events, ifc}

  defp attach(content, ifc) when is_binary(content), do: {:tool_ifc, content, [], ifc}

  # A status result, a failure, or anything else that is not plain content
  # keeps its own shape.
  defp attach(result, _ifc), do: result
end
