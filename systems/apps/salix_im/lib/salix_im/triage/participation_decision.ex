defmodule SalixIM.Triage.ParticipationDecision do
  @moduledoc """
  The native evaluator's contribution choice before it drafts a product decision.

  Communication and investigation have separate owners within the same evaluation.
  The short reason records source-based selection, not private model reasoning.
  """

  alias SalixIM.Triage.CanonicalJSON

  @keys ~w(communication investigate reason)

  def valid?(
        %{"communication" => kind, "investigate" => investigate, "reason" => reason} = value
      ),
      do:
        Enum.sort(Map.keys(value)) == Enum.sort(@keys) and
          kind in ~w(reply reaction silence) and is_boolean(investigate) and
          is_binary(reason) and String.trim(reason) != "" and String.length(reason) <= 1000

  def valid?(_value), do: false

  def validate_result(
        selection,
        %{"communication" => %{"kind" => kind}, "delegations" => delegations} = decision
      )
      when is_list(delegations) do
    if valid?(selection) and
         kind == selection["communication"] and
         length(delegations) in if(selection["investigate"], do: 1..2, else: 0..0) and
         (selection["communication"] == "reply" or is_nil(decision["companion_reaction"])) do
      :ok
    else
      {:error, :invalid_participation_decision}
    end
  end

  def validate_result(_selection, _decision), do: {:error, :invalid_participation_decision}

  def render_instruction(selection) do
    """
    The contribution phase has selected the communication kind and whether useful
    investigation exists from this same snapshot and completed read, if any.
    Render that choice using the six-field product decision contract. Context
    candidates remain independent. Do not add an acknowledgement to silence or
    drop selected investigation. No further tools are available. This selection
    adds no source evidence or action authority.
    """ <> CanonicalJSON.encode!(selection)
  end

  def response_format(route) do
    %{
      "type" => "json_schema",
      "name" => "comma_triage_participation_v1",
      "strict" => true,
      "schema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => @keys,
        "properties" => %{
          "communication" => %{
            "type" => "string",
            "enum" => if(route == "none", do: ~w(reply reaction silence), else: ["silence"])
          },
          "investigate" =>
            if(route == "none",
              do: %{"type" => "boolean"},
              else: %{"type" => "boolean", "enum" => [false]}
            ),
          "reason" => %{"type" => "string", "minLength" => 1, "maxLength" => 1000}
        }
      }
    }
  end

  def constrain_format(format, selection) do
    communication = get_in(format, ["schema", "properties", "communication"])

    chosen =
      Enum.find(communication["anyOf"] || [communication], fn variant ->
        get_in(variant, ["properties", "kind", "enum"]) == [selection["communication"]]
      end)

    if valid?(selection) and is_map(chosen) do
      format =
        format
        |> put_in(["schema", "properties", "communication"], chosen)
        |> put_in(
          ["schema", "properties", "delegations", "minItems"],
          if(selection["investigate"], do: 1, else: 0)
        )
        |> put_in(
          ["schema", "properties", "delegations", "maxItems"],
          if(selection["investigate"], do: 2, else: 0)
        )

      format =
        if selection["communication"] == "reply",
          do: format,
          else:
            put_in(format, ["schema", "properties", "companion_reaction"], %{"type" => "null"})

      {:ok, format}
    else
      {:error, :invalid_participation_decision}
    end
  end
end
