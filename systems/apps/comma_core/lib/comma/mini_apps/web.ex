defmodule Comma.MiniApps.Web do
  @moduledoc """
  Web search for registered Mini App viewers with the `web.search` grant.
  Reuses the agent's Exa adapter. The provider credential stays on the server.
  Each call returns at most five results and makes one request with a 15-second receive timeout.
  """

  alias Comma.MiniApps
  alias SalixAgent.Tools.Web

  def search(rt, query) do
    with :ok <- access(rt),
         :ok <- validate_query(query),
         :ok <- MiniApps.owner_available(rt.app, "web_search") do
      case Web.search(query, receive_timeout: 15_000, retry: false, redirect: false) do
        {:ok, results} -> {:ok, results}
        {:error, :invalid} -> {:error, :invalid}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  end

  defp validate_query(query) when is_binary(query) do
    if String.trim(query) != "" and String.length(query) <= 2000,
      do: :ok,
      else: {:error, :invalid}
  end

  defp validate_query(_query), do: {:error, :invalid}

  defp access(%{guest: true}), do: {:error, :signup_required}

  defp access(rt) do
    grants =
      case rt do
        %{kind: :owner, app: app} -> app.grants
        %{kind: :install, install: install} -> install.grants
        # Link grants live in the client core, as for `ai.chat`.
        %{kind: :link} -> ["web.search"]
      end

    if "web.search" in (rt.version.manifest["capabilities"] || []) and
         "web.search" in grants,
       do: :ok,
       else: {:error, :not_granted}
  end
end
