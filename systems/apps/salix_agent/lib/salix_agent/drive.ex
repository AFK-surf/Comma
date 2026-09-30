defmodule SalixAgent.Drive do
  @moduledoc """
  Port to the user's Comma Drive: the files a Workspace's members sync through
  Synchronicity, reached server-side through its control plane rather than
  through any device of theirs.

  The agent sees it as the `/drive/...` mount of `SalixAgent.FileBackend`
  (`SalixAgent.DriveMount`). Paths handed to an implementation are relative
  to the Drive root, without a leading slash; `""` is the root itself.

  The implementation is bound by `Salix.App`
  (`Application.put_env(:salix_agent, :drive_mod, Salix.Bindings.AgentDrive)`),
  which resolves an agent's group to its Drive binding; an unbound port
  answers `{:error, :drive_not_configured}` for everything, so the mount
  reads as absent rather than failing the node.

  What a caller may assume of an implementation, and no more:

    * A write lands as the hosted replica's own version of the path and never
      alters a version the user's device published; both stay visible. The
      user's devices see it at their next sync, not instantly.
    * A delete withdraws the hosted replica's version only. `still_published:
      true` means a user's device still asserts the path, which is not a
      failure and must not be retried.
    * Reads serve what the hosted replica holds; a file the user just saved on
      a device may not be there yet.
  """

  alias SalixAgent.OAuthStore

  @type ctx :: %{required(:agent_id) => String.t(), optional(atom() | String.t()) => term()}

  @typedoc "One entry of a Drive directory."
  @type entry :: %{
          path: String.t(),
          name: String.t(),
          kind: String.t(),
          size: non_neg_integer(),
          modified_at: non_neg_integer() | nil
        }

  @type write_result :: %{size: non_neg_integer(), root: String.t() | nil}
  @type delete_result :: %{withdrawn: boolean(), still_published: boolean()}
  @type status :: %{available: boolean(), writable: boolean(), detail: String.t()}

  @doc "The entries of one directory (`\"\"` for the root)."
  @callback list(group_id :: String.t(), path :: String.t()) ::
              {:ok, [entry()]} | {:error, term()}

  @doc "Metadata of one path, file or directory."
  @callback stat(group_id :: String.t(), path :: String.t()) ::
              {:ok, entry()} | {:error, :not_found | term()}

  @doc "At most `max_bytes` of one file; the flag says whether it was longer."
  @callback read(group_id :: String.t(), path :: String.t(), max_bytes :: pos_integer()) ::
              {:ok, binary(), boolean()} | {:error, :not_found | term()}

  @doc "A lazy stream of one file's bytes, consumed by the calling process."
  @callback stream(group_id :: String.t(), path :: String.t()) ::
              {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, :not_found | term()}

  @doc "Publishes `body` (a binary, or an enumerable totalling `size` bytes)."
  @callback write(
              group_id :: String.t(),
              path :: String.t(),
              body :: iodata() | Enumerable.t(),
              size :: non_neg_integer()
            ) :: {:ok, write_result()} | {:error, term()}

  @callback delete(group_id :: String.t(), path :: String.t()) ::
              {:ok, delete_result()} | {:error, term()}

  @doc "Whether the Drive can serve reads and take writes for this group now."
  @callback status(group_id :: String.t()) :: {:ok, status()} | {:error, term()}

  @doc "The bound implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:salix_agent, :drive_mod, __MODULE__.Unconfigured)

  @doc "True when a product has bound a Drive implementation."
  @spec configured?() :: boolean()
  def configured?, do: impl() != __MODULE__.Unconfigured

  @spec list(ctx(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(ctx, path), do: call(ctx, :list, [path])

  @spec stat(ctx(), String.t()) :: {:ok, entry()} | {:error, term()}
  def stat(ctx, path), do: call(ctx, :stat, [path])

  @spec read(ctx(), String.t(), pos_integer()) :: {:ok, binary(), boolean()} | {:error, term()}
  def read(ctx, path, max_bytes), do: call(ctx, :read, [path, max_bytes])

  @spec stream(ctx(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer() | nil} | {:error, term()}
  def stream(ctx, path), do: call(ctx, :stream, [path])

  @spec write(ctx(), String.t(), iodata() | Enumerable.t(), non_neg_integer()) ::
          {:ok, write_result()} | {:error, term()}
  def write(ctx, path, body, size), do: call(ctx, :write, [path, body, size])

  @spec delete(ctx(), String.t()) :: {:ok, delete_result()} | {:error, term()}
  def delete(ctx, path), do: call(ctx, :delete, [path])

  @spec status(ctx()) :: {:ok, status()} | {:error, term()}
  def status(ctx), do: call(ctx, :status, [])

  # The group the Drive belongs to: the ctx's own when the runtime put it
  # there, else the agent's record, the way group-scoped runtimes resolve it.
  defp call(ctx, command, args) do
    with {:ok, group_id} <- group_id(ctx) do
      apply(impl(), command, [group_id | args])
    end
  end

  defp group_id(ctx) when is_map(ctx) do
    case Map.get(ctx, :group_id) || Map.get(ctx, "group_id") do
      group_id when is_binary(group_id) and group_id != "" ->
        {:ok, group_id}

      _ ->
        agent_id = Map.get(ctx, :agent_id) || Map.get(ctx, "agent_id")

        with {:ok, context} when is_map(context) <- OAuthStore.agent_oauth_context(agent_id),
             group_id when is_binary(group_id) and group_id != "" <-
               context[:group_id] || context["group_id"] do
          {:ok, group_id}
        else
          {:error, _} = error -> error
          _ -> {:error, :missing_group_id}
        end
    end
  end

  defmodule Unconfigured do
    @moduledoc "The port with no product behind it: every call is refused."
    @behaviour SalixAgent.Drive

    @impl true
    def list(_group_id, _path), do: {:error, :drive_not_configured}
    @impl true
    def stat(_group_id, _path), do: {:error, :drive_not_configured}
    @impl true
    def read(_group_id, _path, _max_bytes), do: {:error, :drive_not_configured}
    @impl true
    def stream(_group_id, _path), do: {:error, :drive_not_configured}
    @impl true
    def write(_group_id, _path, _body, _size), do: {:error, :drive_not_configured}
    @impl true
    def delete(_group_id, _path), do: {:error, :drive_not_configured}
    @impl true
    def status(_group_id), do: {:error, :drive_not_configured}
  end
end
