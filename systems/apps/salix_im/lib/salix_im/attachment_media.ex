defmodule SalixIM.AttachmentMedia do
  @moduledoc false

  @image_extensions %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  @doc "Resolve a trusted provider attachment as a native image without overriding explicit MIME."
  @spec native_image_mime(term(), term()) :: {:ok, String.t()} | :error
  def native_image_mime(mime, filename) do
    declared =
      mime
      |> to_string()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> String.downcase()

    inferred =
      filename
      |> to_string()
      |> Path.extname()
      |> String.downcase()
      |> then(&@image_extensions[&1])

    cond do
      String.starts_with?(declared, "image/") -> {:ok, declared}
      declared in ["", "application/octet-stream"] and is_binary(inferred) -> {:ok, inferred}
      true -> :error
    end
  end
end
