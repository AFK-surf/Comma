defmodule SalixAgent.Tools.IFC do
  @moduledoc """
  The Router's way of asking a person to move information somewhere it would
  not otherwise go (`docs/verification.md` §6.2).

  Declassification is a human act. When the algebra refuses a cross-scope
  relay — "post the summary of this DM thread to #eng", "remember this for
  the team", "publish this page" — the Router does not argue with the
  refusal and does not paraphrase its way around it. It calls this tool,
  which raises one durable capability request addressed to the requester.

  What makes the receipt worth anything is that it is *checked*, not
  claimed: approving the request writes a row scoped to
  `(requester, sources, destination)` with a bounded lifetime, and the next
  attempt at the same effect passes because the kernel finds that row — not
  because the model reports that the person said yes.

  Two invariants this tool enforces before a request is ever raised:

    * the requester must already be able to read every source. A receipt
      widens where information may go, never who may see it, so there is no
      route here to content the person cannot see themselves;
    * the destination is resolved from the effect's own parameters, exactly
      as the dispatcher resolves it, so the request a person approves is the
      flow that will actually happen.
  """

  alias SalixAgent.CapabilityRequestStore
  alias SalixAgent.IFC
  alias SalixAgent.IFC.{Context, Destination}
  alias SalixAgent.Tools.AsyncPolicy
  alias SalixAgent.Waits
  alias SalixIFC.Codec

  @wait AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @request_ttl_seconds 15 * 60
  @tool "ifc.request_declassification"

  def defs do
    [
      {@tool,
       "Ask the person who made the current request to confirm carrying named information to a destination that refused it. Use this only after a guidance refusal, with the same tool and params you were refused for, and only for sources that person can already read. The confirmation is durable: once given, retry the original call unchanged.",
       schema(), &__MODULE__.call/2, @wait, [roles: ["router"], safety: "write"]}
    ]
  end

  @doc false
  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tool" => %{
          "type" => "string",
          "description" =>
            "Canonical name of the effect that was refused, exactly as you called it."
        },
        "params" => %{
          "type" => "object",
          "description" =>
            "The refused effect's parameters, so its destination resolves identically."
        },
        "sources" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "minItems" => 1,
          "description" => "src: refs of the information to carry across."
        },
        "summary" => %{
          "type" => "string",
          "description" =>
            "One sentence, in the person's language, describing what would be carried and where. Shown to them verbatim."
        }
      },
      "required" => ["tool", "params", "sources", "summary"]
    }
  end

  @doc false
  def call(args, ctx) when is_map(args) and is_map(ctx) do
    args = stringify(args)
    target = to_string(args["tool"] || "")
    params = if is_map(args["params"]), do: args["params"], else: %{}
    refs = args["sources"] |> List.wrap() |> Enum.filter(&is_binary/1)
    summary = String.trim(to_string(args["summary"] || ""))
    wire = Map.get(ctx, :ifc)

    with :ok <- validate(target, refs, summary, wire),
         {:ok, descriptor} <- destination(target, params, ctx),
         {:ok, reply} <- resolve(descriptor, refs, wire, ctx),
         {:ok, activation} <- activation(wire),
         {:ok, sources} <- readable_sources(refs, wire, reply, activation),
         {:ok, request} <- raise_request(descriptor, sources, reply, summary, activation, ctx) do
      pending(request, args, summary, ctx)
    else
      {:error, reason} -> raise "#{@tool} failed: #{reason}"
    end
  end

  def call(_args, _ctx), do: raise("#{@tool} requires an object")

  @doc """
  The receipt one approved request writes: who confirmed it, what may move,
  where to, and until when.
  """
  @spec receipt_attrs(map(), non_neg_integer()) :: {:ok, String.t(), map()} | :error
  def receipt_attrs(%{"request_id" => request_id} = request, ttl_ms) do
    payload = get_in(request, ["request_payload", "ifc_declassify"]) || %{}

    with requester when is_binary(requester) and requester != "" <- payload["requester"],
         [_ | _] = sources <- strings(payload["source_atoms"]),
         [_ | _] = destination <- strings(payload["destination_atoms"]) do
      {:ok, request_id,
       %{
         requester_key: requester,
         source_atoms: sources,
         destination_atoms: destination,
         thread_ref: payload["thread_ref"],
         expires_at_ms: System.system_time(:millisecond) + ttl_ms
       }}
    else
      _other -> :error
    end
  end

  def receipt_attrs(_request, _ttl_ms), do: :error

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  defp validate(target, refs, summary, wire) do
    cond do
      target == "" -> {:error, "tool is required"}
      refs == [] -> {:error, "sources must name at least one src: ref"}
      summary == "" -> {:error, "summary is required"}
      not is_map(wire) -> {:error, "this session carries no labelled context"}
      true -> :ok
    end
  end

  defp destination(target, params, ctx) do
    case Destination.describe(target, params, ctx) do
      {class, descriptor} when class in [:egress, :persist] ->
        {:ok, descriptor}

      {class, _descriptor} ->
        {:error, "#{target} is #{class}; nothing about it needs confirming"}
    end
  end

  defp resolve(descriptor, refs, wire, ctx) do
    atoms =
      wire
      |> Context.items()
      |> Enum.filter(&(&1.ref in refs))
      |> Enum.flat_map(&Codec.encode_label(&1.label))
      |> Enum.uniq()

    request = %{
      "tenant_id" => to_string(Map.get(ctx, :tenant_id) || ""),
      "group_id" => to_string(Map.get(ctx, :group_id) || ""),
      "agent_id" => to_string(Map.get(ctx, :agent_id) || ""),
      "session_id" => to_string(Map.get(ctx, :session_id) || ""),
      "requester" => Map.get(wire, "requester"),
      "destination" => descriptor,
      "atoms" => atoms,
      "trusted_origin" => Map.get(ctx, :trusted_origin),
      "now" => System.system_time(:millisecond)
    }

    case IFC.resolve(request) do
      {:ok, reply} -> {:ok, reply}
      {:error, reason} -> {:error, "information-flow facts are unavailable: #{inspect(reason)}"}
    end
  end

  defp activation(wire) do
    case Context.activation(wire) do
      {:ok, activation} -> {:ok, activation}
      :error -> {:error, "this activation has no requester who could confirm"}
    end
  end

  # A receipt never widens beyond what the requester can read. Refusing here,
  # before a person is ever shown a card, keeps the model from turning a
  # confirmation prompt into a way to ask about content the person cannot see.
  defp readable_sources(refs, wire, reply, activation) do
    facts = Codec.decode_facts(reply)
    items = Context.items(wire)

    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
      case Enum.find(items, &(&1.ref == ref)) do
        nil ->
          {:halt, {:error, "#{ref} does not name an item in this session"}}

        item ->
          if SalixIFC.reader?(activation.requester, item.label, facts) == true do
            {:cont, {:ok, acc ++ Codec.encode_label(item.label)}}
          else
            {:halt,
             {:error,
              "#{ref} is not readable by the person who asked; there is nothing they could confirm"}}
          end
      end
    end)
    |> case do
      {:ok, atoms} -> {:ok, Enum.uniq(atoms)}
      error -> error
    end
  end

  defp raise_request(_descriptor, sources, reply, summary, activation, ctx) do
    destination = get_in(reply, ["destination", "label"]) || []

    CapabilityRequestStore.create_capability_request(%{
      "tenant_id" => to_string(Map.get(ctx, :tenant_id) || ""),
      "group_id" => to_string(Map.get(ctx, :group_id) || ""),
      "source_agent_id" => to_string(Map.get(ctx, :agent_id) || ""),
      "source_session_id" => to_string(Map.get(ctx, :session_id) || ""),
      "tool_call_id" => to_string(Map.get(ctx, :tool_call_id) || ""),
      "request_type" => "ifc_declassify",
      "request_payload" => %{
        "ifc_declassify" => %{
          "capability" => "ifc_declassify",
          "requester" => Codec.encode_principal!(activation.requester),
          "source_atoms" => sources,
          "destination_atoms" => destination,
          "source_names" => names(reply, sources),
          "destination_names" => names(reply, destination),
          "summary" => summary,
          # The card is composed by the runtime, so it says which language to
          # compose it in rather than inheriting the model's (§6.4).
          "language" => Atom.to_string(SalixAgent.IFC.language(reply))
        }
      },
      "expires_at" => System.system_time(:second) + @request_ttl_seconds
    })
  end

  defp pending(request, args, summary, ctx) do
    session_id = to_string(Map.get(ctx, :session_id) || "")
    tool_call_id = to_string(Map.get(ctx, :tool_call_id) || "")

    content =
      Jason.encode!(%{
        "status" => "awaiting_confirmation",
        "request_id" => request["request_id"],
        "tool_call_id" => tool_call_id,
        "summary" => summary,
        "message" =>
          "the requester must confirm this transfer; when they do, retry the original call unchanged"
      })

    wait =
      Waits.build(
        "declassification confirmation",
        @wait,
        "auto_wait",
        %{"tool_call_id" => tool_call_id, "tool_name" => @tool}
      )

    {content,
     [
       %{
         "type" => "async_tool_call_started",
         "session_id" => session_id,
         "tool_call_id" => tool_call_id,
         "tool_name" => @tool,
         "input" => Jason.encode!(args),
         "status" => "running",
         "completion_mode" => "external_callback",
         "started_at" => System.system_time(:millisecond),
         "auto_wait_seconds" => @wait
       }
       |> Map.merge(CapabilityRequestStore.execution_fields(request)),
       Waits.event(session_id, wait)
     ]}
  end

  defp names(reply, atoms) do
    display = Map.get(reply, "display_names", %{})

    atoms
    |> Enum.flat_map(fn atom ->
      case Map.get(display, atom) do
        name when is_binary(name) and name != "" -> [name]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  defp strings(values) when is_list(values),
    do: values |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  defp strings(_values), do: []

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
