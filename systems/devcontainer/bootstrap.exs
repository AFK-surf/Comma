defmodule CommaDevContainer.Bootstrap do
  @moduledoc false
  def run do
    assert_local_dev!()
    Comma.FreshInstall.run()
  end

  defp assert_local_dev! do
    unless Mix.env() == :dev and System.get_env("COMMA_ENVIRONMENT") == "local" do
      raise "Comma dev-container bootstrap is restricted to MIX_ENV=dev and COMMA_ENVIRONMENT=local"
    end

    Application.load(:comma_core)
    database_url = Application.fetch_env!(:comma_core, Comma.Repo) |> Keyword.fetch!(:url)
    uri = URI.parse(database_url)

    unless uri.host in ["postgres", "127.0.0.1", "localhost"] and
             uri.path == "/billing_core_dev" do
      raise "Comma dev-container bootstrap refuses non-local database #{uri.host}#{uri.path}"
    end
  end
end

CommaDevContainer.Bootstrap.run()
