defmodule SalixAgent.Browser.Commands do
  @moduledoc "Finite browser operations over CDP. Page scripts run in an isolated world."
  alias SalixAgent.Browser.{Connection, Input}

  def new(conn, timeout),
    do: %{conn: conn, timeout: timeout, tabs: %{}, refs: %{}, viewers: %{}, cookies: %{}}

  def execute(state, "storage_export", _), do: SalixAgent.Browser.Storage.export(state)

  def execute(state, "storage_restore", snapshot),
    do: SalixAgent.Browser.Storage.restore(state, snapshot)

  def execute(state, "tabs", _) do
    infos = cdp(state, "Target.getTargets")["targetInfos"] |> Enum.filter(&(&1["type"] == "page"))
    selected = Enum.take(infos, 32)
    ids = MapSet.new(selected, & &1["targetId"])
    {keep, drop} = Enum.split_with(state.tabs, fn {id, _} -> MapSet.member?(ids, id) end)

    Enum.each(drop, fn {_, session} ->
      Connection.clear_frame(state.conn, session)
      Connection.command(state.conn, "Target.detachFromTarget", %{sessionId: session})
    end)

    state = %{
      state
      | tabs: Map.new(keep),
        refs: Map.take(state.refs, MapSet.to_list(ids)),
        viewers: Map.take(state.viewers, MapSet.to_list(ids))
    }

    state = Enum.reduce(selected, state, fn info, acc -> attach(acc, info["targetId"]) end)

    tabs =
      Enum.map(selected, fn info ->
        %{
          "tab_id" => info["targetId"],
          "url" => String.slice(info["url"], 0, 4096),
          "title" => String.slice(info["title"], 0, 256)
        }
      end)

    {%{"tabs" => tabs, "truncated" => length(infos) > 32}, state}
  end

  def execute(state, "new_tab", args) do
    {tabs, state} = execute(state, "tabs", args)
    if length(tabs["tabs"]) >= 32, do: fail("driver_busy")
    cdp(state, "Target.createTarget", %{url: "about:blank"})
    execute(state, "tabs", args)
  end

  def execute(%{tabs: tabs} = state, op, %{"tab_id" => _} = args) when map_size(tabs) == 0 do
    {_, state} = execute(state, "tabs", %{})
    perform(state, op, args)
  end

  def execute(state, op, args), do: perform(state, op, args)

  defp perform(state, op, %{"tab_id" => tab} = args) do
    session = state.tabs[tab] || fail("tab_not_found")

    case op do
      "close_tab" ->
        cdp(state, "Target.closeTarget", %{targetId: tab})
        # CDP acknowledges the request before the target necessarily disappears.
        wait_until(state.timeout, fn ->
          not Enum.any?(cdp(state, "Target.getTargets")["targetInfos"], &(&1["targetId"] == tab))
        end)

        execute(state, "tabs", %{})

      "snapshot" ->
        snapshot(state, tab, session)

      "navigate" ->
        url = Input.text(args["url"], 4096)
        uri = URI.parse(url)

        unless uri.scheme in ["http", "https"] and is_binary(uri.host) and is_nil(uri.userinfo),
          do: fail("invalid_url")

        result = cdp(state, "Page.navigate", %{url: url}, session)
        if result["errorText"], do: fail("browser_operation_failed")
        # The loader identity prevents a previous document's readyState from
        # completing this navigation before the new document commits.
        wait_until(state.timeout, fn ->
          tree = cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]

          (is_nil(result["loaderId"]) or tree["loaderId"] == result["loaderId"]) and
            evaluate(state, session, "document.readyState !== 'loading'") == true
        end)

        result(state, tab, session, Map.delete(state.refs, tab))

      "screenshot" ->
        shot =
          cdp(
            state,
            "Page.captureScreenshot",
            %{format: "jpeg", quality: 60, captureBeyondViewport: false},
            session
          )

        {%{"mime_type" => "image/jpeg", "data" => shot["data"]}, state}

      "click" ->
        {x, y} =
          if args["ref"] do
            object = reference(state, tab, session, args["ref"])

            point =
              wait_until(state.timeout, fn ->
                point =
                  call_object(state, session, object, """
                  async function() {
                    if (!this.isConnected) return {error: 'stale_element'};
                    this.scrollIntoView({block:'center', inline:'center', behavior:'instant'});
                    await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
                    const rect = this.getBoundingClientRect();
                    const x = Math.max(0,rect.left) + (Math.min(innerWidth,rect.right)-Math.max(0,rect.left))/2;
                    const y = Math.max(0,rect.top) + (Math.min(innerHeight,rect.bottom)-Math.max(0,rect.top))/2;
                    const hit = document.elementFromPoint(x,y);
                    if (!rect.width || !rect.height || this.matches(':disabled') || !(hit === this || this.contains(hit))) return {error:'browser_operation_failed'};
                    return {x,y};
                  }
                  """)

                case point["error"] do
                  "stale_element" -> fail("stale_element")
                  "browser_operation_failed" -> false
                  nil -> point
                end
              end)

            {point["x"], point["y"]}
          else
            {Input.number(args["x"], 0, 1280), Input.number(args["y"], 0, 720)}
          end

        Input.click(state, session, x, y)
        result(state, tab, session)

      "fill" ->
        text = Input.text(args["text"], 4096)
        object = reference(state, tab, session, args["ref"])

        ready =
          call_object(
            state,
            session,
            object,
            """
            function(text) {
              if (!this.isConnected) return 'stale_element';
              if (this.matches(':disabled') || this.readOnly || !this.getClientRects().length) return 'browser_operation_failed';
              this.focus();
              if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement) {
                if (this instanceof HTMLInputElement && !['text','search','url','tel','email','password','number'].includes(this.type)) return 'invalid_input';
                if (this.type === 'number') {
                  if (text !== '' && !Number.isFinite(Number(text))) return 'invalid_input';
                }
                this.select();
              } else if (this.isContentEditable) {
                const range = document.createRange(); range.selectNodeContents(this);
                const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
              } else return 'invalid_input';
              return null;
            }
            """,
            %{arguments: [%{value: text}]}
          )

        if ready, do: fail(ready)

        if text == "",
          do: Input.press(state, session, "Backspace"),
          else: cdp(state, "Input.insertText", %{text: text}, session)

        result(state, tab, session)

      "press" ->
        Input.press(state, session, Input.text(args["key"], 128))
        result(state, tab, session)

      "scroll" ->
        Input.dispatch(state, session, %{
          "type" => "mouseWheel",
          "x" => 640,
          "y" => 360,
          "deltaX" => args["x"] || 0,
          "deltaY" => args["y"]
        })

        result(state, tab, session)

      "wait" ->
        text = Input.text(args["text"], 256)
        timeout = Input.integer(args["timeout_ms"] || 5000, 1, 10_000)

        wait_until(timeout, fn ->
          evaluate(state, session, """
          (() => {
            const normalize = value => value.replace(/\\s+/g, ' ').trim();
            const text = normalize(#{Jason.encode!(text)});
            if (!document.body) return false;
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
            let el = document.body, count = 0;
            do {
              if (el.checkVisibility({visibilityProperty:true}) &&
                  normalize((el.innerText || '').slice(0,32000)).includes(text)) return true;
            } while (++count < 10000 && (el = walker.nextNode()));
            return false;
          })()
          """) == true
        end)

        result(state, tab, session)

      "input" ->
        Input.dispatch(state, session, args["input"])
        {%{"accepted" => true}, state}

      "release_keys" ->
        Input.release(state, session)
        {%{"released" => true}, state}

      "stream_start" ->
        viewers = Map.get(state.viewers, tab, MapSet.new())
        if MapSet.size(viewers) >= 32, do: fail("driver_busy")

        if MapSet.size(viewers) == 0 do
          Connection.clear_frame(state.conn, session)

          cdp(
            state,
            "Page.startScreencast",
            %{format: "jpeg", quality: 60, maxWidth: 1280, maxHeight: 720, everyNthFrame: 1},
            session
          )
        end

        viewers = MapSet.put(viewers, args["viewer_id"] || "default")
        {%{"streaming" => true}, %{state | viewers: Map.put(state.viewers, tab, viewers)}}

      "stream_stop" ->
        viewers =
          Map.get(state.viewers, tab, MapSet.new())
          |> MapSet.delete(args["viewer_id"] || "default")

        if MapSet.size(viewers) == 0 do
          cdp(state, "Page.stopScreencast", %{}, session)
          Connection.clear_frame(state.conn, session)
        end

        {%{"streaming" => false}, %{state | viewers: Map.put(state.viewers, tab, viewers)}}

      _ ->
        fail("unsupported_operation")
    end
  end

  defp perform(_, _, _), do: fail("invalid_input")

  def cdp(state, method, params \\ %{}, session \\ nil) do
    case Connection.command(state.conn, method, params, session, state.timeout) do
      {:ok, value} -> value
      {:error, reason} -> fail(reason)
    end
  end

  defp attach(state, tab) do
    if state.tabs[tab] do
      state
    else
      session = cdp(state, "Target.attachToTarget", %{targetId: tab, flatten: true})["sessionId"]
      cdp(state, "Page.enable", %{}, session)
      cdp(state, "Runtime.enable", %{}, session)

      cdp(
        state,
        "Emulation.setDeviceMetricsOverride",
        %{width: 1280, height: 720, deviceScaleFactor: 1, mobile: false},
        session
      )

      %{state | tabs: Map.put(state.tabs, tab, session)}
    end
  end

  defp world(state, session) do
    frame = cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]["id"]

    cdp(state, "Page.createIsolatedWorld", %{frameId: frame, worldName: "salix-browser"}, session)[
      "executionContextId"
    ]
  end

  defp evaluate(state, session, expression, extra \\ %{}) do
    params =
      Map.merge(
        %{
          expression: expression,
          contextId: world(state, session),
          returnByValue: true,
          awaitPromise: true
        },
        extra
      )

    value(cdp(state, "Runtime.evaluate", params, session), params[:returnByValue])
  end

  defp call_object(state, session, object, function, extra \\ %{}) do
    params =
      Map.merge(
        %{
          objectId: object,
          functionDeclaration: function,
          returnByValue: true,
          awaitPromise: true
        },
        extra
      )

    value(cdp(state, "Runtime.callFunctionOn", params, session), params[:returnByValue])
  end

  defp value(%{"exceptionDetails" => _}, _), do: fail("browser_operation_failed")
  defp value(%{"result" => result}, true), do: result["value"]
  defp value(%{"result" => result}, false), do: result["objectId"]

  defp snapshot(state, tab, session) do
    if old = state.refs[tab],
      do: cdp(state, "Runtime.releaseObjectGroup", %{objectGroup: old.group}, session)

    group = Ecto.UUID.generate()
    generation = Connection.generation(state.conn, session)

    array =
      evaluate(
        state,
        session,
        """
        (() => {
          const all = document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]');
          const visible = Array.from(all).slice(0,100).filter(el => el.checkVisibility({visibilityProperty:true}) && el.getBoundingClientRect().width && el.getBoundingClientRect().height);
          visible.truncated = all.length > 100;
          return visible;
        })()
        """,
        %{returnByValue: false, objectGroup: group}
      )

    data =
      call_object(state, session, array, """
      function() { return {url:location.href.slice(0,4096),title:document.title.slice(0,256),
        text:(document.body?.innerText || '').slice(0,32000), truncated:this.truncated,
        elements:this.slice(0,100).map(el => ({tag:el.tagName.toLowerCase(),role:el.getAttribute('role'),
          name:(el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.innerText || '').slice(0,256),type:el.getAttribute('type')}))}; }
      """)

    properties =
      cdp(state, "Runtime.getProperties", %{objectId: array, ownProperties: true}, session)[
        "result"
      ]

    objects =
      Map.new(properties, fn property ->
        {property["name"], get_in(property, ["value", "objectId"])}
      end)

    {elements, refs} =
      data["elements"]
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {element, index}, refs ->
        ref = "e#{group}-#{index}"
        {Map.put(element, "ref", ref), Map.put(refs, ref, objects[to_string(index)])}
      end)

    data = data |> Map.put("tab_id", tab) |> Map.put("elements", elements)

    {data,
     %{
       state
       | refs: Map.put(state.refs, tab, %{group: group, generation: generation, objects: refs})
     }}
  end

  defp reference(state, tab, session, ref) do
    saved = state.refs[tab] || fail("stale_element")
    if saved.generation != Connection.generation(state.conn, session), do: fail("stale_element")
    saved.objects[ref] || fail("stale_element")
  end

  defp result(state, tab, session, refs \\ nil) do
    url = cdp(state, "Page.getFrameTree", %{}, session)["frameTree"]["frame"]["url"]
    {%{"tab_id" => tab, "url" => String.slice(url, 0, 4096)}, %{state | refs: refs || state.refs}}
  end

  defp wait_until(timeout, fun), do: poll(System.monotonic_time(:millisecond) + timeout, fun)

  defp poll(deadline, fun) do
    if value = fun.() do
      value
    else
      if System.monotonic_time(:millisecond) >= deadline, do: fail("browser_operation_failed")
      Process.sleep(100)
      poll(deadline, fun)
    end
  end

  defp fail(reason), do: throw({:browser_error, reason})
end
