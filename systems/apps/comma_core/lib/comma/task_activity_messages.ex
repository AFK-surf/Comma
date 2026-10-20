defmodule Comma.TaskActivityMessages do
  @moduledoc """
  A transcript page cut down to what a Task's Activity reads, for a client
  that reads the Activity's history before the transcript it holds.

  The Activity groups milestones under the requests before them and opens the
  Agent's next shown Message from each. So a Message keeps its identity,
  sequence, time, sender, metadata and delivery facts, its milestone blocks,
  and the provider of a delivery's origin (a Loop's wake names `loop`). Only a request's words are read: a person's Message keeps its text,
  as does an Agent's Message that hands the Task a request (`task_request`).
  Any other Message keeps one empty text block in place of what it showed, so
  a client still knows a transcript shows it.
  """

  @text_limit 500

  @spec slim(map()) :: map()
  def slim(message) when is_map(message) do
    keep_text? = message["actor_type"] != "agent" or task_request?(message)

    message
    |> Map.update("content", [], &slim_content(&1, keep_text?))
    |> update_present("platform_message", fn platform ->
      Map.update(platform, "content", [], &slim_content(&1, platform["role"] == "user"))
    end)
    # It marks a delivery no transcript shows; its origin names a Loop's wake.
    |> update_present("agent_input", &slim_input/1)
  end

  defp slim_input(input) do
    case input["trusted_origin"] || input[:trusted_origin] do
      %{} = origin ->
        %{"trusted_origin" => %{"provider" => origin["provider"] || origin[:provider]}}

      _none ->
        %{}
    end
  end

  defp task_request?(message), do: get_in(message, ["metadata", "task_request"]) == true

  defp slim_content(content, keep_text?) when is_list(content) do
    {milestones, rest} = Enum.split_with(content, &match?(%{"type" => "milestone"}, &1))

    shown =
      if keep_text?,
        do: Enum.flat_map(rest, &text_block/1),
        else: []

    milestones ++
      cond do
        shown != [] -> shown
        rest != [] -> [%{"type" => "text", "text" => ""}]
        true -> []
      end
  end

  defp slim_content(content, keep_text?) when is_binary(content),
    do: slim_content([%{"type" => "text", "text" => content}], keep_text?)

  defp slim_content(_content, _keep_text?), do: []

  defp text_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [%{"type" => "text", "text" => String.slice(text, 0, @text_limit)}]

  defp text_block(_block), do: []

  defp update_present(map, key, fun) do
    case map do
      %{^key => value} when is_map(value) -> Map.put(map, key, fun.(value))
      _ -> map
    end
  end
end
