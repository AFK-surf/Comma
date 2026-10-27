defmodule Comma.MiniApps.Blobs do
  @moduledoc """
  Mini App objects in the deployment's object store (`SalixStore.S3`), all
  under `miniapps/apps/<app_id>/`:

    * `versions/<n>/bundle.tar`, `versions/<n>/source.tar.gz`,
      `versions/<n>/icon`, `versions/<n>/cover`: one Version's files;
    * `docs/app/…` and `docs/user/<viewer id>/…`: app documents
      (`Comma.MiniApps.Documents`).

  Deleting an app deletes its whole prefix.
  """

  alias SalixStore.S3

  @root "miniapps/apps/"
  @delete_page 500

  def app_prefix(app_id), do: @root <> app_id <> "/"
  def version_prefix(app_id, number), do: app_prefix(app_id) <> "versions/#{number}/"
  def bundle_key(app_id, number), do: version_prefix(app_id, number) <> "bundle.tar"
  def source_key(app_id, number), do: version_prefix(app_id, number) <> "source.tar.gz"
  def icon_key(app_id, number), do: version_prefix(app_id, number) <> "icon"
  def cover_key(app_id, number), do: version_prefix(app_id, number) <> "cover"

  @doc "The documents prefix of one scope: `app`, or `{:user, viewer_id}`."
  def docs_prefix(app_id, :app), do: app_prefix(app_id) <> "docs/app/"

  def docs_prefix(app_id, {:user, viewer}),
    do: app_prefix(app_id) <> "docs/user/" <> viewer <> "/"

  @doc "Stores a local file under `key`."
  def put_file(key, path, content_type) do
    with {:ok, body} <- File.read(path),
         {:ok, _} <- S3.put(key, body, content_type: content_type) do
      :ok
    else
      {:error, reason} -> {:error, {:blob_store_failed, reason}}
    end
  end

  def put(key, body, content_type) do
    case S3.put(key, body, content_type: content_type) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:blob_store_failed, reason}}
    end
  end

  @doc "Opens `key` as a stream of binaries, or `{:error, :not_found}`."
  def stream(key), do: S3.stream(key)

  def get(key) do
    case S3.get(key) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  @doc """
  Deletes one bounded page of objects under `prefix`: `:done` when none is
  left, `:more` when a later run continues.
  """
  def delete_page(prefix) do
    case S3.list(prefix, max_keys: @delete_page) do
      {:ok, %{objects: []}} ->
        :done

      {:ok, %{objects: objects, next: next}} ->
        Enum.each(objects, fn %{key: key} -> S3.delete(key) end)
        if next || length(objects) >= @delete_page, do: :more, else: :done

      {:error, reason} ->
        {:error, reason}
    end
  end
end
