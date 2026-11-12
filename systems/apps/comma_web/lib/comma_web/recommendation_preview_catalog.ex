defmodule CommaWeb.RecommendationPreviewCatalog do
  @moduledoc """
  Provider capability registry for requester-bound managed OAuth previews.
  Discovery, identity resolution and dispatch share this fail-closed set.
  Each provider must implement exact-target reads in RecommendationOAuthSource.
  Feishu and Lark are member Routine sources without previews: a member's
  own sign-in with the bot app their scan made (`CommaWeb.PluginConnections`).
  """
  @managed_toolkits ~w(github linear notion slack)
  @member_only_toolkits ~w(feishu lark)
  def managed_toolkits, do: @managed_toolkits
  def managed?(toolkit), do: toolkit in @managed_toolkits

  @doc "Managed OAuth providers a member's Routine reads, previews or not."
  def member_toolkits, do: @managed_toolkits ++ @member_only_toolkits
  def member_toolkit?(toolkit), do: toolkit in member_toolkits()
  def member_only?(toolkit), do: toolkit in @member_only_toolkits

  @doc """
  The alias of the Group binding a member source reads. A Feishu or Lark
  member sign-in has its own, so a credential an Agent asked for under the
  provider's name never replaces it, nor it that credential.
  """
  def binding_alias(toolkit) when toolkit in @member_only_toolkits, do: toolkit <> "-member"
  def binding_alias(toolkit), do: toolkit
end
