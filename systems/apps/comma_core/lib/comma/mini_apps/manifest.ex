defmodule Comma.MiniApps.Manifest do
  @moduledoc """
  The app manifest `comma-app.json` (design §6.1). `validate/1` returns the
  normalized manifest or every problem it finds, as text the coding agent
  reads.
  """

  @capabilities ~w(identity.basic ai.chat web.search chat.draft tasks.create files.pick drive.app_folder calendar.read notifications clipboard.write links.open)
  @storage ~w(app user device)
  @keys ~w(name description icon cover capabilities storage backend)
  @backend_keys ~w(entry egress secrets)
  @icon_types %{".png" => "image/png", ".svg" => "image/svg+xml", ".webp" => "image/webp"}
  @cover_types %{
    ".webp" => "image/webp",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png"
  }
  @secret_name ~r/\A[A-Z][A-Z0-9_]{0,63}\z/
  @host ~r/\A(?=.{1,253}\z)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
  @comma_hosts ~w(comma.surf comma.app)
  @max_list 20

  def capabilities, do: @capabilities

  @doc "Decodes and validates manifest JSON."
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = manifest} -> validate(manifest)
      {:ok, _other} -> {:error, ["comma-app.json must be a JSON object"]}
      {:error, _} -> {:error, ["comma-app.json is not valid JSON"]}
    end
  end

  def parse(_json), do: {:error, ["comma-app.json is missing"]}

  @doc "Validates a decoded manifest."
  def validate(%{} = manifest) do
    {normalized, errors} =
      {%{}, []}
      |> check_unknown(manifest, @keys, "")
      |> field(manifest, "name", &name/1)
      |> field(manifest, "description", &description/1)
      |> field(manifest, "icon", &icon/1)
      |> field(manifest, "cover", &cover/1)
      |> field(manifest, "capabilities", &subset(&1, @capabilities, "capabilities"))
      |> field(manifest, "storage", &subset(&1, @storage, "storage"))
      |> field(manifest, "backend", &backend/1)

    if errors == [], do: {:ok, normalized}, else: {:error, Enum.reverse(errors)}
  end

  @doc "The MIME type of an icon path, by extension."
  def icon_type(path) when is_binary(path),
    do: Map.get(@icon_types, path |> Path.extname() |> String.downcase())

  def icon_type(_path), do: nil

  @doc "The MIME type of a cover path, by extension."
  def cover_type(path) when is_binary(path),
    do: Map.get(@cover_types, path |> Path.extname() |> String.downcase())

  def cover_type(_path), do: nil

  defp check_unknown({normalized, errors}, map, allowed, prefix) do
    unknown = map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort()

    errors =
      Enum.reduce(unknown, errors, fn key, acc -> ["unknown field #{prefix}#{key}" | acc] end)

    {normalized, errors}
  end

  defp field({normalized, errors}, manifest, key, fun) do
    case fun.(Map.get(manifest, key)) do
      :skip -> {normalized, errors}
      {:ok, value} -> {Map.put(normalized, key, value), errors}
      {:error, messages} when is_list(messages) -> {normalized, Enum.reverse(messages, errors)}
      {:error, message} -> {normalized, [message | errors]}
    end
  end

  defp name(name) when is_binary(name) do
    name = String.trim(name)
    length = String.length(name)

    if length in 1..60, do: {:ok, name}, else: {:error, "name must be 1 to 60 characters"}
  end

  defp name(_name), do: {:error, "name is required (1 to 60 characters)"}

  defp description(nil), do: :skip

  defp description(text) when is_binary(text) do
    if String.length(text) <= 500,
      do: {:ok, text},
      else: {:error, "description must be at most 500 characters"}
  end

  defp description(_text), do: {:error, "description must be a string"}

  defp icon(nil), do: :skip

  defp icon(path) when is_binary(path) do
    cond do
      not safe_path?(path) -> {:error, "icon must be a relative path inside the bundle"}
      icon_type(path) == nil -> {:error, "icon must be a .png, .svg or .webp file"}
      true -> {:ok, path}
    end
  end

  defp icon(_path), do: {:error, "icon must be a path"}

  defp cover(nil), do: :skip

  defp cover(path) when is_binary(path) do
    cond do
      not safe_path?(path) -> {:error, "cover must be a relative path inside the bundle"}
      cover_type(path) == nil -> {:error, "cover must be a .webp, .jpg, .jpeg or .png file"}
      true -> {:ok, path}
    end
  end

  defp cover(_path), do: {:error, "cover must be a path"}

  defp subset(nil, _allowed, _label), do: {:ok, []}

  defp subset(values, allowed, label) when is_list(values) do
    case Enum.reject(values, &(is_binary(&1) and &1 in allowed)) do
      [] -> {:ok, Enum.uniq(values)}
      bad -> {:error, "#{label} has unknown entries: #{Enum.map_join(bad, ", ", &inspect/1)}"}
    end
  end

  defp subset(_values, _allowed, label), do: {:error, "#{label} must be a list"}

  defp backend(nil), do: :skip

  defp backend(%{} = backend) do
    {normalized, errors} =
      {%{}, []}
      |> check_unknown(backend, @backend_keys, "backend.")
      |> field(backend, "entry", &entry/1)
      |> field(backend, "egress", &egress/1)
      |> field(backend, "secrets", &secret_names/1)

    if errors == [], do: {:ok, normalized}, else: {:error, Enum.reverse(errors)}
  end

  defp backend(_backend), do: {:error, "backend must be an object"}

  defp entry(entry) when is_binary(entry) do
    if safe_path?(entry),
      do: {:ok, entry},
      else: {:error, "backend.entry must be a relative path"}
  end

  defp entry(_entry), do: {:error, "backend.entry is required"}

  defp egress(nil), do: {:ok, []}

  defp egress(hosts) when is_list(hosts) and length(hosts) <= @max_list do
    bad =
      Enum.reject(hosts, fn host ->
        is_binary(host) and Regex.match?(@host, host) and not comma_host?(host)
      end)

    if bad == [],
      do: {:ok, Enum.uniq(hosts)},
      else:
        {:error,
         "backend.egress must list host names (no IP addresses, wildcards or Comma hosts): " <>
           Enum.map_join(bad, ", ", &inspect/1)}
  end

  defp egress(hosts) when is_list(hosts),
    do: {:error, "backend.egress lists at most #{@max_list} hosts"}

  defp egress(_hosts), do: {:error, "backend.egress must be a list"}

  defp secret_names(nil), do: {:ok, []}

  defp secret_names(names) when is_list(names) and length(names) <= @max_list do
    bad = Enum.reject(names, &(is_binary(&1) and Regex.match?(@secret_name, &1)))

    if bad == [],
      do: {:ok, Enum.uniq(names)},
      else:
        {:error,
         "backend.secrets names must match ^[A-Z][A-Z0-9_]{0,63}$: " <>
           Enum.map_join(bad, ", ", &inspect/1)}
  end

  defp secret_names(names) when is_list(names),
    do: {:error, "backend.secrets lists at most #{@max_list} names"}

  defp secret_names(_names), do: {:error, "backend.secrets must be a list"}

  defp comma_host?(host),
    do: Enum.any?(@comma_hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

  @doc false
  def safe_path?(path) when is_binary(path) do
    path != "" and byte_size(path) <= 512 and not String.starts_with?(path, "/") and
      not String.contains?(path, ["\\", "\0"]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  def safe_path?(_path), do: false
end
