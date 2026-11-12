defmodule Salix.Bindings.MeetingGlossary do
  @moduledoc """
  Spelling corrections a team keeps in its Router's `/memory/semantic/glossary.md`.

  One correction per list item, misheard forms on the left of `→` (or `->`),
  separated by `/`, the correct form on the right. A trailing parenthetical
  on the right is a note:

      - Acme Clowd / Akme Cloud → Acme Cloud
      - 张山 / 章三 → Zhang San（Slack display zs）
      - → Acme Cloud

  The correct forms, also of items without a misheard form, are the terms the
  recording ASR is asked to spell. Other lines, such as headings and prose, are ignored. A misheard form needs two or more characters, and a
  Latin one matches whole words only, so a short entry cannot rewrite
  unrelated text.
  """

  @path "/memory/semantic/glossary.md"
  @max_bytes 64_000
  @max_entries 500
  @entry ~r/\A\s*[-*]\s+(.*?)\s*(?:→|->)\s*(.+?)\s*\z/u
  @note ~r/\s*[（(][^（）()]*[）)]\s*\z/u

  def path, do: @path

  @doc "The corrections in an agent's glossary file, or none when it has none."
  @spec load(String.t()) :: [{String.t(), String.t()}]
  def load(agent_id) do
    case SalixAgent.AgentWorkspace.read(agent_id, @path) do
      {:ok, text} when is_binary(text) -> parse(text)
      _ -> []
    end
  end

  @doc "The Router of a meeting's group: the agent whose glossary applies."
  @spec router_agent(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def router_agent(group_id, tenant_id) do
    with {:ok, group} <- Salix.Control.Groups.get(group_id, tenant_id) do
      case group["router_agent_id"] do
        agent_id when is_binary(agent_id) and agent_id != "" -> {:ok, agent_id}
        _ -> {:error, :no_user_facing_agent}
      end
    end
  end

  @doc "The correct form of every item in an agent's glossary, each once."
  @spec load_terms(String.t()) :: [String.t()]
  def load_terms(agent_id) do
    case SalixAgent.AgentWorkspace.read(agent_id, @path) do
      {:ok, text} when is_binary(text) -> terms(text)
      _ -> []
    end
  end

  @spec terms(String.t()) :: [String.t()]
  def terms(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> bounded_lines(@max_bytes)
    |> Enum.flat_map(fn line ->
      case Regex.run(@entry, line) do
        [_, _left, right] -> [right |> String.replace(@note, "") |> String.trim()]
        _ -> []
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(@max_entries)
  end

  @spec parse(String.t()) :: [{String.t(), String.t()}]
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> bounded_lines(@max_bytes)
    |> Enum.flat_map(&entry/1)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.take(@max_entries)
    # Longer forms first, so a form inside another one does not split it.
    |> Enum.sort_by(fn {wrong, _right} -> -String.length(wrong) end)
  end

  def parse(_text), do: []

  @spec apply_to(String.t(), [{String.t(), String.t()}]) :: String.t()
  def apply_to(text, corrections) when is_binary(text) do
    Enum.reduce(corrections, text, fn {wrong, right}, acc ->
      Regex.replace(pattern(wrong), acc, fn _ -> right end)
    end)
  end

  defp bounded_lines(lines, budget) do
    lines
    |> Enum.reduce_while({[], budget}, fn line, {kept, left} ->
      size = byte_size(line) + 1
      if size > left, do: {:halt, {kept, left}}, else: {:cont, {[line | kept], left - size}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp entry(line) do
    with [_, left, right] <- Regex.run(@entry, line),
         right = right |> String.replace(@note, "") |> String.trim(),
         true <- right != "" do
      left
      |> String.split("/")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) >= 2 and &1 != right))
      |> Enum.map(&{&1, right})
    else
      _ -> []
    end
  end

  defp pattern(wrong) do
    escaped = Regex.escape(wrong)

    if Regex.match?(~r/\A[\x00-\x7F]+\z/, wrong),
      do: Regex.compile!("(?<![A-Za-z0-9])#{escaped}(?![A-Za-z0-9])", "u"),
      else: Regex.compile!(escaped, "u")
  end
end
