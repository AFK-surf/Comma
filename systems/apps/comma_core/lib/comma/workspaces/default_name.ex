defmodule Comma.Workspaces.DefaultName do
  @moduledoc false

  # Keep account bootstrap available when an email is missing or blank.
  def for_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> "Default workspace"
      name -> name
    end
  end

  def for_email(nil), do: "Default workspace"
end
