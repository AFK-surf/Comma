defmodule SalixIM.Triage.FileAttachments do
  @moduledoc """
  A bounded catalogue of files observed on one Slack source message.

  Names are source metadata, not body evidence. Provider ids, URLs, previews
  and credentials are never selected. The existing 1 MiB thread-read budget
  bounds raw metadata; at most ten entries and 512 UTF-8 bytes per projected
  name reach the model. Its ordinary source-message read resolves the files.
  """

  @item_limit 10
  @name_bytes 512
  @kinds ~w(text image audio video pdf file)

  def from_slack(files) when is_list(files) do
    %{
      "total_count" => length(files),
      "truncated" => length(files) > @item_limit,
      "items" => files |> Enum.take(@item_limit) |> Enum.map(&metadata/1)
    }
  end

  def from_slack(_), do: from_slack([])

  # Sanitize the complete name before shortening it: shortening a credential
  # first could prevent the existing text sanitizer from recognizing it.
  def project(catalogue, sanitize) do
    items =
      Enum.map(catalogue["items"], fn item ->
        name = sanitize.(item["name"])
        {Map.put(item, "name", bounded_name(name)), byte_size(name) > @name_bytes}
      end)

    %{
      "total_count" => catalogue["total_count"],
      "truncated" => catalogue["truncated"] or Enum.any?(items, &elem(&1, 1)),
      "items" => Enum.map(items, &elem(&1, 0))
    }
  end

  def valid?(catalogue, name_bytes \\ 1_048_576)

  def valid?(
        %{"items" => items, "total_count" => count, "truncated" => truncated} = value,
        name_bytes
      )
      when is_list(items) and is_integer(count) and is_boolean(truncated) do
    Enum.sort(Map.keys(value)) == ~w(items total_count truncated) and
      length(items) <= @item_limit and count >= length(items) and
      (count == length(items) or truncated) and
      Enum.all?(items, fn
        %{"name" => name, "kind" => kind} = item ->
          Enum.sort(Map.keys(item)) == ~w(kind name) and is_binary(name) and
            byte_size(name) <= name_bytes and kind in @kinds

        _ ->
          false
      end)
  end

  def valid?(_, _), do: false

  def valid_projected?(catalogue), do: valid?(catalogue, @name_bytes)

  defp metadata(file) when is_map(file) do
    name = Enum.find([file["name"], file["title"]], "", &(is_binary(&1) and &1 != ""))
    %{"name" => name, "kind" => kind(file["mimetype"])}
  end

  defp metadata(_), do: %{"name" => "", "kind" => "file"}

  defp kind("text/" <> _), do: "text"
  defp kind("image/" <> _), do: "image"
  defp kind("audio/" <> _), do: "audio"
  defp kind("video/" <> _), do: "video"
  defp kind("application/pdf"), do: "pdf"
  defp kind(_), do: "file"

  defp bounded_name(name) when byte_size(name) <= @name_bytes, do: name

  defp bounded_name(name) do
    case :unicode.characters_to_binary(binary_part(name, 0, @name_bytes)) do
      prefix when is_binary(prefix) -> prefix
      {:incomplete, prefix, _suffix} -> prefix
    end
  end
end
