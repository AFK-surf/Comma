import { useCommaLocale } from "@comma/i18n/react";
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
  Menu,
  MenuItem,
  MenuSeparator,
  ScrollArea,
} from "@comma/ui";
import { useCallback, useEffect, useLayoutEffect, useState } from "react";

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
  const active = state.menu !== null;
  useLayoutEffect(() => {
    if (!active || !ready) return;
    void bridge.sitePermissionMenu
      .act({ action: "present", generation: state.generation })
      .catch(() => {});
  }, [bridge, state.generation, active, ready]);
  return (
    <div className="h-full" data-site-permission-menu-ready={ready ? "true" : "false"}>
      {state.menu && (
        <SitePermissionMenuContent
          key={state.generation}
          snapshot={state.menu}
          generation={state.generation}
        />
      )}
    </div>
  );
}

type WithoutGeneration<T> = T extends unknown ? Omit<T, "generation"> : never;
function SitePermissionMenuContent({
  snapshot,
  generation,
}: {
  snapshot: SitePermissionMenuSnapshot;
  generation: number;
}) {
  const bridge = getNativeBridge();
  const zh = useCommaLocale() === "zh-CN";
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
      className="h-full p-lg"
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) close();
      }}
    >
      <section
        aria-label={zh ? "网站权限" : "Site permissions"}
        className="flex max-h-full flex-col rounded-xl border-[0.5px] border-primary bg-popup-secondary py-sm text-sm text-secondary shadow-lg"
      >
        <h1
          className="truncate px-[calc(var(--spacing-sm)+var(--spacing-md))] py-md text-sm font-medium text-primary"
          title={snapshot?.origin}
        >
          {snapshot?.origin ?? (zh ? "网站权限" : "Site permissions")}
        </h1>
        <ScrollArea
          className="min-h-0"
          edgeEffect="none"
          viewportProps={{ tabIndex: -1 }}
        >
          {snapshot &&
            (device ? (
              <Menu
                key={device}
                aria-label={mediaName(device)}
                variant="embedded"
                // This dedicated menu window is a user-opened focus scope.
                // eslint-disable-next-line jsx-a11y/no-autofocus
                autoFocus="first"
                selectionMode="single"
                selectedKeys={[snapshot.choices[device]]}
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
                      ]
                    : []
                }
              >
                {(["microphone", "camera"] as const).map((type) => (
                  <MenuItem
                    key={type}
                    id={type}
                    textValue={mediaName(type)}
                    shortcut={
                      <span className="flex items-center gap-xs">
                        {choiceName(snapshot.choices[type])}
                        <ChevronRightSmallIcon className="size-4" />
                      </span>
                    }
                    onAction={() => setDevice(type)}
                  >
                    {mediaName(type)}
                  </MenuItem>
                ))}
                <MenuSeparator />
                <MenuItem
                  id="reset"
                  onAction={() => {
                    void act({ action: "reset" });
                  }}
                >
                  {zh ? "重置权限" : "Reset permissions"}
                </MenuItem>
                <MenuItem
                  id="reload"
                  onAction={() => {
                    void act({ action: "reload" });
                  }}
                >
                  {zh ? "重新加载此页面" : "Reload this page"}
                </MenuItem>
                {snapshot.systemSettings && <MenuSeparator />}
                {snapshot.systemSettings &&
                  (["microphone", "camera"] as const).map((type) => (
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
                  ))}
              </Menu>
            ))}
        </ScrollArea>
        <p
          className="px-[calc(var(--spacing-sm)+var(--spacing-md))] py-sm text-xs text-quaternary"
          role={changed ? "status" : undefined}
        >
          {zh
            ? "权限更改后，请重新加载已打开的标签页。"
            : "Reload open tabs to apply permission changes."}
        </p>
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
