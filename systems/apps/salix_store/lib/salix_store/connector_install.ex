defmodule SalixStore.ConnectorInstall do
  @moduledoc "Platform and artifact selection for Comma and Runner installation scripts."

  @platforms [
    {"darwin-arm64", "Darwin/arm64"},
    {"darwin-amd64", "Darwin/x86_64"},
    {"linux-arm64", "Linux/aarch64|Linux/arm64"},
    {"linux-amd64", "Linux/x86_64|Linux/amd64"}
  ]

  def platforms, do: Enum.map(@platforms, &elem(&1, 0))

  @doc "Select published artifact values for this host. Callers retain their installation policy."
  def artifact_exports(targets) when is_map(targets) do
    cases =
      Enum.flat_map(@platforms, fn {platform, pattern} ->
        case Map.fetch(targets, platform) do
          {:ok, values} ->
            exports =
              values
              |> Enum.sort()
              |> Enum.map_join("\n", fn {key, value} ->
                "    export #{key}=#{shell_quote(to_string(value))}"
              end)

            ["  #{pattern})\n#{exports}\n    ;;"]

          :error ->
            []
        end
      end)

    Enum.join(
      ["case \"$(uname -s)/$(uname -m)\" in"] ++
        cases ++ ["  *) echo 'Unsupported installation platform' >&2; exit 1 ;;", "esac"],
      "\n"
    )
  end

  def shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
