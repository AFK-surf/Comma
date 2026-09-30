defmodule SalixAgent.IFC.Declaration do
  @moduledoc """
  The two self-descriptions the model attaches to an outgoing effect
  (`docs/verification.md` §4):

      "ifc": { "request": "src:q-4471", "sources": ["src:t-88#2"] }

  Both are statements of fact about what the model just did — which input it
  is acting on, and which labelled items the content carries or is derived
  from — never a label and never a judgement about who may read what.

  `sources` tracks data flow only. An item that merely directed the effect —
  what to do, where to send it, how to present it — is control flow and is
  not a source, even when it is the request; the request is a source exactly
  when its own content is in the effect. Nothing adds the request implicitly.

  Defaults are the conservative ones. An absent `request` is the activation's
  singular source authority. An absent `sources` is `"context"`: every item
  in the context, which fails closed as soon as the context holds anything
  the destination may not read. Declaring sources is the normal path, and
  `[]` is the honest declaration for an effect that carries no labelled
  content at all.
  """

  @type t :: %{request: String.t() | nil, sources: [String.t()] | :context}

  @doc "The `ifc` object accepted on the `call` envelope and the external-runtime body."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "description" =>
        "Provenance of this effect. request is the src: ref of the human input you are acting on; sources are the src: refs whose content this effect carries or is derived from. Sources track data, not instructions: an input that only said what to do or how to present it is not a source, even when it is the request. Omit sources only if you cannot enumerate them: the default counts the entire context, which is refused as soon as the context holds anything the destination may not read. Use [] when the effect carries no content from the conversation.",
      "properties" => %{
        "request" => %{
          "type" => "string",
          "description" => "src: ref of the human input this effect acts on."
        },
        "sources" => %{
          "oneOf" => [
            %{"type" => "array", "items" => %{"type" => "string"}},
            %{"type" => "string", "enum" => ["context"]}
          ],
          "description" =>
            "src: refs whose content this effect carries or is derived from, or \"context\". Not the inputs that only instructed it."
        }
      }
    }
  end

  @doc """
  Reads the declaration a call carries, prepared or raw.

  A prepared call carries it on the call itself, lifted out of the envelope
  by `SalixAgent.Tools`. A raw call still has it inside the `call` envelope's
  arguments, which is where the round reads it when it labels its own
  assistant record before any dispatch has happened.
  """
  @spec from_call(map()) :: t()
  def from_call(call) when is_map(call) do
    args = Map.get(call, :args) || Map.get(call, "args") || %{}

    parse(
      Map.get(call, :ifc) || Map.get(call, "ifc") ||
        (is_map(args) and (Map.get(args, "ifc") || Map.get(args, :ifc)))
    )
  end

  def from_call(_call), do: parse(nil)

  @doc "Normalizes a raw `ifc` object into the two fields the kernel needs."
  @spec parse(term()) :: t()
  def parse(%{} = raw) do
    %{
      request: request(Map.get(raw, "request", Map.get(raw, :request))),
      sources: sources(Map.get(raw, "sources", Map.get(raw, :sources)))
    }
  end

  def parse(_raw), do: %{request: nil, sources: :context}

  @doc """
  Splits a declaration out of a tool's argument map.

  The external-runtime body and the JavaScript host call carry the same
  object as the `call` envelope does, but as a sibling of the tool's own
  parameters. Lifting it here keeps every disclosed schema exactly as
  published: no tool ever sees an `ifc` argument.
  """
  @spec lift(term()) :: {map(), map() | nil}
  def lift(args) when is_map(args) do
    case Map.get(args, "ifc", Map.get(args, :ifc)) do
      %{} = ifc -> {args |> Map.delete("ifc") |> Map.delete(:ifc), ifc}
      _other -> {args, nil}
    end
  end

  def lift(args), do: {args, nil}

  @doc "The declared sources of a batch of calls, for the round's own label."
  @spec declared_sources([map()]) :: [[String.t()] | :context]
  def declared_sources(calls) when is_list(calls),
    do: Enum.map(calls, &from_call(&1).sources)

  defp request(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      ref -> ref
    end
  end

  defp request(_value), do: nil

  # An unreadable `sources` value is not an error the model can exploit: it
  # falls back to the whole context, which is the most restrictive reading.
  defp sources(value) when is_list(value) do
    refs =
      value
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if length(refs) == length(value), do: refs, else: :context
  end

  defp sources(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, refs} when is_list(refs) -> sources(refs)
      _ -> :context
    end
  end

  defp sources(_value), do: :context
end
