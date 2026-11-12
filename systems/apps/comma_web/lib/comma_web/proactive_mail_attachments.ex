defmodule CommaWeb.ProactiveMailAttachments do
  @moduledoc """
  Which mail attachments the full mail read reads, and how each one is kept.
  A mail that says "details in the attached file" carries its evidence there,
  so small text files (logs, JSON reports) are read; others keep only their
  name, type and size.
  """

  # Attachments read per message, their raw size, and the text kept of each.
  @max_read 3
  @max_bytes 64_000
  @max_text_bytes 4_000
  @text_types ~w(application/json application/xml application/x-ndjson application/yaml)
  @text_extensions ~w(.json .txt .log .csv .xml .md .yaml .yml .ndjson)

  @doc """
  The attachment entries of `files` (`{name, content_type, size, ref}`), with
  the text of at most #{@max_read} readable ones. `read.(ref)` returns the
  raw bytes or `nil`.
  """
  def read(files, read) do
    files
    |> Enum.take(10)
    |> Enum.map_reduce(@max_read, fn {name, type, size, ref}, left ->
      text = if left > 0 and readable?(name, type, size), do: text(read.(ref))
      {entry(name, type, size, text), if(text, do: left - 1, else: left)}
    end)
    |> elem(0)
  end

  defp readable?(name, type, size) do
    type = String.downcase(type || "")

    is_integer(size) and size <= @max_bytes and
      (String.starts_with?(type, "text/") or type in @text_types or
         Path.extname(String.downcase(name || "")) in @text_extensions)
  end

  defp text(raw) when is_binary(raw) do
    if String.valid?(raw) and String.trim(raw) != "", do: String.trim(raw)
  end

  defp text(_raw), do: nil

  defp entry(name, type, size, text) do
    base = %{"name" => name || "", "content_type" => type || "", "size" => size}

    if text do
      kept = prefix(text, @max_text_bytes)
      Map.merge(base, %{"text" => kept, "truncated" => kept != text})
    else
      base
    end
  end

  defp prefix(text, bytes) when byte_size(text) <= bytes, do: text

  defp prefix(text, bytes) do
    value = binary_part(text, 0, max(bytes, 0))
    if String.valid?(value), do: value, else: prefix(value, byte_size(value) - 1)
  end
end
