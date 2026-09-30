defmodule SalixMedia.OpenAICompat do
  @moduledoc """
  Shared OpenAI-compatible request shaping used by media and LLM clients.
  """

  @max_completion_token_prefixes ~w(gpt-5 o1 o3 o4)

  @doc """
  Put the correct chat-completions token cap parameter for `model`.

  Willow's `usesMaxCompletionTokens` rule applies after the last provider-route
  slash, so names like `openai/gpt-5-mini` use `max_completion_tokens`.
  """
  @spec put_chat_max_tokens(map(), term(), pos_integer() | nil) :: map()
  def put_chat_max_tokens(body, _model, nil), do: body

  def put_chat_max_tokens(body, model, max_tokens) do
    if uses_max_completion_tokens?(model) do
      Map.put(body, "max_completion_tokens", max_tokens)
    else
      Map.put(body, "max_tokens", max_tokens)
    end
  end

  @spec uses_max_completion_tokens?(term()) :: boolean()
  def uses_max_completion_tokens?(model) do
    short =
      model
      |> to_string()
      |> String.downcase()
      |> String.split("/")
      |> List.last()
      |> String.trim()

    Enum.any?(@max_completion_token_prefixes, &String.starts_with?(short, &1))
  end
end
