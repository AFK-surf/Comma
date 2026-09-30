defmodule SalixIM.Ports.AgentWorkspace do
  @moduledoc """
  Outbound port used by provider APIs that need to read from or stage files
  into an agent VFS.
  """

  @callback read_upload(agent_id :: String.t(), path :: String.t(), title :: String.t()) ::
              {:ok, %{data: binary(), filename: String.t(), path: String.t()}} | {:error, term()}

  @doc """
  Directory listing for `path`.

  `{:ok, entries}` is a directory (possibly empty, which is how the root of an
  untouched workspace answers), `{:file, entry}` is a path that names a file
  rather than a directory, and `{:error, :not_found}` is neither. That
  three-way answer is why `:not_found` stays an ATOM here while the other
  callbacks flatten errors to a sentence: callers distinguish "no such path"
  from "the VFS is unreachable", and a sentence cannot be matched on.
  `put_ref` additionally preserves typed errors for Conversation delivery,
  whose existing participant owner must classify bounded retries.
  """
  @callback list(agent_id :: String.t(), path :: String.t()) ::
              {:ok, [map()]} | {:file, map()} | {:error, :not_found} | {:error, term()}

  @callback write(agent_id :: String.t(), path :: String.t(), body :: binary()) ::
              {:ok, %{path: String.t(), size: non_neg_integer()}} | {:error, term()}

  @doc "The adapter preserves storage/control error terms; the dispatcher owns display formatting."
  @callback put_ref(agent_id :: String.t(), path :: String.t(), ref :: map()) ::
              {:ok, %{path: String.t(), size: non_neg_integer()}} | {:error, term()}

  @callback file_ref(agent_id :: String.t(), path :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback read_stream(agent_id :: String.t(), path :: String.t()) ::
              {:ok, Enumerable.t(), non_neg_integer(), String.t()} | {:error, term()}

  @callback read_ref_stream(agent_id :: String.t(), ref :: map(), filename :: String.t()) ::
              {:ok, Enumerable.t(), non_neg_integer(), String.t()} | {:error, term()}

  @spec read_upload(String.t() | nil, term(), term()) :: {:ok, map()} | {:error, term()}
  def read_upload(agent_id, path, title \\ "") do
    impl().read_upload(to_string(agent_id || ""), to_string(path || ""), to_string(title || ""))
  end

  @spec list(String.t() | nil, term()) ::
          {:ok, [map()]} | {:file, map()} | {:error, :not_found} | {:error, term()}
  def list(agent_id, path) do
    impl().list(to_string(agent_id || ""), to_string(path || ""))
  end

  @spec write(String.t() | nil, term(), binary()) :: {:ok, map()} | {:error, term()}
  def write(agent_id, path, body) when is_binary(body) do
    impl().write(to_string(agent_id || ""), to_string(path || ""), body)
  end

  @doc """
  Maps an existing blob into the Agent VFS. Provider callers retain the original
  human-readable errors. Only Conversation attachment materialization requests
  `preserve_error: true` so its existing delivery owner can classify failures;
  this option does not change the write, authorization, or retry owner.
  """
  @spec put_ref(String.t() | nil, term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_ref(agent_id, path, ref, opts \\ []) do
    result = impl().put_ref(to_string(agent_id || ""), to_string(path || ""), ref)

    case result do
      {:error, reason} ->
        {:error,
         if(Keyword.get(opts, :preserve_error, false), do: reason, else: display_error(reason))}

      other ->
        other
    end
  end

  defp display_error(reason) when is_binary(reason), do: reason
  defp display_error({:bad_request, message}) when is_binary(message), do: message
  defp display_error(reason), do: inspect(reason)

  @spec file_ref(String.t() | nil, term()) :: {:ok, map()} | {:error, term()}
  def file_ref(agent_id, path) do
    impl().file_ref(to_string(agent_id || ""), to_string(path || ""))
  end

  @spec read_stream(String.t() | nil, term()) ::
          {:ok, Enumerable.t(), non_neg_integer(), String.t()} | {:error, term()}
  def read_stream(agent_id, path) do
    impl().read_stream(to_string(agent_id || ""), to_string(path || ""))
  end

  @spec read_ref_stream(String.t() | nil, map(), term()) ::
          {:ok, Enumerable.t(), non_neg_integer(), String.t()} | {:error, term()}
  def read_ref_stream(agent_id, ref, filename) when is_map(ref) do
    impl().read_ref_stream(
      to_string(agent_id || ""),
      ref,
      to_string(filename || "")
    )
  end

  defp impl, do: Application.get_env(:salix_im, :agent_workspace_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentWorkspace

    @impl true
    def read_upload(_agent_id, _path, _title), do: {:error, "agent VFS is not available"}

    @impl true
    def list(_agent_id, _path), do: {:error, "agent VFS is not available"}

    @impl true
    def write(_agent_id, _path, _body), do: {:error, "agent VFS is not available"}

    @impl true
    def put_ref(_agent_id, _path, _ref), do: {:error, "agent VFS is not available"}

    @impl true
    def file_ref(_agent_id, _path), do: {:error, "agent VFS is not available"}

    @impl true
    def read_stream(_agent_id, _path), do: {:error, "agent VFS is not available"}

    @impl true
    def read_ref_stream(_agent_id, _ref, _filename),
      do: {:error, "agent VFS is not available"}
  end
end
