defmodule SalixIM.ConversationMilestone do
  @moduledoc """
  Pure contract for an Agent's Task milestones.

  A milestone is a Message content value, not a separate entity. When an Agent
  finishes a key step of its Task, it records one `milestone` block with a
  short title, such as "Wrote the invite for Bob". Milestones only append: a
  Task's Activity is its milestones in order, each at the time its Message was
  written. A Message may carry several, for steps finished together.

  Every append normalizes the titles and puts the blocks first. A Message
  that carries only milestones is recorded without notifying any Participant
  unless its sender chose a delivery filter: it is for people, not a request
  for the Router. Transcripts do not show milestones, and such a Message has
  no text for any reader.
  """

  @max_milestones 20
  @title_length 1..80

  @doc """
  Shape checks for stored and incoming content. They run on reads too, so they
  only cover what a normalized block always satisfies.
  """
  @spec validate_blocks(list()) :: :ok | {:error, term()}
  def validate_blocks(content) when is_list(content) do
    case Enum.filter(content, &milestone?/1) do
      [] -> :ok
      milestones -> validate_milestones(milestones)
    end
  end

  def validate_blocks(_content), do: :ok

  @doc """
  Append-time rules, before the content is validated: only an Agent records
  milestones; each title is kept on one line and the blocks go first, in
  their order; a Message with only milestones gets an empty delivery filter
  unless its sender gave one. Content without a milestone is returned as it is.
  """
  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{"content" => content} = attrs) when is_list(content) do
    {milestones, rest} = Enum.split_with(content, &milestone?/1)

    cond do
      milestones == [] ->
        {:ok, attrs}

      attrs["actor_type"] != "agent" ->
        bad("Only an Agent can record a milestone")

      true ->
        milestones =
          Enum.map(milestones, &%{"type" => "milestone", "title" => one_line(&1["title"])})

        attrs = Map.put(attrs, "content", milestones ++ rest)

        if rest == [] and not Map.has_key?(attrs, "delivery_filter") and
             not Map.has_key?(attrs, :delivery_filter),
           do: {:ok, Map.put(attrs, "delivery_filter", %{"participant_ids" => []})},
           else: {:ok, attrs}
    end
  end

  def prepare(attrs), do: {:ok, attrs}

  defp milestone?(block), do: match?(%{"type" => "milestone"}, block)

  defp validate_milestones(milestones) when length(milestones) <= @max_milestones do
    if Enum.all?(milestones, &valid_title?(&1["title"])),
      do: :ok,
      else: bad("Each milestone title must be one line of 1 to 80 characters")
  end

  defp validate_milestones(_milestones),
    do: bad("A Message carries at most #{@max_milestones} milestones")

  defp valid_title?(title) when is_binary(title),
    do: String.length(String.trim(title)) in @title_length and not String.contains?(title, "\n")

  defp valid_title?(_title), do: false

  defp one_line(title) when is_binary(title), do: title |> String.split() |> Enum.join(" ")
  defp one_line(title), do: title

  defp bad(message), do: {:error, {:bad_request, message}}
end
