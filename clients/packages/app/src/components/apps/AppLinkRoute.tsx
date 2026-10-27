import { useCall, type MiniApp } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { LoadingIndicator } from "@comma/ui/components/LoadingIndicator";
import { MiniAppNotice } from "@comma/ui/components/mini-apps";
import { toast } from "@comma/ui/components/toast";
import { getActiveCommaConfig } from "@comma/config";
import { getNativeBridge } from "@comma/native-bridge";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import { useActiveWorkspaceId } from "../activeWorkspace";
import { useCommaAuth } from "../auth-context";
import { MiniAppFrame } from "./MiniAppFrame";

/**
 * An app opened from its link: it runs here through the link (a guest too), and a registered viewer can add it to
 * their Comma or remix it. A link that does not resolve says so.
 */
export function AppLinkRoute({ token }: { token: string }) {
  const messages = useCommaMessages();
  const call = useCall();
  const navigate = useNavigate();
  const { isGuest = false } = useCommaAuth();
  const workspace = useActiveWorkspaceId(!isGuest);
  const [resolved, setResolved] = useState<
    { status: "loading" } | { status: "ready"; app: MiniApp } | { status: "invalid" }
  >({ status: "loading" });
  const [pending, setPending] = useState<"add" | "remix">();
  const inElectron = getNativeBridge().platform === "electron";

  useEffect(() => {
    let current = true;
    setResolved({ status: "loading" });
    call("miniApps.link.resolve", { token }).then(
      ({ app }) => current && setResolved({ status: "ready", app }),
      () => current && setResolved({ status: "invalid" })
    );
    return () => {
      current = false;
    };
  }, [call, token]);

  const add = async () => {
    if (!workspace) return;
    setPending("add");
    try {
      const app = await call("miniApps.install", { workspace, token });
      toast.success(messages.mini_app_added());
      await navigate({
        to: "/apps/$workspaceId/$appId",
        params: { workspaceId: workspace, appId: app.id },
      });
    } catch {
      toast.error(messages.mini_app_add_failed());
    } finally {
      setPending(undefined);
    }
  };
  const remix = async () => {
    if (!workspace) return;
    setPending("remix");
    try {
      const made = await call("miniApps.remix", { workspace, token });
      await navigate({
        to: "/tasks/$workspaceId/$groupId/$conversationId",
        params: {
          workspaceId: workspace,
          groupId: made.task.group_id,
          conversationId: made.task.conversation_id,
        },
      });
    } catch {
      toast.error(messages.mini_app_remix_failed());
    } finally {
      setPending(undefined);
    }
  };

  if (resolved.status === "loading")
    return (
      <div className="flex flex-1 items-center justify-center">
        <LoadingIndicator label={messages.mini_app_link_loading()} />
      </div>
    );
  if (resolved.status === "invalid")
    return (
      <div className="flex flex-1 flex-col" data-testid="app-link-invalid">
        <MiniAppNotice kind="unavailable" reason={messages.mini_app_link_invalid()} />
      </div>
    );
  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col" data-testid="app-link-route">
      <MiniAppFrame
        appId={resolved.app.id}
        known={{ name: resolved.app.name, author: resolved.app.author.name }}
        trailing={
          <>
            {inElectron ? null : (
              <Button
                hierarchy="tertiary-gray"
                onPress={() =>
                  window.location.assign(
                    `${getActiveCommaConfig().urlScheme}://apps/link/${token}`
                  )
                }
                size="xs"
              >
                {messages.mini_app_open_in_mac()}
              </Button>
            )}
            {!isGuest && workspace ? (
              <>
                <Button
                  hierarchy="secondary-gray"
                  isPending={pending === "remix"}
                  onPress={() => void remix()}
                  size="xs"
                >
                  {messages.mini_app_remix()}
                </Button>
                <Button
                  hierarchy="primary"
                  isPending={pending === "add"}
                  onPress={() => void add()}
                  size="xs"
                >
                  {messages.mini_app_add()}
                </Button>
              </>
            ) : null}
          </>
        }
        variant="flush"
        via={{ token }}
      />
    </div>
  );
}
