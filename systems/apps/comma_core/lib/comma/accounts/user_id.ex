defmodule Comma.Accounts.UserId do
  @moduledoc false

  @new_pattern ~r/^usr_[A-Za-z0-9_-]+$/
  @legacy_dash_pattern ~r/^usr-[A-Za-z0-9_-]+$/
  @legacy_uuid_pattern ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

  @spec new_pattern() :: Regex.t()
  def new_pattern, do: @new_pattern

  @spec persisted_valid?(term()) :: boolean()
  def persisted_valid?(value) when is_binary(value) do
    Regex.match?(@new_pattern, value) or
      Regex.match?(@legacy_dash_pattern, value) or
      Regex.match?(@legacy_uuid_pattern, value)
  end

  def persisted_valid?(_value), do: false
end
