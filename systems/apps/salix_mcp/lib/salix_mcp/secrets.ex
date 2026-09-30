defmodule SalixMCP.Secrets do
  @moduledoc false

  @secret_name_parts ["token", "secret", "key", "authorization", "auth", "credential", "password"]

  def secret_name?(key) do
    key = String.downcase(to_string(key))

    Enum.any?(@secret_name_parts, fn part ->
      String.contains?(key, part)
    end)
  end
end
