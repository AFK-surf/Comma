defmodule SystemsRuntime.FS do
  @moduledoc "Files: each function is the `File` function of the same name."

  @doc "As `File.read/1`."
  def read(path), do: File.read(IO.chardata_to_string(path))

  @doc "As `File.read!/1`."
  def read!(path) do
    case read(path) do
      {:ok, content} -> content
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc "As `File.write/2`."
  def write(path, content),
    do: File.write(IO.chardata_to_string(path), IO.iodata_to_binary(content))

  @doc "As `File.write!/2`."
  def write!(path, content) do
    case write(path, content) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write to file", path: path
    end
  end

  @doc "As `File.rm/1`."
  def rm(path), do: File.rm(IO.chardata_to_string(path))

  @doc "As `File.exists?/1`."
  def exists?(path), do: File.exists?(IO.chardata_to_string(path))
end
