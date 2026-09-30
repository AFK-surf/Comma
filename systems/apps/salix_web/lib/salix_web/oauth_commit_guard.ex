defmodule SalixWeb.OAuthCommitGuard do
  @moduledoc false

  def run(%{"comma_operation" => nil}, write), do: write.()

  def run(%{"comma_operation" => %{} = _operation} = auth, write) do
    case Application.get_env(:salix_web, :comma_oauth_commit_mod) do
      module when is_atom(module) and not is_nil(module) -> module.run(auth, write)
      _ -> {:error, "authorization operation unavailable"}
    end
  end

  def run(%{"comma_operation" => _}, _write),
    do: {:error, "authorization operation unavailable"}

  def run(_auth, write), do: write.()
end
