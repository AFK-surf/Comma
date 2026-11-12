defmodule SalixWeb.SiteOgImage do
  @moduledoc """
  The default share image of a public site: a screenshot of its home page.

  The image is a disposable projection of the site's public files, not a site
  file. A public GET never claims the agent, so the capture cannot write the VFS.
  It lives in one object per site under the agent prefix, which agent cleanup
  covers. The object stays until then if its site is removed.

  `version/2` digests the public tree. The object's metadata names the version it
  shows, so a publish makes it stale and the next read replaces it.

  Link previews fetch the image once and keep the result, so a capture must not
  be lost to a race. A visit to a page starts it in the background (`warm/3`),
  and an image read that finds no current object captures, or waits for the
  capture already running.

  Browser Run is paid and this URL is public, so each site gets at most one
  capture per window across the cluster, and each version at most
  `@version_attempts` captures per `@version_window_ms`. The second limit stops a
  home page that always fails to render from costing a capture every window
  until the next publish. A read that waits out `@await_attempts`, or meets a
  spent version, gets an error and a retry time. Redis unavailability admits
  nothing.
  """

  alias Salix.App.RouterInbox.RateLimit
  alias SalixAgent.{Browser, SiteId}
  alias SalixStore.{Ids, Keys, S3}

  require Logger

  @path "/_og-image.jpg"
  @capture_window_ms 60_000
  @version_attempts 3
  @version_window_ms 86_400_000
  @await_attempts 15
  @await_interval_ms 1_000
  @expected_refusals [
    :capture_limited,
    :version_exhausted,
    :browser_disabled,
    :browser_not_configured,
    :browser_capture_restricted
  ]

  def path, do: @path
  def url(version), do: @path <> "?v=" <> version
  def retry_after_seconds, do: Integer.to_string(div(@capture_window_ms, 1000))

  @doc "Whether the agent's tenant can capture, so a page may name the image."
  def available?(agent_id), do: Browser.capture_available?(Ids.tenant_id_from_agent!(agent_id))

  @doc "A digest of the public files under `base`. Reserved `/_*` paths do not count."
  def version(vfs, base) do
    prefix = base <> "/"

    vfs
    |> Enum.filter(fn {path, _entry} ->
      String.starts_with?(path, prefix) and not String.starts_with?(path, prefix <> "_")
    end)
    |> Enum.map(fn {path, entry} -> {path, entry["hash"]} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 12)
    |> Base.encode16(case: :lower)
  end

  @doc "The JPEG for `version`. Captures when the stored one is older, or waits for a capture."
  def fetch(agent_id, site_name, version) do
    key = Keys.agent_site_og_image(agent_id, site_name)

    case current_or_capture(key, agent_id, site_name, version) do
      {:error, :capture_limited} -> await(key, version, @await_attempts)
      result -> result
    end
  end

  @doc "Starts the capture a page's visitors will need, when none is known to be current."
  def warm(agent_id, site_name, version) do
    SystemsRuntime.TaskSupervisor.start_child(__MODULE__.Supervisor, fn ->
      key = Keys.agent_site_og_image(agent_id, site_name)

      # One look per window, so page views do not each read the object.
      with :ok <- admit("warm:" <> key, @capture_window_ms, 1) do
        current_or_capture(key, agent_id, site_name, version)
      end
    end)

    :ok
  end

  defp current_or_capture(key, agent_id, site_name, version) do
    case S3.get(key) do
      {:ok, %{body: image, meta: %{"version" => ^version}}} -> {:ok, image}
      {:ok, _older} -> capture(key, agent_id, site_name, version)
      {:error, :not_found} -> capture(key, agent_id, site_name, version)
      {:error, _} = error -> error
    end
  end

  defp await(_key, _version, 0), do: {:error, :capture_limited}

  defp await(key, version, attempts) do
    SystemsClock.sleep(@await_interval_ms)

    case S3.get(key) do
      {:ok, %{body: image, meta: %{"version" => ^version}}} -> {:ok, image}
      _ -> await(key, version, attempts - 1)
    end
  end

  defp capture(key, agent_id, site_name, version) do
    with :ok <- admit("capture:" <> key, @capture_window_ms, 1),
         :ok <- admit_version(key, version),
         {:ok, image} <-
           Browser.capture_page(
             Ids.tenant_id_from_agent!(agent_id),
             SiteId.site_url(agent_id, site_name) <> "/"
           ),
         {:ok, _} <-
           S3.put(key, image, content_type: "image/jpeg", meta: %{"version" => version}) do
      {:ok, image}
    else
      {:error, reason} = error when reason in @expected_refusals ->
        error

      {:error, reason} = error ->
        Logger.warning("site og image capture failed: #{inspect(reason)}")
        error
    end
  end

  defp admit_version(key, version) do
    case admit("version:" <> key <> ":" <> version, @version_window_ms, @version_attempts) do
      :ok -> :ok
      {:error, :capture_limited} -> {:error, :version_exhausted}
    end
  end

  defp admit(bucket, window_ms, limit) do
    case RateLimit.admit("site-og-image:" <> bucket, window_ms, limit) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :capture_limited}
    end
  rescue
    _ -> {:error, :capture_limited}
  catch
    :exit, _ -> {:error, :capture_limited}
  end
end
