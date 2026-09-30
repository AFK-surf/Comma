defmodule Comma.ObanBootstrap do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: Comma.Oban,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(opts) do
    if schema_ready?() do
      Oban.start_link(opts)
    else
      # Fresh-database release validation boots the umbrella before running the
      # migration that creates oban_jobs. Serving releases have already run the
      # exact migration plan, so they always take the branch above.
      :ignore
    end
  end

  defp schema_ready? do
    case Ecto.Adapters.SQL.query(
           Comma.Repo,
           "SELECT to_regclass('public.oban_jobs') IS NOT NULL",
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  rescue
    _error -> false
  end
end
