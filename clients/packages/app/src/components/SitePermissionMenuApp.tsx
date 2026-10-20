import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  getNativeBridge,
  emptySitePermissionMenuState,
  type SitePermissionMenuState,
  type SitePermissionMenuAction,
  type SitePermissionMenuSnapshot,
} from "@comma/native-bridge";
import {
  ArrowLeftIcon,
  ChevronRightSmallIcon,
  GlobeIcon,
  SignInKeyIcon,
} from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuSeparator } from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

/** The content of a single preloaded native child window. */
export function SitePermissionMenuApp() {
  const bridge = getNativeBridge();
  const [state, setState] = useState(emptySitePermissionMenuState);
  const [ready, setReady] = useState(false);
  useEffect(() => {
    let disposed = false;
    const apply = (value: SitePermissionMenuState) => {
      if (!disposed)
        setState((previous) =>
          value.revision >= previous.revision ? value : previous
        );
    };
    const unsubscribe = bridge.sitePermissionMenu.state.subscribe(apply);
    void bridge.sitePermissionMenu.state
      .get()
      .then((value) => {
        apply(value);
        if (!disposed) setReady(true);
      })
      .catch(() => {});
    return () => {
      disposed = true;
      unsubscribe();
    };
  }, [bridge]);
  return (
    <div className="h-full" data-site-permission-menu-ready={ready ? "true" : "false"}>
      {state.menu && (
        <SitePermissionMenuContent
          key={state.generation}
          snapshot={state.menu}
          generation={state.generation}
          ready={ready}
        />
      )}
    </div>
  );
}

type WithoutGeneration<T> = T extends unknown ? Omit<T, "generation"> : never;
/** The menu's full height, including what the window currently clips of its list. */
function menuHeight(root: HTMLElement) {
  const section = root.firstElementChild as HTMLElement | null;
  const area = root.querySelector<HTMLElement>('[data-slot="scroll-area"]');
  const list = root.querySelector<HTMLElement>('[data-slot="scroll-area-content"]');
  if (!section || !area || !list) return 0;
  const style = getComputedStyle(root);
  // The list keeps its own height; only the scroll area around it is clamped.
  return Math.ceil(
    (parseFloat(style.paddingTop) || 0) +
      (parseFloat(style.paddingBottom) || 0) +
      section.offsetHeight -
      area.offsetHeight +
      list.offsetHeight
  );
}

