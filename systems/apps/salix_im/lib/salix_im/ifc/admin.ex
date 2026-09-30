defmodule SalixIM.IFC.Admin do
  @moduledoc """
  The operator's view of information-flow settings
  (`docs/verification.md` §3.6, §10).

  Everything section 3.6 lets an operator decide lives in `SalixStore.IFC` as
  rows. This is the one place that assembles them into something a person can
  look at, and the one place a dashboard writes them through, so the Bridge For
  Teams page never reaches into the store's schemas directly.

  Two honesty rules the assembly keeps:

    * **Observed and decided are different columns.** A conversation the
      projection has seen and a conversation an operator has classified are
      separate facts, and a row shows both — including a classification for a
      conversation nothing has been observed about yet, which is a real state
      (someone classified a channel before the bot ever saw traffic in it) and
      not a rendering bug.
    * **A placement shows what a decision would use.** The provider's answer
      and the operator's override are both returned, because "external" on this
      page has to mean the same thing the kernel will read.

  Reads degrade per connect: one unavailable connect contributes an error entry
  and the rest of the page still renders.
  """

  alias SalixIM.ProviderConnects
  alias SalixStore.IFC, as: Store

  @modes ~w(off audit enforce)
  @audience_modes ~w(space members)
  @languages ~w(zh en)
  @placements ~w(internal external)

  @doc """
  Every information-flow setting in one Group, by connect.

  `mode` is the Group's own, read from the control record rather than the
  cache, because an operator who just changed it must see what they changed.
  """
  @spec overview(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def overview(tenant_id, group_id) do
    with {:ok, group} <- group(group_id, tenant_id) do
      connects =
        group_id
        |> connects()
        |> Enum.map(&connect_settings(tenant_id, group_id, &1))

      {:ok,
       %{
         "group_id" => group_id,
         "tenant_id" => tenant_id,
         "mode" => mode_of(group),
         "modes" => @modes,
         "language" => language_of(group),
         "languages" => @languages,
         "audience_modes" => @audience_modes,
         "connects" => connects
       }}
    end
  end

  @doc "Classifies one conversation: tags, audience mode, sealed."
  @spec put_scope_label(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def put_scope_label(tenant_id, group_id, connect_id, scope_id, attrs) when is_map(attrs) do
    with {:ok, attrs} <- scope_label_attrs(attrs) do
      settled(Store.put_scope_label(tenant_id, group_id, connect_id, scope_id, attrs))
    end
  end

  @doc "Removes a classification, returning the conversation to its defaults."
  @spec delete_scope_label(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def delete_scope_label(tenant_id, group_id, connect_id, scope_id),
    do: settled(Store.delete_scope_label(tenant_id, group_id, connect_id, scope_id))

  @doc """
  Clears one principal for one tag.

  A clearance says what a person may *read*; it never changes what they write
  (§3.6), which is why this takes a tag and a principal and nothing else.
  """
  @spec put_tag_clearance(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_tag_clearance(tenant_id, group_id, connect_id, tag, user_id) do
    with {:ok, tag} <- present(tag, :invalid_tag),
         {:ok, user_id} <- present(user_id, :invalid_principal) do
      settled(
        Store.put_tag_clearance(
          tenant_id,
          group_id,
          connect_id,
          tag,
          principal_key(connect_id, user_id)
        )
      )
    end
  end

  @doc "Withdraws one clearance."
  @spec delete_tag_clearance(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def delete_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key),
    do: settled(Store.delete_tag_clearance(tenant_id, group_id, connect_id, tag, principal_key))

  @doc """
  Overrides what the provider says about where one person sits.

  A blank placement drops the row entirely, which is how an override is undone:
  the provider's own answer is observed again the next time that person is
  seen, so the projection reverts rather than this module inventing a value.
  """
  @spec put_placement_override(String.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def put_placement_override(tenant_id, group_id, connect_id, user_id, placement) do
    with {:ok, user_id} <- present(user_id, :invalid_principal),
         {:ok, placement} <- placement(placement) do
      case placement do
        nil ->
          settled(Store.delete_principal_fact(tenant_id, group_id, connect_id, user_id))

        value ->
          settled(Store.put_principal_fact(tenant_id, group_id, connect_id, user_id, value))
      end
    end
  end

  # The store answers a write with the row's new revision, or nothing at all for
  # a delete. Neither is any use to a dashboard, and a caller that had to know
  # which shape came back would get it wrong exactly once. Every write here says
  # `:ok`.
  defp settled({:ok, _revision}), do: :ok
  defp settled(:ok), do: :ok
  defp settled({:error, _reason} = error), do: error

  # ---------------------------------------------------------------------------
  # Assembly
  # ---------------------------------------------------------------------------

  defp connect_settings(tenant_id, group_id, connect) do
    connect_id = text(connect["connect_id"])

    base = %{
      "connect_id" => connect_id,
      "provider" => text(connect["provider"]),
      "name" => text(connect["name"] || connect["workspace_name"])
    }

    with {:ok, facts} <- Store.list_scope_facts(tenant_id, group_id, connect_id),
         {:ok, labels} <- Store.list_scope_labels(tenant_id, group_id, connect_id),
         {:ok, clearances} <- Store.list_tag_clearances(tenant_id, group_id, connect_id),
         {:ok, principals} <- Store.list_principal_facts(tenant_id, group_id, connect_id) do
      Map.merge(base, %{
        "available" => true,
        "scopes" => merge_scopes(facts, labels),
        "clearances" => group_clearances(clearances),
        "principals" => principals
      })
    else
      _unavailable ->
        Map.merge(base, %{
          "available" => false,
          "scopes" => [],
          "clearances" => [],
          "principals" => []
        })
    end
  end

  # One row per conversation, whether it was observed, classified, or both.
  defp merge_scopes(facts, labels) do
    by_id = Map.new(labels, &{&1["scope_id"], &1})

    observed =
      Enum.map(facts, fn fact ->
        label = Map.get(by_id, fact["scope_id"], %{})

        fact
        |> Map.merge(%{
          "tags" => label["tags"] || [],
          "audience_mode" => label["audience_mode"] || "space",
          "sealed" => label["sealed"] || false,
          "classified" => label != %{}
        })
      end)

    classified_only =
      labels
      |> Enum.reject(fn label -> Enum.any?(facts, &(&1["scope_id"] == label["scope_id"])) end)
      |> Enum.map(fn label ->
        %{
          "scope_id" => label["scope_id"],
          "kind" => nil,
          "display_name" => nil,
          "observed_at" => nil,
          "members_complete" => false,
          "tags" => label["tags"] || [],
          "audience_mode" => label["audience_mode"] || "space",
          "sealed" => label["sealed"] || false,
          "classified" => true
        }
      end)

    Enum.sort_by(observed ++ classified_only, & &1["scope_id"])
  end

  defp group_clearances(rows) do
    rows
    |> Enum.group_by(& &1["tag"], & &1["principal_key"])
    |> Enum.map(fn {tag, principals} ->
      %{"tag" => tag, "principals" => Enum.sort(principals)}
    end)
    |> Enum.sort_by(& &1["tag"])
  end

  defp connects(group_id) do
    case ProviderConnects.list_group_im_connects(group_id) do
      {:ok, connects} when is_list(connects) -> connects
      _unavailable -> []
    end
  end

  defp mode_of(group) do
    case Map.get(group, "ifc") do
      %{"mode" => mode} when is_binary(mode) -> if mode in @modes, do: mode, else: "off"
      _absent -> "off"
    end
  end

  # The language the runtime writes its own sentences in — a refusal, a
  # provenance footer, a confirmation card (§6.4). Chinese unless the Group
  # says otherwise, which is what every existing workspace already reads.
  defp language_of(group) do
    case Map.get(group, "ifc") do
      %{"language" => language} when is_binary(language) ->
        if language in @languages, do: language, else: "zh"

      _absent ->
        "zh"
    end
  end

  defp group(group_id, tenant_id) do
    if text(group_id) == "",
      do: {:error, :not_found},
      else: SalixIM.GroupDirectory.get_group(group_id, tenant_id)
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  defp scope_label_attrs(attrs) do
    tags = attrs |> Map.get("tags", attrs[:tags]) |> List.wrap() |> Enum.map(&text/1)
    audience_mode = text(Map.get(attrs, "audience_mode", attrs[:audience_mode]))
    sealed = Map.get(attrs, "sealed", attrs[:sealed])

    cond do
      Enum.any?(tags, &(&1 == "")) ->
        {:error, :invalid_tag}

      # A tag is an audience atom's name; the codec would refuse a separator
      # later, so refuse it here where a person can still see why.
      Enum.any?(tags, &String.contains?(&1, "|")) ->
        {:error, :invalid_tag}

      audience_mode != "" and audience_mode not in @audience_modes ->
        {:error, :invalid_audience_mode}

      not is_nil(sealed) and not is_boolean(sealed) ->
        {:error, :invalid_sealed}

      true ->
        {:ok,
         %{tags: Enum.uniq(tags)}
         |> put_unless_blank(:audience_mode, audience_mode)
         |> put_unless_nil(:sealed, sealed)}
    end
  end

  defp placement(nil), do: {:ok, nil}

  defp placement(placement) do
    case text(placement) do
      "" -> {:ok, nil}
      value when value in @placements -> {:ok, value}
      _other -> {:error, :invalid_placement}
    end
  end

  defp principal_key(connect_id, user_id), do: "provider_user|#{connect_id}|#{user_id}"

  defp present(value, error) do
    case text(value) do
      "" -> {:error, error}
      present -> {:ok, present}
    end
  end

  defp put_unless_blank(attrs, _key, ""), do: attrs
  defp put_unless_blank(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_unless_nil(attrs, _key, nil), do: attrs
  defp put_unless_nil(attrs, key, value), do: Map.put(attrs, key, value)

  defp text(nil), do: ""
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(value), do: value |> to_string() |> String.trim()
end
