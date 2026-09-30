defmodule SalixAgent.Browser.Storage do
  @moduledoc "Bounded cookie and first-party localStorage transfer through a private, network-intercepted CDP target."
  alias SalixAgent.Browser.{Commands, Connection}

  @cookie_fields ~w(name value domain path secure httpOnly sameSite expires priority sameParty sourceScheme sourcePort partitionKey)

  def export(state) do
    # Include documents already open when a replacement driver attached.
    {_, state} = Commands.execute(state, "tabs", %{})

    for {_, session} <- state.tabs do
      remember_frames(state, Commands.cdp(state, "Page.getFrameTree", %{}, session)["frameTree"])
    end

    {origins, count, access} =
      case Connection.origins(state.conn) do
        {:ok, origins, count, access} -> {origins, count, access}
        {:error, reason} -> fail(reason)
      end

    values =
      with_target(state, fn session ->
        Map.new(origins, fn origin ->
          navigate(state, session, origin)

          items =
            Commands.cdp(
              state,
              "DOMStorage.getDOMStorageItems",
              %{storageId: storage_id(origin)},
              session
            )["entries"]

          if items == [], do: Connection.forget_origin(state.conn, origin)
          {origin, items}
        end)
      end)

    cookies = Commands.cdp(state, "Storage.getCookies")["cookies"]
    # Cookie read-only fields must not be sent back to setCookies.
    cookies =
      Enum.map(cookies, fn cookie ->
        if cookie["partitionKeyOpaque"], do: fail(:browser_storage_unsupported)
        cookie = Map.take(cookie, @cookie_fields)
        if cookie["expires"] == -1, do: Map.delete(cookie, "expires"), else: cookie
      end)

    # Retain observed recency while this browser lives, including cookies that
    # SQL evicted. Exporting an unchanged cookie must not make it recent again.
    hosts = Enum.map(access, fn {origin, used} -> {URI.parse(origin).host, used} end)

    observed =
      Map.new(cookies, fn cookie ->
        key = SalixStore.BrowserStorage.cookie_key(cookie)

        used =
          case state.cookies[key] do
            {^cookie, used} -> used
            _ -> System.system_time(:microsecond)
          end

        domain = String.trim_leading(cookie["domain"] || "", ".")

        used =
          Enum.reduce(hosts, used, fn {host, time}, latest ->
            if is_binary(host) and (host == domain or String.ends_with?(host, "." <> domain)),
              do: max(time, latest),
              else: latest
          end)

        {key, {cookie, used}}
      end)

    state = %{state | cookies: observed}

    snapshot = %{
      "cookies" => cookies,
      "origins" => values,
      "access" => access,
      "cookie_access" => Map.new(observed, fn {key, {_, used}} -> {key, used} end)
    }

    {Map.put(snapshot, "remaining", max(0, count - length(origins))), state}
  end

  def restore(state, %{"cookies" => cookies, "origins" => origins} = snapshot) do
    state = seed(state, snapshot)

    with_target(state, fn session ->
      for {origin, items} <- origins do
        navigate(state, session, origin)

        for [key, value] <- items do
          Commands.cdp(
            state,
            "DOMStorage.setDOMStorageItem",
            %{storageId: storage_id(origin), key: key, value: value},
            session
          )
        end
      end
    end)

    Commands.cdp(state, "Storage.setCookies", %{cookies: cookies})
    {%{}, state}
  end

  def seed(state, snapshot) do
    cookies =
      Map.new(snapshot["cookies"], fn cookie ->
        key = SalixStore.BrowserStorage.cookie_key(cookie)
        {key, {cookie, get_in(snapshot, ["last_used", key]) || 0}}
      end)

    %{state | cookies: cookies}
  end

  defp remember_frames(state, %{"frame" => frame} = tree) do
    Connection.remember_origin(state.conn, frame["securityOrigin"])
    Enum.each(tree["childFrames"] || [], &remember_frames(state, &1))
  end

  defp with_target(state, fun) do
    target = Commands.cdp(state, "Target.createTarget", %{url: "about:blank"})["targetId"]

    try do
      session =
        Commands.cdp(state, "Target.attachToTarget", %{targetId: target, flatten: true})[
          "sessionId"
        ]

      Connection.storage_session(state.conn, session)
      Commands.cdp(state, "Page.enable", %{}, session)
      Commands.cdp(state, "Network.setBypassServiceWorker", %{bypass: true}, session)
      Commands.cdp(state, "Network.setCacheDisabled", %{cacheDisabled: true}, session)
      Commands.cdp(state, "Fetch.enable", %{patterns: [%{urlPattern: "*"}]}, session)
      fun.(session)
    after
      Commands.cdp(state, "Target.closeTarget", %{targetId: target})
      wait_closed(state, target, System.monotonic_time(:millisecond) + 5000)
      Connection.storage_session(state.conn, nil)
    end
  end

  defp wait_closed(state, target, deadline) do
    if Enum.any?(
         Commands.cdp(state, "Target.getTargets")["targetInfos"],
         &(&1["targetId"] == target)
       ) do
      if System.monotonic_time(:millisecond) >= deadline, do: fail(:browser_storage_unavailable)
      Process.sleep(10)
      wait_closed(state, target, deadline)
    end
  end

  defp navigate(state, session, origin) do
    result = Commands.cdp(state, "Page.navigate", %{url: origin <> "/"}, session)
    if result["errorText"], do: fail(:browser_storage_unavailable)
    wait_origin(state, session, origin, System.monotonic_time(:millisecond) + 5000)
  end

  defp wait_origin(state, session, origin, deadline) do
    frame = Commands.cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]

    if frame["securityOrigin"] == origin do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: fail(:browser_storage_unavailable)
      Process.sleep(10)
      wait_origin(state, session, origin, deadline)
    end
  end

  defp storage_id(origin), do: %{securityOrigin: origin, isLocalStorage: true}
  defp fail(reason), do: throw({:browser_error, reason})
end