function SitePermissionMenuContent({
  snapshot,
  generation,
  ready,
}: {
  snapshot: SitePermissionMenuSnapshot;
  generation: number;
  ready: boolean;
}) {
  const bridge = getNativeBridge();
  const messages = useCommaMessages();
  const zh = useCommaLocale() === "zh-CN";
  const site = snapshot.site;
  const [device, setDevice] = useState<"microphone" | "camera">();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const [changed, setChanged] = useState(false);
  const mediaName = (type: "microphone" | "camera") =>
    type === "microphone" ? (zh ? "麦克风" : "Microphone") : zh ? "摄像头" : "Camera";
  const choiceName = (choice: "ask" | "allow" | "block") =>
    ({
      ask: zh ? "询问" : "Ask",
      allow: zh ? "允许" : "Allow",
      block: zh ? "阻止" : "Block",
    })[choice];
  const rootRef = useRef<HTMLDivElement>(null);
  // Presents this generation once its menu is committed, then keeps the native
  // window as tall as the menu so no transparent area covers the page.
  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!ready || !root) return;
    let presented: number | undefined;
    const present = () => {
      const height = menuHeight(root);
      if (height === presented) return;
      presented = height;
      void bridge.sitePermissionMenu
        .act({ action: "present", generation, height })
        .catch(() => {});
    };
    present();
    const observer = new ResizeObserver(present);
    const section = root.firstElementChild;
    const content = root.querySelector('[data-slot="scroll-area-content"]');
    if (section) observer.observe(section);
    if (content) observer.observe(content);
    return () => observer.disconnect();
  }, [bridge, generation, ready]);
  const close = useCallback(() => {
    void bridge.sitePermissionMenu.act({ action: "close", generation }).catch(() => {});
  }, [bridge, generation]);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        event.preventDefault();
        close();
      }
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [close]);
  const act = async (action: WithoutGeneration<SitePermissionMenuAction>) => {
    if (busy) return;
    setBusy(true);
    setError(undefined);
    try {
      await bridge.sitePermissionMenu.act({ ...action, generation });
      if (action.action === "change" || action.action === "reset") {
        setChanged(true);
        setDevice(undefined);
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div
      ref={rootRef}
      className="h-full p-lg"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) close();
      }}
    >
      <section
        aria-label={zh ? "网站权限" : "Site permissions"}
        className="flex max-h-full flex-col rounded-xl border-[0.5px] border-primary bg-popup-secondary py-sm text-sm text-secondary shadow-lg"
      >
        {site ? (
          <header className="px-[calc(var(--spacing-sm)+var(--spacing-md))] pt-sm pb-xs">
            <h1
              className="truncate text-xs font-medium text-quaternary"
              title={site.origin}
            >
              {zh ? "此网站" : "This site"}
            </h1>
            <p
              className="truncate text-sm font-medium text-primary"
              title={site.origin}
            >
              {site.origin}
            </p>
            <p
              className="text-micro text-quaternary"
              role={changed ? "status" : undefined}
            >
              {zh
                ? "权限更改后，请重新加载已打开的标签页。"
                : "Reload open tabs to apply permission changes."}
            </p>
          </header>
        ) : null}
        <ScrollArea
          className="min-h-0"
          edgeEffect="none"
          viewportProps={{ tabIndex: -1 }}
        >
          {snapshot &&
            (device && site ? (
              <Menu
                key={device}
                aria-label={mediaName(device)}
                variant="embedded"
                // This dedicated menu window is a user-opened focus scope.
                // eslint-disable-next-line jsx-a11y/no-autofocus
                autoFocus="first"
                selectionMode="single"
                selectedKeys={[site.choices[device]]}
                disabledKeys={busy ? ["ask", "allow", "block"] : []}
              >
                <MenuItem
                  id="back"
                  icon={<ArrowLeftIcon />}
                  onAction={() => setDevice(undefined)}
                >
                  {zh ? "返回" : "Back"}
                </MenuItem>
                <MenuSeparator />
                {(["ask", "allow", "block"] as const).map((value) => (
                  <MenuItem
                    key={value}
                    id={value}
                    selectionIndicator="check"
                    onAction={() => {
                      void act({ action: "change", media: device, value });
                    }}
                  >
                    {choiceName(value)}
                  </MenuItem>
                ))}
              </Menu>
            ) : (
              <Menu
                aria-label={zh ? "网站权限" : "Site permissions"}
                variant="embedded"
                // This dedicated menu window is a user-opened focus scope.
                // eslint-disable-next-line jsx-a11y/no-autofocus
                autoFocus="first"
                disabledKeys={
                  busy
                    ? [
                        "microphone",
                        "camera",
                        "reset",
                        "reload",
                        "system-microphone",
                        "system-camera",
                        "import-sign-ins",
                        "open-external",
                      ]
                    : []
                }
              >
                {site
                  ? (["microphone", "camera"] as const).map((type) => (
                      <MenuItem
                        key={type}
                        id={type}
                        textValue={mediaName(type)}
                        shortcut={
                          <span className="flex items-center gap-xs">
                            {choiceName(site.choices[type])}
                            <ChevronRightSmallIcon className="size-4" />
                          </span>
                        }
                        onAction={() => setDevice(type)}
                      >
                        {mediaName(type)}
                      </MenuItem>
                    ))
                  : null}
                {site ? <MenuSeparator /> : null}
                {site ? (
                  <MenuItem
                    id="reset"
                    onAction={() => {
                      void act({ action: "reset" });
                    }}
                  >
                    {zh ? "重置权限" : "Reset permissions"}
                  </MenuItem>
                ) : null}
                {site ? (
                  <MenuItem
                    id="reload"
                    onAction={() => {
                      void act({ action: "reload" });
                    }}
                  >
                    {zh ? "重新加载此页面" : "Reload this page"}
                  </MenuItem>
                ) : null}
                {site && snapshot.systemSettings ? <MenuSeparator /> : null}
                {site && snapshot.systemSettings
                  ? (["microphone", "camera"] as const).map((type) => (
                      <MenuItem
                        key={`system-${type}`}
                        id={`system-${type}`}
                        onAction={() => {
                          void act({ action: "system-settings", media: type });
                        }}
                      >
                        {zh
                          ? `系统${mediaName(type)}设置…`
                          : `System ${mediaName(type).toLowerCase()} settings…`}
                      </MenuItem>
                    ))
                  : null}
                {site ? <MenuSeparator /> : null}
                <MenuItem
                  icon={<SignInKeyIcon />}
                  id="import-sign-ins"
                  onAction={() => {
                    void act({ action: "pick", item: "import-sign-ins" });
                  }}
                >
                  {messages.browser_import_sign_ins()}
                </MenuItem>
                <MenuItem
                  icon={<GlobeIcon />}
                  id="open-external"
                  onAction={() => {
                    void act({ action: "pick", item: "open-external" });
                  }}
                >
                  {messages.chat_open_in_default_browser()}
                </MenuItem>
              </Menu>
            ))}
        </ScrollArea>
        {error && (
          <p
            role="alert"
            className="px-[calc(var(--spacing-sm)+var(--spacing-md))] py-sm text-xs text-error-primary"
          >
            {error}
          </p>
        )}
      </section>
    </div>
  );
}
