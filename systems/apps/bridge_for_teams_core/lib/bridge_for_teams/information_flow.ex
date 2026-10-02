defmodule BridgeForTeams.InformationFlow do
  @moduledoc """
  Org-scoped product boundary over Salix's information-flow settings
  (`docs/verification.md` §3.6, §10).

  `SalixIM.IFC.Admin` owns what a setting *means*; this module owns the two
  things Salix cannot know: **which org a group belongs to**, and **who may
  change it**. Every call therefore starts from an org and a project, resolves
  the project's Salix group inside that org, and only then reaches the seam —
  so a forged group id in a form post cannot become a cross-organization write.

  ## The mode is the only dangerous control here

  Classifications, clearances and placement overrides describe a workspace;
  getting one wrong makes the bot refuse something it could have carried, which
  is visible and recoverable. `enforce` is different: it starts refusing
  effects, so it is written through the ordinary group control API
  (`Salix.Control.Groups`), validated there, and never inferred from anything
  on this side.

  ## Reads are not cached

  Unlike the Triage posture, these rows are small, read once per page, and
  edited on the same screen they are read from. A stale row here would be an
  operator looking at a classification they just changed, so the page pays one
  read instead.
  """

  alias BridgeForTeams.Schema.Organization
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.{Orgs, Projects}

  @type result :: {:ok, term()} | {:error, term()}

  @modes ~w(off audit enforce)
  @languages ~w(zh en)

  @doc "The languages the runtime's own sentences can be written in."
  @spec languages() :: [String.t()]
  def languages, do: @languages

  @doc """
  Every information-flow setting for one project, by connect.

  The project is resolved inside the org first, so the group id that reaches
  Salix is one this org owns.
  """
  @spec overview(Organization.t() | String.t(), String.t()) :: result()
  def overview(org, project_id) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id) do
      client().ifc_overview(tenant_id, group_id)
    end
  end

  @doc """
  Sets one Group's mode.

  `enforce` is the moment this design starts refusing effects, so the write
  goes through the group control API that validates it rather than through the
  settings seam.
  """
  @spec set_mode(Organization.t() | String.t(), String.t(), String.t()) :: result()
  def set_mode(org, project_id, mode) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         true <- mode in @modes do
      client().update_group(group_id, tenant_id, %{"ifc" => %{"mode" => mode}})
    else
      false -> {:error, :invalid_mode}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Sets the language the runtime writes its own sentences in.

  Rule A's refusal, rule B's provenance footer and the confirmation card are
  composed by the runtime rather than by the model, so they cannot follow the
  model's instruction to answer in the asker's language. This is the setting
  that says which one they use (§6.4).

  A settings write, not a mode write: the group control API merges it, so
  changing the language never disturbs the mode.
  """
  @spec set_language(Organization.t() | String.t(), String.t(), String.t()) :: result()
  def set_language(org, project_id, language) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         true <- language in @languages do
      client().update_group(group_id, tenant_id, %{"ifc" => %{"language" => language}})
    else
      false -> {:error, :invalid_language}
      {:error, _reason} = error -> error
    end
  end

  @doc "Classifies one conversation: tags, audience mode, sealed."
  @spec put_scope_label(Organization.t() | String.t(), String.t(), String.t(), String.t(), map()) ::
          result()
  def put_scope_label(org, project_id, connect_id, scope_id, attrs) when is_map(attrs) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         {:ok, connect_id} <- present(connect_id, :connect_not_found),
         {:ok, scope_id} <- present(scope_id, :scope_not_found) do
      client().ifc_put_scope_label(tenant_id, group_id, connect_id, scope_id, attrs)
    end
  end

  @doc "Returns one conversation to its defaults."
  @spec delete_scope_label(Organization.t() | String.t(), String.t(), String.t(), String.t()) ::
          result()
  def delete_scope_label(org, project_id, connect_id, scope_id) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         {:ok, connect_id} <- present(connect_id, :connect_not_found),
         {:ok, scope_id} <- present(scope_id, :scope_not_found) do
      client().ifc_delete_scope_label(tenant_id, group_id, connect_id, scope_id)
    end
  end

  @doc "Clears one provider user for one tag."
  @spec put_tag_clearance(
          Organization.t() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: result()
  def put_tag_clearance(org, project_id, connect_id, tag, user_id) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         {:ok, connect_id} <- present(connect_id, :connect_not_found),
         {:ok, tag} <- present(tag, :invalid_tag),
         {:ok, user_id} <- present(user_id, :invalid_principal) do
      client().ifc_put_tag_clearance(tenant_id, group_id, connect_id, tag, user_id)
    end
  end

  @doc "Withdraws one clearance."
  @spec delete_tag_clearance(
          Organization.t() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: result()
  def delete_tag_clearance(org, project_id, connect_id, tag, principal_key) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         {:ok, connect_id} <- present(connect_id, :connect_not_found),
         {:ok, tag} <- present(tag, :invalid_tag),
         {:ok, principal_key} <- present(principal_key, :invalid_principal) do
      client().ifc_delete_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key)
    end
  end

  @doc """
  Overrides where one principal sits, or clears the override.

  A blank placement restores the provider's own answer, which is the only way
  back once someone has been overridden.
  """
  @spec put_placement_override(
          Organization.t() | String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: result()
  def put_placement_override(org, project_id, connect_id, user_id, placement) do
    with {:ok, tenant_id, group_id} <- scope(org, project_id),
         {:ok, connect_id} <- present(connect_id, :connect_not_found),
         {:ok, user_id} <- present(user_id, :invalid_principal) do
      client().ifc_put_placement_override(tenant_id, group_id, connect_id, user_id, placement)
    end
  end

  # ---------------------------------------------------------------------------
  # internal
  # ---------------------------------------------------------------------------

  # The join that makes every call above org-scoped: a project id the caller
  # supplied becomes a group id only if this org owns that project.
  defp scope(org, project_id) do
    with {:ok, %Organization{} = org} <- fetch_org(org),
         {:ok, tenant_id} <- tenant_id(org),
         {:ok, project} <- project(org, project_id) do
      {:ok, tenant_id, project.salix_group_id}
    end
  end

  defp project(org, project_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(project_id),
         {:ok, project} <- Projects.get_project(project_id),
         true <- project.org_id == org.id and is_nil(project.archived_at),
         true <- present?(project.salix_group_id) do
      {:ok, project}
    else
      _ -> {:error, :project_not_found}
    end
  end

  defp fetch_org(%Organization{} = org), do: {:ok, org}
  defp fetch_org(org_id) when is_binary(org_id), do: Orgs.get_org(org_id)
  defp fetch_org(_org), do: {:error, :not_found}

  defp tenant_id(%Organization{salix_tenant_id: tenant_id}) do
    if present?(tenant_id), do: {:ok, tenant_id}, else: {:error, :tenant_not_ready}
  end

  defp present(value, error) do
    if present?(value), do: {:ok, String.trim(value)}, else: {:error, error}
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp client, do: Client.impl()
end
