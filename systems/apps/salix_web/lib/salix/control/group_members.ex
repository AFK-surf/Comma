defmodule Salix.Control.GroupMembers do
  @moduledoc """
  Group membership control-plane API.
  """

  def list(_group_id), do: {:error, :not_implemented}
end
