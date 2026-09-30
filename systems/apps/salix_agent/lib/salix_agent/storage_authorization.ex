defmodule SalixAgent.StorageAuthorization do
  @moduledoc """
  Hard availability guard for workspace storage mutations.
  """

  alias SalixAgent.{AgentWorkspace, Control, GroupContext, SkillStore}

  @callback authorize_write(map()) :: :ok | {:error, term()}
  @site_doc_event_types MapSet.new([
                          "site_doc_namespace_write",
                          "site_doc_write",
                          "site_doc_delete"
                        ])
  # Comma Drive mutations (`SalixAgent.DriveMount`) are effects outside Salix
  # storage, but they answer to the same availability guard: a Workspace this
  # guard has closed writes nothing on the agent's behalf anywhere.
  @drive_event_types MapSet.new(["drive_write", "drive_delete"])

  @spec authorize_write(map()) :: :ok | {:error, term()}
  def authorize_write(attrs) when is_map(attrs) do
    billing_context = billing_context(attrs)

    if storage_mutation?(attrs[:events] || attrs["events"] || []) and
         billing_account_id(billing_context) do
      attrs =
        attrs
        |> Map.put(:billing_context, billing_context)
        |> Map.put("billing_context", billing_context)

      apply(impl(), :authorize_write, [attrs])
    else
      :ok
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec prepare_write(String.t(), String.t(), binary(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_write(agent_id, path, content, context_or_opts \\ %{}) do
    with :ok <- authorize_prepared_write(agent_id, path, context_or_opts) do
      agent_id
      |> AgentWorkspace.prepare_write(path, content)
      |> record_ifc_label(agent_id, path, context_or_opts)
    end
  end

  @spec prepare_write_stream(String.t(), String.t(), Enumerable.t(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare_write_stream(agent_id, path, stream, context_or_opts \\ %{}) do
    with :ok <- authorize_prepared_write(agent_id, path, context_or_opts) do
      agent_id
      |> AgentWorkspace.prepare_write_stream(path, stream)
      |> record_ifc_label(agent_id, path, context_or_opts)
    end
  end

  @doc """
  Marks a write as replacing the file's whole content, so it does not inherit
  what was there (`docs/verification.md` §8).

  The default is the other way round, because most writes are not
  replacements: `fs.edit_file` and `memory.write` in append mode read the file,
  keep what they did not touch, and write it back. The content they retained
  keeps its own audience whether or not the call that caused the edit knows
  about it — a request to change one `TODO` marker can honestly declare only
  itself, while the confidential paragraph three lines below survives the
  write untouched. So a write inherits the path's audience unless it says it
  replaced everything, and a new caller that forgets gets the restrictive
  reading rather than the leaky one.
  """
  @spec replacing_content(map()) :: map()
  def replacing_content(ctx) when is_map(ctx), do: Map.put(ctx, :ifc_replaces_content, true)
  def replacing_content(ctx), do: ctx

  # What the effect that caused this write drew on, as `SalixAgent.IFC.Check`
  # established it, joined with what the write kept, so a later read of the
  # path is no weaker than reading either would have been (§8).
  #
  # Every visible write passes through here — `fs.write_file`, `fs.edit_file`
  # and `memory.write` alike — so no tool needs to know about it. Absent
  # whenever the Group is `off`, or when audit mode let a would-be denial
  # through: the file then records nothing rather than recording something
  # nobody established.
  defp record_ifc_label({:ok, %{"type" => "vfs_write"} = event}, agent_id, path, context_or_opts) do
    case ifc_sources_label(context_or_opts) do
      nil ->
        {:ok, event}

      label ->
        {:ok, Map.put(event, "ifc_label", written_label(agent_id, path, label, context_or_opts))}
    end
  end

  defp record_ifc_label(other, _agent_id, _path, _context_or_opts), do: other

  # Four cases, and a write joins exactly what a read of the content it kept
  # would have returned — otherwise a write and a read of one file disagree
  # about who may see it, which is how an unlabelled file got relabelled by an
  # edit that only touched a marker in it.
  defp written_label(agent_id, path, sources_label, context_or_opts) do
    if auth_value(context_or_opts, :ifc_replaces_content, false) == true do
      sources_label
    else
      case AgentWorkspace.retained(agent_id, path) do
        {:labelled, retained} ->
          SalixAgent.IFC.FileLabels.join_encoded(sources_label, retained)

        # Something survives this write and nobody recorded its audience, so it
        # reads as agent-private and the write has to say so.
        :unlabelled ->
          SalixAgent.IFC.FileLabels.join_private(sources_label)

        # Nothing survives, so there is nothing to inherit.
        :absent ->
          sources_label
      end
    end
  end

  defp ifc_sources_label(context_or_opts) do
    case auth_value(context_or_opts, :ifc_evidence, nil) do
      %{"sources_label" => label} when is_list(label) -> label
      _absent -> nil
    end
  end

  @doc false
  def prepare_managed_write(agent_id, path, content, context_or_opts \\ %{}) do
    with :ok <- authorize_prepared_write(agent_id, path, context_or_opts) do
      AgentWorkspace.prepare_managed_write(agent_id, path, content)
    end
  end

  @doc false
  def prepare_managed_write_stream(agent_id, path, stream, context_or_opts \\ %{}) do
    with :ok <- authorize_prepared_write(agent_id, path, context_or_opts) do
      AgentWorkspace.prepare_managed_write_stream(agent_id, path, stream)
    end
  end

  defp storage_mutation?(events), do: Enum.any?(events, &storage_event?/1)

  defp storage_event?(event) when is_map(event) do
    type = event["type"] || event[:type]

    AgentWorkspace.workspace_event?(event) or SkillStore.skill_event?(event) or
      MapSet.member?(@site_doc_event_types, type) or MapSet.member?(@drive_event_types, type)
  end

  defp storage_event?(_event), do: false

  defp authorize_prepared_write(agent_id, path, context_or_opts) do
    authorize_write(%{
      agent_id: agent_id,
      events: [%{"type" => "vfs_write", "path" => path}],
      billing_context: auth_billing_context(context_or_opts),
      entrypoint: auth_value(context_or_opts, :entrypoint, "storage_write"),
      actor_type: auth_value(context_or_opts, :actor_type, "tool")
    })
  end

  defp auth_billing_context(context_or_opts) when is_list(context_or_opts) do
    Keyword.get(context_or_opts, :billing_context, %{})
  end

  defp auth_billing_context(context_or_opts) when is_map(context_or_opts) do
    context_or_opts[:billing_context] || context_or_opts["billing_context"] || %{}
  end

  defp auth_billing_context(_context_or_opts), do: %{}

  defp auth_value(context_or_opts, key, default) when is_list(context_or_opts) do
    Keyword.get(context_or_opts, key, default)
  end

  defp auth_value(context_or_opts, key, default) when is_map(context_or_opts) do
    context_or_opts[key] || context_or_opts[to_string(key)] || default
  end

  defp auth_value(_context_or_opts, _key, default), do: default

  defp billing_context(attrs) do
    context = attrs[:billing_context] || attrs["billing_context"] || %{}

    if billing_account_id(context) do
      context
    else
      derive_billing_context(attrs)
    end
  end

  defp derive_billing_context(attrs) do
    agent_id = attrs[:agent_id] || attrs["agent_id"]

    with agent_id when is_binary(agent_id) and agent_id != "" <- agent_id,
         {:ok, agent} <- Control.get_record(agent_id),
         group_id when is_binary(group_id) and group_id != "" <- agent["group_id"],
         tenant_id when is_binary(tenant_id) and tenant_id != "" <- agent["tenant_id"],
         {:ok, group} <- GroupContext.get(group_id, tenant_id),
         owner when is_map(owner) <- group["billing_owner"],
         account_id when is_binary(account_id) and account_id != "" <- owner["billing_account_id"] do
      %{
        "billing_account_id" => account_id,
        "surface" => owner["surface"],
        "product_owner_type" => owner["product_owner_type"],
        "product_owner_id" => owner["product_owner_id"],
        "tenant_id" => owner["salix_tenant_id"] || tenant_id,
        "group_id" => owner["salix_group_id"] || group_id,
        "salix_tenant_id" => owner["salix_tenant_id"] || tenant_id,
        "salix_group_id" => owner["salix_group_id"] || group_id,
        "charge_policy" => owner["charge_policy"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp billing_account_id(context) when is_map(context) do
    case context["billing_account_id"] || context[:billing_account_id] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp billing_account_id(_context), do: nil

  defp impl do
    Application.get_env(:salix_agent, :storage_authorization_mod, __MODULE__.Noop)
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(_attrs), do: :ok
  end

  defmodule BillingCore do
    @moduledoc false
    @behaviour SalixAgent.StorageAuthorization

    @impl true
    def authorize_write(attrs) do
      context = attrs[:billing_context] || %{}
      account_id = context["billing_account_id"] || context[:billing_account_id]
      entrypoint = attrs[:entrypoint] || context["entrypoint"] || "storage_write"
      actor_type = attrs[:actor_type] || context["actor_type"] || "system"

      request =
        Module.concat([:BillingCore, :FeeControl, :Request])
        |> struct(%{
          billing_account_id: account_id,
          resource_kind: :storage,
          action: :write,
          mode: :enforce,
          estimated_credits: 1,
          balance_snapshot: attrs[:balance_snapshot] || context["balance_snapshot"] || 0,
          provider: "salix_store",
          sku: "storage_write",
          typed_sink: attrs[:typed_sink],
          source: "storage_authorization",
          source_key: attrs[:source_key] || "storage:#{account_id}:#{entrypoint}",
          row_context: %{
            "billing_account_id" => account_id,
            "surface" => context["surface"] || context[:surface] || "unknown",
            "product_owner_type" =>
              context["product_owner_type"] || context[:product_owner_type] || "unknown",
            "product_owner_id" =>
              context["product_owner_id"] || context[:product_owner_id] || "unknown",
            "tenant_id" => context["salix_tenant_id"] || context[:salix_tenant_id] || "",
            "group_id" => context["salix_group_id"] || context[:salix_group_id] || "",
            "entrypoint" => entrypoint,
            "actor_type" => actor_type
          }
        })

      fee_control = Module.concat([:BillingCore, :FeeControl])

      case apply(fee_control, :authorize, [request]) do
        {:ok, %{allowed?: true}} -> :ok
        {:ok, decision} -> {:error, {:billing_unavailable, decision}}
        {:error, _} = err -> err
      end
    end
  end
end
