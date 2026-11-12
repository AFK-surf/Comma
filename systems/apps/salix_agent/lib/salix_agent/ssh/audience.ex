defmodule SalixAgent.SSH.Audience do
  @moduledoc """
  Who may use an SSH host, and the audience of what it returns
  (`docs/verification.md` §3.3).

  Every `ssh.*` call authenticates with the Group's SSH key, so anyone in the
  Group could have run the same command: what a host returns has the Group's
  audience, `{group, id}`, the one `SalixAgent.IFC.ConnectorLabels` gives MCP
  and Composio reads. Without a label of its own an `ssh.*` result, which is
  classified as egress, would get the round's label instead, and a round that
  declared `sources: []` would make a database read over SSH public.

  An operator can restrict a host key to a tag
  (`SalixAgent.SSH.KnownHosts.restrict/3`). Such a host is then used only for
  a requester cleared for that tag or a supervisor of the Group (who reads
  every tag), checked on every call, since an SSH
  session outlives the round that opened it. Its results carry
  `{group, id}` and `{tag, name}`, so they reach only the tag's readers.
  The requester is the principal the call's sealed origin names
  (`SalixAgent.IFC.principal/1`); a schedule or Loop carries its creator's.
  """

  alias SalixAgent.SSH.{Connection, KnownHosts}
  alias SalixIFC.{Codec, Label}
  alias SalixStore.{CasRecord, Keys}

  @doc """
  The tag restricting the host key `fingerprint`, after checking that this
  call's requester is cleared for it: `{:ok, nil}` for an unrestricted host,
  `{:ok, tag}`, or `{:error, diagnostic}`. Fails closed when the restriction
  or the clearance cannot be read.
  """
  @spec admit(map(), String.t() | nil) :: {:ok, String.t() | nil} | {:error, map()}
  def admit(ctx, fingerprint) when is_binary(fingerprint) and fingerprint != "" do
    case KnownHosts.restriction(group_id(ctx), fingerprint) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, tag} ->
        case cleared?(ctx, tag) do
          true -> {:ok, tag}
          false -> {:error, refused(fingerprint)}
          :unavailable -> {:error, unavailable(fingerprint)}
        end

      {:error, _reason} ->
        {:error, unavailable(fingerprint)}
    end
  end

  def admit(_ctx, _fingerprint), do: {:ok, nil}

  @doc "Attaches the host's audience to a tool result. Silent for a session that is not labelling."
  @spec label(term(), map(), String.t() | nil) :: term()
  def label(result, ctx, tag) do
    if is_map(Map.get(ctx, :ifc)),
      do: attach(result, %{"label" => encoded(ctx, tag)}),
      else: result
  end

  @doc """
  The context for an SFTP download: the written file records the host's
  audience joined with what the call drew on, as a read of it then returns.
  """
  @spec download_ctx(map(), String.t() | nil) :: map()
  def download_ctx(ctx, tag) do
    case Map.get(ctx, :ifc_evidence) do
      %{"sources_label" => sources} = evidence when is_list(sources) ->
        joined = SalixAgent.IFC.FileLabels.join_encoded(sources, encoded(ctx, tag))
        Map.put(ctx, :ifc_evidence, Map.put(evidence, "sources_label", joined))

      _absent ->
        ctx
    end
  end

  defp encoded(ctx, tag) do
    case group_id(ctx) do
      "" ->
        Codec.encode_label(Label.new([:agent_private]))

      group_id ->
        atoms = [{:group, group_id} | if(tag, do: [{:tag, tag}], else: [])]
        Codec.encode_label(Label.new(atoms))
    end
  end

  # A tag's readers are the provider users an operator cleared for it, per
  # connect (`SalixStore.IFC.tag_clearances/4`), and the Group's supervisors
  # (`ifc.supervisors` on the Group record), as the kernel reads them.
  defp cleared?(ctx, tag) do
    case SalixAgent.IFC.principal(Map.get(ctx, :trusted_origin)) do
      {:provider_user, connect_id, _user} = principal ->
        key = Codec.encode_principal!(principal)

        with false <- supervisor?(ctx, key) do
          case SalixStore.IFC.tag_clearances(tenant_id(ctx), group_id(ctx), connect_id, [tag]) do
            {:ok, %{^tag => %{members: members}}} -> key in members
            {:ok, _none} -> false
            {:error, _reason} -> :unavailable
          end
        end

      _no_person ->
        false
    end
  end

  defp supervisor?(ctx, key) do
    case CasRecord.get(Keys.ctl_group(group_id(ctx))) do
      {:ok, %{"ifc" => %{"supervisors" => supervisors}}} when is_list(supervisors) ->
        key in supervisors

      {:ok, _group} ->
        false

      {:error, _reason} ->
        :unavailable
    end
  end

  defp attach({content, events}, ifc) when is_binary(content) and is_list(events),
    do: {:tool_ifc, content, events, ifc}

  defp attach(content, ifc) when is_binary(content), do: {:tool_ifc, content, [], ifc}
  defp attach(result, _ifc), do: result

  defp refused(fingerprint) do
    Connection.diagnostic(
      "host_restricted",
      "An administrator restricted this host. Only people cleared for its tag on the Data policy page can have the Agent use it, and the person who asked is not.",
      %{"fingerprint" => fingerprint}
    )
  end

  defp unavailable(fingerprint) do
    Connection.diagnostic(
      "host_access_unavailable",
      "Whether this host is restricted could not be checked. Retry shortly.",
      %{"fingerprint" => fingerprint}
    )
  end

  defp group_id(ctx), do: to_string(Map.get(ctx, :group_id) || "")

  defp tenant_id(ctx) do
    case Map.get(ctx, :tenant_id) do
      tenant when is_binary(tenant) and tenant != "" -> tenant
      _ -> SalixStore.Ids.tenant_id_from_group!(group_id(ctx))
    end
  end
end
