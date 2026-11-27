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

  An absent `request` uses the activation's singular source authority.
  When IFC is enabled, effects require explicit source arrays. Missing or
  malformed declarations are rejected before authorization. `[]` declares
  that the effect carries no labelled content. The permissive parser remains
  for disabled IFC and conservative transcript labels, not effect admission.
  """

  @type t :: %{request: String.t() | nil, sources: [String.t()] | :context}

  @doc "The `ifc` object accepted on the `call` envelope and the external-runtime body."
  @spec schema() :: map()
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "description" =>
        "Provenance of this effect. request is the src: ref of the input you are acting on; sources are the src: refs whose content this effect carries or is derived from. Sources track data, not instructions: an input that only said what to do or how to present it is not a source, even when it is the request. When IFC is enabled, sources must be an explicit array. The optional context form is retained only for disabled-mode compatibility. Use [] when the effect carries no content from the conversation.",
      "properties" => %{
        "request" => %{
          "type" => "string",
          "pattern" => "^src:[^\\s\\[\\]]+$",
          "description" =>
            "Input reference ID, not a task description. Copy the src: ID from the [src:...] marker on the input you act on, e.g. src:q-4471 or src:a-88. Do not include brackets or other text."
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

  @doc "Requires explicit declarations on model calls when IFC is enabled."
  def for_mode(specs, mode) do
    if SalixAgent.IFC.mode(mode) == :off do
      specs
    else
      Enum.map(specs, fn
        %{"name" => "call"} = spec ->
          update_in(spec, ["input_schema"], &call_schema/1)

        %{"name" => "end_turn"} = spec ->
          spec
          |> update_in(["input_schema", "properties", "reply"], &require_declaration/1)
          |> Map.update!(
            "description",
            &(&1 <>
                " When supplying reply, use reply={tool,params,ifc}; reply.ifc must include an explicit sources array, including [] when no source content is carried.")
          )

        spec ->
          spec
      end)
    end
  end

  @doc "Adds the enabled-mode declaration contract to a tool argument schema."
  def require_declaration(envelope) do
    declaration =
      schema()
      |> Map.put("required", ["sources"])
      |> Map.put(
        "description",
        "Declare the input this effect acts on and the content sources it uses. Sources are required when IFC is enabled. Use [] only when the effect carries no source content."
      )
      |> put_in(["properties", "sources"], %{
        "type" => "array",
        "items" => %{"type" => "string", "pattern" => "^src:.+"},
        "uniqueItems" => true,
        "description" =>
          "Complete src: IDs whose content the arguments or reply carry, summarize, or derive conclusions from. Include tool results you report. Exclude instructions or help used only for calling syntax. Use [] only when the content carries or derives from no sources."
      })

    envelope
    |> Map.update("properties", %{"ifc" => declaration}, &Map.put(&1, "ifc", declaration))
    |> Map.update("required", ["ifc"], &Enum.uniq(&1 ++ ["ifc"]))
  end

  @doc "A local query may omit its declaration only after runtime provenance validation."
  def for_tool(schema, name) do
    schema = require_declaration(schema)

    if SalixAgent.IFC.LocalMetadata.candidate?(name),
      do: optional_local_declaration(schema),
      else: schema
  end

  defp optional_local_declaration(schema) do
    schema
    |> Map.update!("required", &List.delete(&1, "ifc"))
    |> Map.update(
      "description",
      "",
      &(&1 <>
          " A declaration may be omitted only for a fixed local metadata query validated by the runtime. Explicit declarations must remain valid. Other calls require ifc.sources.")
    )
  end

  defp call_schema(schema), do: require_declaration(schema)

  @doc false
  def present?(call) do
    args = Map.get(call, :args) || Map.get(call, "args") || %{}

    Enum.any?(
      [:ifc, "ifc"],
      &(Map.has_key?(call, &1) or (is_map(args) and Map.has_key?(args, &1)))
    )
  end

  @doc "Rejects absent or malformed effect sources before any context expansion."
  def validate_sources(call) do
    with %{} = declaration <- raw(call),
         true <- valid_fields?(declaration),
         refs when is_list(refs) <-
           Map.get(declaration, "sources", Map.get(declaration, :sources)),
         true <- Enum.all?(refs, &valid_ref?/1),
         true <- length(Enum.uniq(refs)) == length(refs) do
      :ok
    else
      _ -> {:error, :sources_required}
    end
  end

  defp valid_fields?(declaration) do
    keys = Map.keys(declaration)

    Enum.all?(keys, &(&1 in [:request, :sources, "request", "sources"])) and
      length(Enum.uniq(Enum.map(keys, &to_string/1))) == length(keys) and
      case Map.fetch(declaration, "request") do
        {:ok, request} ->
          valid_ref?(request)

        :error ->
          case Map.fetch(declaration, :request) do
            {:ok, request} -> valid_ref?(request)
            :error -> true
          end
      end
  end

  defp valid_ref?("src:" <> rest = ref),
    do: rest != "" and Regex.match?(~r/\Asrc:[^\s\[\]]+\z/u, ref)

  defp valid_ref?(_), do: false

  defp raw(call) when is_map(call) do
    args = Map.get(call, :args) || Map.get(call, "args") || %{}

    Map.get(call, :ifc) || Map.get(call, "ifc") ||
      (is_map(args) and (Map.get(args, "ifc") || Map.get(args, :ifc)))
  end

  defp raw(_), do: nil

  @doc """
  Reads the declaration a call carries, prepared or raw.

  A prepared call carries it on the call itself, lifted out of the envelope
  by `SalixAgent.Tools`. A raw call still has it inside the `call` envelope's
  arguments, which is where the round reads it when it labels its own
  assistant record before any dispatch has happened.
  """
  @spec from_call(map()) :: t()
  def from_call(call), do: parse(raw(call))

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
  @spec lift(term()) :: {term(), term()}
  def lift(args) when is_map(args) do
    # Preserve invalid input for parameter validation. A runtime constructor
    # must not mistake a malformed declaration for an absent declaration.
    {Map.drop(args, ["ifc", :ifc]), Map.get(args, "ifc", Map.get(args, :ifc))}
  end

  def lift(args), do: {args, nil}

  @doc "Default sources only at a runtime-owned call constructor; never for model input."
  def runtime_sources(nil), do: %{"sources" => []}

  def runtime_sources(declaration) when is_map(declaration) do
    if Map.has_key?(declaration, "sources") or Map.has_key?(declaration, :sources),
      do: declaration,
      else: Map.put(declaration, "sources", [])
  end

  def runtime_sources(declaration), do: declaration

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

  # Conservative transcript parsing also reads old or disabled-mode records.
  # Enabled tool admission rejects these fallback forms before authorization.
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
