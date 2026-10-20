defmodule CommaWeb.RecommendationPreviewCatalog do
  @moduledoc """
  Provider capability registry for requester-bound managed OAuth previews.
  Discovery, identity resolution and dispatch share this fail-closed set.
  Each provider must implement exact-target reads in RecommendationOAuthSource.
  """
  @managed_toolkits ~w(github linear notion slack)
  def managed_toolkits, do: @managed_toolkits
  def managed?(toolkit), do: toolkit in @managed_toolkits
end
