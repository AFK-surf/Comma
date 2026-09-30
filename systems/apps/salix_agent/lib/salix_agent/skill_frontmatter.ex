defmodule SalixAgent.SkillFrontmatter do
  @moduledoc """
  Parses the small SKILL.md frontmatter subset used for catalog metadata.

  This intentionally accepts only top-level scalar fields plus simple block
  values for name, description, and summary.
  """

  @doc "Parse the small SKILL.md frontmatter subset Salix needs for catalog metadata."
  @spec parse(binary()) :: map()
  def parse(content) when is_binary(content) do
    with {:ok, lines} <- frontmatter_lines(content) do
      parse_lines(lines, %{})
    else
      _ -> %{}
    end
  end

  def parse(_content), do: %{}

  @doc "Validate activation and return catalog metadata for SKILL.md."
  def metadata(content, defaults \\ %{}) do
    fields = Map.merge(defaults, parse(content))
    activation = fields["activation"] || "regular"
    body = body(content)

    cond do
      activation not in ["regular", "per-message"] ->
        {:error, "activation must be regular or per-message"}

      activation == "per-message" and
          Enum.any?(["name", "description"], &(String.trim(fields[&1] || "") == "")) ->
        {:error, "miniskills require a name and description"}

      activation == "per-message" and byte_size(body) > 2048 ->
        {:error, "miniskill instructions exceed 2 KiB"}

      true ->
        {:ok,
         fields
         |> Map.put("activation", activation)
         |> Map.put("instruction_bytes", byte_size(body))}
    end
  end

  def body(content) do
    case Regex.run(~r/\A---\r?\n.*?\r?\n---(?:\r?\n|\z)(.*)\z/s, content) do
      [_, body] -> body
      _ -> content
    end
  end

  defp frontmatter_lines(content) do
    # Byte-mode \R also matches 0x85, a continuation byte in UTF-8 text such as 腿.
    lines = String.split(content, ~r/\r\n|\n|\r/, trim: false)

    case lines do
      ["---" | rest] -> {:ok, Enum.take_while(rest, &(&1 != "---"))}
      _ -> {:error, :missing_frontmatter}
    end
  end

  defp parse_lines([], acc), do: acc

  defp parse_lines([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        parse_lines(rest, acc)

      String.starts_with?(line, " ") ->
        parse_lines(rest, acc)

      true ->
        case String.split(line, ":", parts: 2) do
          [key, raw_value] ->
            key = key |> String.trim() |> String.downcase()
            value = String.trim(raw_value)

            cond do
              value in ["|", "|-", "|+", ">", ">-", ">+"] ->
                {block, rest} = take_indented(rest)
                joiner = if String.starts_with?(value, "|"), do: "\n", else: " "
                parse_lines(rest, maybe_put(acc, key, Enum.join(block, joiner)))

              value == "" ->
                {_nested, rest} = take_indented(rest)
                parse_lines(rest, if(key == "activation", do: Map.put(acc, key, ""), else: acc))

              true ->
                parse_lines(rest, maybe_put(acc, key, scalar(value)))
            end

          _ ->
            parse_lines(rest, acc)
        end
    end
  end

  defp take_indented(lines) do
    {block, rest} =
      Enum.split_while(lines, fn line ->
        String.trim(line) == "" or String.starts_with?(line, " ")
      end)

    {block |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")), rest}
  end

  defp maybe_put(acc, key, value)
       when key in ["name", "description", "summary", "activation"] and value != "",
       do: Map.put(acc, key, value)

  defp maybe_put(acc, _key, _value), do: acc

  defp scalar(value) do
    value = String.trim(value)

    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
          String.length(value) >= 2 ->
        String.slice(value, 1..-2//1)

      String.starts_with?(value, "'") and String.ends_with?(value, "'") and
          String.length(value) >= 2 ->
        String.slice(value, 1..-2//1)

      true ->
        value
    end
  end
end
