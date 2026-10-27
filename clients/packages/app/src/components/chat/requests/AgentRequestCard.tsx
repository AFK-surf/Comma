import type { AgentRequest } from "@comma/core-client";
import { useCall } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import {
  ArrowUpRightIcon,
  ClockIcon,
  LoadingCircleIcon,
  ReloadIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { uiClock } from "@comma/ui/clock";
import { memo, useEffect, useId, useState } from "react";
import { openNativePlatformExternalUrl } from "../../../nativePlatformActions";
import { PluginBrandArtwork } from "../../plugins/PluginBrandArtwork";
import {
  AgentCard,
  AgentCardFoot,
  AgentCardHead,
  AgentReceipt,
} from "../agent-card/AgentCard";

/** The account names the cards show for the providers an Agent connects; others show their id, capitalized. */
const PROVIDER_NAMES: Record<string, string> = {
  github: "GitHub",
  google: "Google",
  linear: "Linear",
  notion: "Notion",
  slack: "Slack",
  feishu: "Feishu",
};

export function providerName(provider: string): string {
  return (
    PROVIDER_NAMES[provider] ?? provider.charAt(0).toUpperCase() + provider.slice(1)
  );
}

/** The time left before `expiresAt`, in seconds, counting down once a second while there is some. */
function useSecondsLeft(expiresAt: number | null, pending: boolean): number | null {
  const left = () =>
    expiresAt === null
      ? null
      : Math.max(0, Math.ceil((expiresAt - uiClock.now()) / 1000));
  const [seconds, setSeconds] = useState(left);
  useEffect(() => {
    setSeconds(left());
    if (!pending || expiresAt === null) return;
    const stop = uiClock.every(1000, () => {
      const next = left();
      setSeconds(next);
      if (next === 0) stop();
    });
    return stop;
    // `left` reads only `expiresAt`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expiresAt, pending]);
  return seconds;
}

const clock = (seconds: number) =>
  `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;

/**
 * An Agent's request to the person, as a card in the conversation (the Agent cards' shell). The server decides how it
 * ends; the card shows what it says, so every device shows the same ending. Connecting an account opens the
 * provider's page in the browser; the provider's verified answer ends the request, and the card becomes its receipt.
 */
export const AgentRequestCard = memo(function AgentRequestCard({
  request,
  groupId,
  conversationId,
}: {
  request: AgentRequest;
  groupId: string;
  conversationId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const titleId = useId();
  const name = providerName(request.oauth.provider);
  const pending = request.status === "pending";
  const seconds = useSecondsLeft(request.expiresAt, pending);
  // The page was opened here: the card waits for the browser.
  const [opened, setOpened] = useState(false);
  const [declining, setDeclining] = useState(false);
  const [declineFailed, setDeclineFailed] = useState(false);

  // A deadline that passed ends the request, though the server settles it only when it is next read.
  const expired = request.status === "expired" || (pending && seconds === 0);
  if (!pending || expired) {
    const about = messages.agent_request_connect_title({ name });
    if (request.status === "completed" && request.outcome === "connected")
      return (
        <AgentReceipt
          about={about}
          label={about}
          note={request.oauth.account}
          outcome={messages.agent_request_connected({ name })}
          testId="agent-request-receipt"
        />
      );
    if (request.status === "completed" && request.outcome === "declined")
      return (
        <AgentReceipt
          about={about}
          icon={<XIcon aria-hidden="true" />}
          label={about}
          muted
          outcome={messages.agent_request_declined({ name })}
          testId="agent-request-receipt"
        />
      );
    if (expired)
      return (
        <AgentReceipt
          about={about}
          icon={<ClockIcon aria-hidden="true" />}
          label={about}
          muted
          note={messages.agent_request_expired_note()}
          outcome={messages.agent_request_expired()}
          testId="agent-request-receipt"
        />
      );
    return (
      <AgentReceipt
        about={about}
        icon={<ReloadIcon aria-hidden="true" />}
        label={about}
        muted
        outcome={
          request.status === "cancelled"
            ? messages.agent_request_cancelled()
            : messages.agent_request_failed()
        }
        testId="agent-request-receipt"
      />
    );
  }

  const url = request.oauth.authorizationUrl;
  const authorize = () => {
    if (!url) return;
    setOpened(true);
    void openNativePlatformExternalUrl(url).catch(() => setOpened(false));
  };
  const decline = () => {
    setDeclining(true);
    setDeclineFailed(false);
    void call("agentRequests.decline", {
      group: groupId,
      conversation: conversationId,
      request: request.id,
    })
      .catch(() => setDeclineFailed(true))
      .finally(() => setDeclining(false));
  };
  const soon = seconds !== null && seconds <= 30;
  const account =
    request.oauth.alias !== request.oauth.provider ? request.oauth.alias : null;

  return (
    <AgentCard
      state={opened ? "browser" : "pending"}
      testId="agent-request-card"
      titleId={titleId}
    >
      <AgentCardHead
        mark={<PluginBrandArtwork brand={request.oauth.provider} name={name} />}
        reason={request.oauth.reason}
        title={messages.agent_request_connect_title({ name })}
        titleId={titleId}
      />
      {account || request.oauth.scopes.length > 0 ? (
        <dl className="comma-agent-card-detail">
          {account ? (
            <>
              <dt>{messages.agent_request_account()}</dt>
              <dd>{account}</dd>
            </>
          ) : null}
          {request.oauth.scopes.length > 0 ? (
            <>
              <dt>{messages.agent_request_access()}</dt>
              <dd>{request.oauth.scopes.join(", ")}</dd>
            </>
          ) : null}
        </dl>
      ) : null}
      <output className="comma-agent-card-note">
        {declineFailed
          ? messages.agent_request_decline_failed()
          : opened
            ? ""
            : messages.agent_request_browser_hint()}
      </output>
      <AgentCardFoot
        actions={
          <>
            <Button
              hierarchy="secondary-gray"
              isDisabled={declining}
              onPress={decline}
              size="xs"
            >
              {messages.agent_request_decline()}
            </Button>
            <Button
              hierarchy={opened ? "secondary-gray" : "primary"}
              iconTrailing={<ArrowUpRightIcon />}
              isDisabled={!url}
              onPress={authorize}
              size="xs"
            >
              {opened
                ? messages.agent_request_reopen()
                : messages.agent_request_authorize()}
            </Button>
          </>
        }
        lead={
          opened ? (
            <output className="comma-agent-card-status">
              <LoadingCircleIcon
                aria-hidden="true"
                className="motion-safe:animate-spin"
              />
              {messages.agent_request_waiting_browser()}
            </output>
          ) : seconds !== null ? (
            <span
              className="comma-agent-card-time"
              data-soon={soon ? "" : undefined}
              role="timer"
            >
              {soon
                ? messages.agent_request_expires_soon({ time: clock(seconds) })
                : messages.agent_request_expires_in({ time: clock(seconds) })}
            </span>
          ) : null
        }
      />
    </AgentCard>
  );
});
