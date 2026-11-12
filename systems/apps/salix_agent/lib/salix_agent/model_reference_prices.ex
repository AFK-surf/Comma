defmodule SalixAgent.ModelReferencePrices do
  @moduledoc "Catalog reference prices for estimates, separate from billing and subscription charges."
  alias SalixAgent.Models
  alias SalixAgent.TaskRouting.Learner

  @prices Map.new(Models.list(), fn model ->
            price = model["price"]
            {model["id"], if(price, do: Map.put(price, "tiers", model["price_tiers"] || []))}
          end)
  @aliases Models.list()
           |> Enum.flat_map(fn model ->
             for route <- Map.values(model["routes"]), do: {route["model"], model["id"]}
           end)
           |> Map.new()

  def source, do: Models.generated_from()

  def estimate(model, usage) do
    price = @prices[model] || @prices[@aliases[model]]
    if price, do: estimate_price(price, usage)
  end

  @doc """
  Whether a call's token counters were observed. Only the Responses parser sets
  the flags. A NULL flag comes from the other parsers and from historical rows,
  and nonzero counters are then the only evidence: they default to 0 when absent.
  """
  def usage_reported?(usage) do
    case usage["usage_reported"] do
      true ->
        usage["prompt_tokens_reported"] != false and
          usage["completion_tokens_reported"] != false

      false ->
        false

      nil ->
        (usage["prompt_tokens"] || 0) + (usage["completion_tokens"] || 0) > 0
    end
  end

  @doc false
  def estimate_price(price, usage) do
    input = usage["prompt_tokens"] || 0
    output = usage["completion_tokens"] || 0
    read = usage["cache_read_input_tokens"] || 0
    write = usage["cache_write_input_tokens"] || 0

    rates =
      (price["tiers"] || [])
      |> Enum.filter(
        &(get_in(&1, ["tier", "type"]) == "context" and input > get_in(&1, ["tier", "size"]))
      )
      |> Enum.sort_by(&get_in(&1, ["tier", "size"]))
      |> Enum.reduce(price, &Map.merge(&2, &1))

    components = [
      {input - read - write, "input"},
      {output, "output"},
      {read, "cache_read"},
      {write, "cache_write"}
    ]

    # Without the cached counter, cached tokens would be charged the full input rate.
    if usage_reported?(usage) and usage["cache_read_tokens_reported"] != false and
         Enum.all?(components, fn {tokens, key} ->
           tokens >= 0 and (tokens == 0 or is_number(rates[key]))
         end) do
      Learner.cost(
        %{
          "input_tokens" => input,
          "output_tokens" => output,
          "cache_read_input_tokens" => read,
          "cache_write_input_tokens" => write
        },
        Map.new(components, fn {_tokens, key} -> {key, rates[key] || 0} end)
      )
    end
  end
end
