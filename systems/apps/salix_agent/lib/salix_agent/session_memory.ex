defmodule SalixAgent.SessionMemory do
  @moduledoc """
  Local resource input for session residency, not an observability dependency.
  Container charge is the safety boundary; reclaimable file cache is reported
  separately and is not treated as actor memory. Non-container runtimes use an
  configured BEAM budget, or 4 GiB by default. Invalid explicit budgets
  are distinct from a healthy sample.
  """

  def sample do
    root = Application.get_env(:salix_agent, :session_cgroup_path, "/sys/fs/cgroup")

    with {:ok, used} <- integer_file(Path.join(root, "memory.current")),
         {:ok, limit} <- integer_file(Path.join(root, "memory.max")),
         true <- limit > 0 do
      {:ok, %{used: used, limit: limit, reclaimable: inactive_file(root)}}
    else
      _ -> beam_budget()
    end
  end

  defp inactive_file(root) do
    case File.read(Path.join(root, "memory.stat")) do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.find_value(0, fn line ->
          case String.split(line) do
            ["inactive_file", value] ->
              case Integer.parse(value) do
                {n, ""} when n >= 0 -> n
                _ -> 0
              end

            _ ->
              nil
          end
        end)

      _ ->
        0
    end
  end

  defp beam_budget do
    case Application.get_env(:salix_agent, :session_memory_budget_bytes, 4 * 1024 * 1024 * 1024) do
      n when is_integer(n) and n > 0 -> {:ok, %{used: :erlang.memory(:total), limit: n}}
      _ -> {:error, :invalid_memory_budget}
    end
  end

  defp integer_file(path) do
    with {:ok, text} <- File.read(path),
         {value, ""} when value >= 0 <- Integer.parse(String.trim(text)) do
      {:ok, value}
    else
      _ -> {:error, :unavailable}
    end
  end
end
