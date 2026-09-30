defmodule SalixWeb.Dashboard.MessageContent do
  @moduledoc """
  Helpers for rendering Salix message `content`, which may be a plain string or
  a list of content blocks (`%{"type" => "text"|"image_url"|"file", ...}`),
  mirroring willow's message rendering.
  """

  @doc "A one-line plain-text preview of a message's content (for tables)."
  def preview(content, max \\ 120) do
    content
    |> text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(max)
  end

  @doc "Concatenated plain text of all text blocks (or the string itself)."
  def text(content) when is_binary(content), do: content

  def text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def text(%{} = block), do: block_text(block)
  def text(_), do: ""

  @doc "Normalize content into a list of blocks for rich rendering."
  def blocks(content) when is_list(content), do: content
  def blocks(content) when is_binary(content), do: [%{"type" => "text", "text" => content}]
  def blocks(%{} = block), do: [block]
  def blocks(_), do: []

  defp block_text(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp block_text(%{"text" => t}) when is_binary(t), do: t
  defp block_text(%{"type" => "image_url"}), do: "[image]"
  defp block_text(%{"type" => "file", "file_name" => name}), do: "[file: #{name}]"
  defp block_text(%{"type" => type}), do: "[#{type}]"
  defp block_text(b) when is_binary(b), do: b
  defp block_text(_), do: ""

  defp truncate(s, max) when byte_size(s) > max do
    head = s |> binary_part(0, max) |> valid_utf8_prefix()
    head <> "…"
  end

  defp truncate(s, _max), do: s

  # `binary_part/3` cuts on a byte boundary, which splits multi-byte characters
  # (any CJK preview is a candidate). The resulting invalid UTF-8 survives the
  # dead render but crashes the LiveView socket's JSON encoder on every diff,
  # leaving the page in a reconnect loop — so drop the partial trailing
  # character instead.
  defp valid_utf8_prefix(binary) do
    case :unicode.characters_to_binary(binary) do
      valid when is_binary(valid) -> valid
      {:error, valid, _rest} -> valid
      {:incomplete, valid, _rest} -> valid
    end
  end
end
