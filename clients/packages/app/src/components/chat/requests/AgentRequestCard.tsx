import type {
  AgentLocationRequest,
  AgentOAuthRequest,
  AgentPhoneRequest,
  AgentPluginRequest,
  AgentRequest,
} from "@comma/core-client";
import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import {
  ArrowUpRightIcon,
  ClockIcon,
  CopyIcon,
  EyeIcon,
  GlobeIcon,
  LoadingCircleIcon,
  MapPinIcon,
  PhoneDynamicIslandIcon,
  ReloadIcon,
  SignInKeyIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { uiClock } from "@comma/ui/clock";
import { memo, useEffect, useId, useState } from "react";
import { openNativePlatformExternalUrl } from "../../../nativePlatformActions";
import { location as devicePosition } from "../../apps/miniAppDevices";
import { PluginBrandArtwork } from "../../plugins/PluginBrandArtwork";
import { usePluginInstall } from "../../plugins/pluginInstall";
import { PluginScanDialog } from "../../plugins/PluginScanDialog";
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

/** What the card calls a request: a secret by what the Agent says it is, an account by its provider. */
function requestTitle(
  request: AgentOAuthRequest,
  messages: ReturnType<typeof useCommaMessages>
) {
  if (request.oauth.provider === "cli")
    return messages.agent_request_login_title({ name: request.oauth.alias });
  if (request.oauth.provider !== "secret")
    return messages.agent_request_connect_title({
      name: providerName(request.oauth.provider),
    });
  return messages.agent_request_fill_title({
    name: request.oauth.label ?? request.oauth.alias,
  });
}

/** The brands of the command-line tools people log in to most; others show a plain mark. */
const CLI_BRANDS: Record<string, string> = {
  gh: "github",
  lark: "lark",
  "lark-cli": "lark",
};

function requestMark(request: AgentOAuthRequest) {
  const { provider, alias } = request.oauth;
  if (provider === "secret") return <SignInKeyIcon />;
  if (provider === "cli") {
    const brand = CLI_BRANDS[alias];
    return brand ? <PluginBrandArtwork brand={brand} name={alias} /> : <GlobeIcon />;
  }
  return <PluginBrandArtwork brand={provider} name={providerName(provider)} />;
}

/** A field whose value stays hidden until the person asks to see it. */
function SecretField({
  label,
  placeholder,
  value,
  onChange,
  onEnter,
  disabled,
}: {
  label: string;
  placeholder?: string;
  value: string;
  onChange: (value: string) => void;
  onEnter: () => void;
  disabled: boolean;
}) {
  const messages = useCommaMessages();
  const [shown, setShown] = useState(false);
  return (
    <InputField
      aria-label={label}
      autoComplete="off"
      className="w-full"
      disabled={disabled}
      fieldSize="sm"
      label={label}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={(event) => {
        if (event.key === "Enter") onEnter();
      }}
      placeholder={placeholder}
      trailingIcon={
        <button
          aria-label={messages.agent_request_show_value()}
          aria-pressed={shown}
          className="comma-agent-card-reveal"
          onClick={() => setShown(!shown)}
          type="button"
        >
          <EyeIcon aria-hidden="true" />
        </button>
      }
      type={shown ? "text" : "password"}
      value={value}
    />
  );
}

/**
 * The card while it asks the person to fill something in. What they type stays in this component until they send it
 * to the server, and is not kept after: the card closes into a receipt (a secret) or goes on to the page (an app).
 */
function RequestInputCard({
  request,
  input,
  groupId,
  conversationId,
}: {
  request: AgentOAuthRequest;
  input: Extract<
    NonNullable<AgentOAuthRequest["oauth"]["input"]>,
    { kind: "secret" | "app" | "paste" }
  >;
  groupId: string;
  conversationId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const titleId = useId();
  const [value, setValue] = useState("");
  const [clientId, setClientId] = useState("");
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<"forbidden" | "other" | null>(null);
  const isApp = input.kind === "app";
  const isPaste = input.kind === "paste";
  const [sent, setSent] = useState(false);
  const ready = value.trim() !== "" && (!isApp || clientId.trim() !== "");
  const send = () => {
    if (!ready || busy) return;
    setBusy(true);
    setFailure(null);
    void call("agentRequests.fill", {
      group: groupId,
      conversation: conversationId,
      request: request.id,
      values: isApp
        ? { client_id: clientId.trim(), client_secret: value.trim() }
        : { value },
    })
      .then(() => {
        setValue("");
        if (isPaste) setSent(true);
      })
      .catch((error: unknown) =>
        setFailure(
          (error as { code?: string }).code === "forbidden" ? "forbidden" : "other"
        )
      )
      .finally(() => setBusy(false));
  };
  const decline = () => {
    setBusy(true);
    setFailure(null);
    void call("agentRequests.decline", {
      group: groupId,
      conversation: conversationId,
      request: request.id,
    })
      .catch(() => setFailure("other"))
      .finally(() => setBusy(false));
  };
  const name = input.kind === "secret" ? (input.label ?? request.oauth.alias) : null;

  return (
    <AgentCard state="input" testId="agent-request-card" titleId={titleId}>
      <AgentCardHead
        mark={requestMark(request)}
        reason={request.oauth.reason}
        title={requestTitle(request, messages)}
        titleId={titleId}
      />
      <div className="comma-agent-card-fields">
        {isApp ? (
          <InputField
            aria-label={messages.agent_request_app_id()}
            autoComplete="off"
            className="w-full"
            disabled={busy}
            fieldSize="sm"
            label={messages.agent_request_app_id()}
            onChange={(event) => setClientId(event.target.value)}
            value={clientId}
          />
        ) : null}
        {isPaste ? (
          <InputField
            aria-label={messages.agent_request_login_code()}
            autoComplete="off"
            className="w-full"
            disabled={busy || sent}
            fieldSize="sm"
            label={messages.agent_request_login_code()}
            onChange={(event) => setValue(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") send();
            }}
            placeholder={messages.agent_request_login_code_placeholder()}
            value={value}
          />
        ) : (
          <SecretField
            disabled={busy}
            label={isApp ? messages.agent_request_app_secret() : (name ?? "")}
            onChange={setValue}
            onEnter={send}
            value={value}
            {...(isApp
              ? {}
              : { placeholder: messages.agent_request_paste({ name: name ?? "" }) })}
          />
        )}
        {isPaste && request.oauth.authorizationUrl ? (
          <a
            className="comma-agent-card-link"
            href={request.oauth.authorizationUrl}
            onClick={(event) => {
              event.preventDefault();
              void openNativePlatformExternalUrl(
                request.oauth.authorizationUrl as string
              );
            }}
          >
            {messages.agent_request_login_open()}
            <ArrowUpRightIcon aria-hidden="true" />
          </a>
        ) : null}
        {"helpUrl" in input && input.helpUrl ? (
          <a
            className="comma-agent-card-link"
            href={input.helpUrl}
            onClick={(event) => {
              event.preventDefault();
              void openNativePlatformExternalUrl(input.helpUrl as string);
            }}
          >
            {isApp
              ? messages.agent_request_app_help({
                  name: providerName(request.oauth.provider),
                })
              : messages.agent_request_value_help()}
            <ArrowUpRightIcon aria-hidden="true" />
          </a>
        ) : null}
      </div>
      {input.kind === "app" && input.redirectUri ? (
        <dl className="comma-agent-card-detail">
          <dt>{messages.agent_request_redirect_url()}</dt>
          <dd>{input.redirectUri}</dd>
        </dl>
      ) : null}
      <output className="comma-agent-card-note">
        {failure === "forbidden"
          ? isApp
            ? messages.agent_request_owner_only()
            : messages.agent_request_not_yours()
          : failure === "other"
            ? messages.agent_request_fill_failed()
            : isPaste
              ? messages.agent_request_browser_hint()
              : messages.agent_request_fill_hint()}
      </output>
      <AgentCardFoot
        lead={
          sent ? (
            <output className="comma-agent-card-status">
              <LoadingCircleIcon
                aria-hidden="true"
                className="motion-safe:animate-spin"
              />
              {messages.agent_request_login_checking()}
            </output>
          ) : null
        }
        actions={
          <>
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy}
              onPress={decline}
              size="xs"
            >
              {messages.agent_request_decline()}
            </Button>
            <Button
              hierarchy="primary"
              isDisabled={!ready || busy || sent}
              onPress={send}
              size="xs"
            >
              {isPaste
                ? messages.agent_request_login_submit()
                : isApp
                  ? messages.agent_request_next()
                  : messages.agent_request_save()}
            </Button>
          </>
        }
      />
    </AgentCard>
  );
}

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
  return request.type === "location" ? (
    <LocationRequestCard
      conversationId={conversationId}
      groupId={groupId}
      request={request}
    />
  ) : request.type === "plugin_install" ? (
    <PluginRequestCard
      conversationId={conversationId}
      groupId={groupId}
      request={request}
    />
  ) : request.type === "computer_use_start" ? (
    <PhoneRequestCard
      conversationId={conversationId}
      groupId={groupId}
      request={request}
    />
  ) : (
    <AccountRequestCard
      conversationId={conversationId}
      groupId={groupId}
      request={request}
    />
  );
});

/**
 * A request for this device's position. Sharing asks the system first, sends the position once, and the card becomes
 * the receipt the server answers with; the receipt never shows the coordinates.
 */
function LocationRequestCard({
  request,
  groupId,
  conversationId,
}: {
  request: AgentLocationRequest;
  groupId: string;
  conversationId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const titleId = useId();
  const pending = request.status === "pending";
  const seconds = useSecondsLeft(request.expiresAt, pending);
  const [busy, setBusy] = useState<"locating" | "declining" | null>(null);
  const [note, setNote] = useState<
    "denied" | "unavailable" | "failed" | "decline_failed" | null
  >(null);
  const title = messages.agent_request_location_title();

  const expired = request.status === "expired" || (pending && seconds === 0);
  if (!pending || expired) {
    if (request.status === "completed" && request.outcome === "shared")
      return (
        <AgentReceipt
          about={title}
          label={title}
          outcome={messages.agent_request_location_shared()}
        />
      );
    if (request.status === "completed" && request.outcome === "declined")
      return (
        <AgentReceipt
          about={title}
          icon={<XIcon aria-hidden="true" />}
          label={title}
          muted
          outcome={messages.agent_request_location_declined()}
          testId="agent-request-receipt"
        />
      );
    if (expired)
      return (
        <AgentReceipt
          about={title}
          icon={<ClockIcon aria-hidden="true" />}
          label={title}
          muted
          note={messages.agent_request_location_expired_note()}
          outcome={messages.agent_request_expired()}
          testId="agent-request-receipt"
        />
      );
    return (
      <AgentReceipt
        about={title}
        icon={<ReloadIcon aria-hidden="true" />}
        label={title}
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

  const where = { group: groupId, conversation: conversationId, request: request.id };
  const share = () => {
    setBusy("locating");
    setNote(null);
    void devicePosition()
      .then((position) => {
        if (!position.ok) {
          setNote(position.code === "denied" ? "denied" : "unavailable");
          return;
        }
        const { latitude, longitude, accuracy } = position.value as {
          latitude: number;
          longitude: number;
          accuracy: number;
        };
        return call("agentRequests.shareLocation", {
          ...where,
          latitude,
          longitude,
          accuracy,
        }).catch(() => setNote("failed"));
      })
      .finally(() => setBusy(null));
  };
  const decline = () => {
    setBusy("declining");
    setNote(null);
    void call("agentRequests.decline", where)
      .catch(() => setNote("decline_failed"))
      .finally(() => setBusy(null));
  };
  const soon = seconds !== null && seconds <= 30;

  return (
    <AgentCard state="pending" testId="agent-request-card" titleId={titleId}>
      <AgentCardHead
        mark={<MapPinIcon />}
        reason={request.location.reason}
        title={title}
        titleId={titleId}
      />
      <output className="comma-agent-card-note">
        {note === "denied"
          ? messages.agent_request_location_denied()
          : note === "unavailable"
            ? messages.agent_request_location_unavailable()
            : note === "failed"
              ? messages.agent_request_location_failed()
              : note === "decline_failed"
                ? messages.agent_request_decline_failed()
                : ""}
      </output>
      <AgentCardFoot
        actions={
          <>
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy !== null}
              onPress={decline}
              size="xs"
            >
              {messages.agent_request_decline()}
            </Button>
            <Button
              hierarchy="primary"
              isDisabled={busy !== null}
              onPress={share}
              size="xs"
            >
              {messages.agent_request_location_share()}
            </Button>
          </>
        }
        lead={
          busy === "locating" ? (
            <output className="comma-agent-card-status">
              <LoadingCircleIcon
                aria-hidden="true"
                className="motion-safe:animate-spin"
              />
              {messages.agent_request_location_locating()}
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
}

/** A request to connect an account or fill in a credential. */
function AccountRequestCard({
  request,
  groupId,
  conversationId,
}: {
  request: AgentOAuthRequest;
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
    const about = requestTitle(request, messages);
    if (request.status === "completed" && request.outcome === "connected")
      return (
        <AgentReceipt
          about={about}
          label={about}
          note={request.oauth.account}
          outcome={
            request.oauth.provider === "secret"
              ? messages.agent_request_saved()
              : request.oauth.provider === "cli"
                ? messages.agent_request_logged_in()
                : messages.agent_request_connected({ name })
          }
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

  const input = request.oauth.input;
  if (input && input.kind !== "device" && input.kind !== "open")
    return (
      <RequestInputCard
        conversationId={conversationId}
        groupId={groupId}
        input={input}
        request={request}
      />
    );

  const url = request.oauth.authorizationUrl;
  const authorize = () => {
    if (!url) return;
    if (input?.kind === "device") void navigator.clipboard?.writeText(input.code);
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
  // A secret with no input on the card is filled in on Comma's own form, not authorized at a provider.
  const form = request.oauth.provider === "secret";
  const account =
    request.oauth.alias !== request.oauth.provider ? request.oauth.alias : null;

  return (
    <AgentCard
      state={opened ? "browser" : "pending"}
      testId="agent-request-card"
      titleId={titleId}
    >
      <AgentCardHead
        mark={requestMark(request)}
        reason={request.oauth.reason}
        title={requestTitle(request, messages)}
        titleId={titleId}
      />
      {input?.kind === "device" ? (
        <div className="comma-agent-card-code">{input.code}</div>
      ) : null}
      {request.oauth.provider !== "cli" &&
      (account || request.oauth.scopes.length > 0) ? (
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
            : form
              ? messages.agent_request_form_hint()
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
              {...(input?.kind === "device" && !opened
                ? { iconLeading: <CopyIcon /> }
                : { iconTrailing: <ArrowUpRightIcon /> })}
              isDisabled={!url}
              onPress={authorize}
              size="xs"
            >
              {opened
                ? messages.agent_request_reopen()
                : input?.kind === "device"
                  ? messages.agent_request_login_copy_open()
                  : form
                    ? messages.agent_request_open_form()
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
              {form
                ? messages.agent_request_waiting_form()
                : messages.agent_request_waiting_browser()}
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
}

/**
 * An Agent asks to use a person's phone in this conversation. Only the owner of the computer the phone is on can
 * answer; the server refuses anyone else, and the card says so.
 */
function PhoneRequestCard({
  request,
  groupId,
  conversationId,
}: {
  request: AgentPhoneRequest;
  groupId: string;
  conversationId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const titleId = useId();
  const pending = request.status === "pending";
  const seconds = useSecondsLeft(request.expiresAt, pending);
  const [busy, setBusy] = useState(false);
  const [failure, setFailure] = useState<"forbidden" | "other" | null>(null);
  const phone = request.phone.title || request.phone.target;
  const about = messages.agent_request_phone_title({ phone });
  // (the same card asks for a computer's iOS Simulator: env.screen)
  const simulator = request.phone.target.startsWith("simulator:");
  const expired = request.status === "expired" || (pending && seconds === 0);
  if (!pending || expired) {
    if (request.status === "completed" && request.outcome === "allowed")
      return (
        <AgentReceipt
          about={about}
          label={about}
          outcome={messages.agent_request_phone_allowed()}
          testId="agent-request-receipt"
        />
      );
    return (
      <AgentReceipt
        about={about}
        icon={expired ? <ClockIcon aria-hidden="true" /> : <XIcon aria-hidden="true" />}
        label={about}
        muted
        outcome={
          expired
            ? messages.agent_request_expired()
            : request.outcome === "denied"
              ? messages.agent_request_phone_denied()
              : messages.agent_request_failed()
        }
        testId="agent-request-receipt"
      />
    );
  }
  const decide = (approved: boolean) => {
    setBusy(true);
    setFailure(null);
    void call("agentRequests.decide", {
      group: groupId,
      conversation: conversationId,
      request: request.id,
      approved,
    })
      .catch((error: unknown) =>
        setFailure(
          (error as { code?: string }).code === "forbidden" ? "forbidden" : "other"
        )
      )
      .finally(() => setBusy(false));
  };
  const soon = seconds !== null && seconds <= 30;
  return (
    <AgentCard state="pending" testId="agent-request-card" titleId={titleId}>
      <AgentCardHead
        mark={<PhoneDynamicIslandIcon />}
        reason={
          simulator
            ? messages.agent_request_simulator_body()
            : messages.agent_request_phone_body()
        }
        title={about}
        titleId={titleId}
      />
      <output className="comma-agent-card-note">
        {failure === "forbidden"
          ? simulator
            ? messages.agent_request_simulator_owner_only()
            : messages.agent_request_phone_owner_only()
          : failure === "other"
            ? messages.agent_request_phone_failed()
            : simulator
              ? messages.agent_request_simulator_hint()
              : messages.agent_request_phone_hint()}
      </output>
      <AgentCardFoot
        actions={
          <>
            <Button
              hierarchy="secondary-gray"
              isDisabled={busy}
              onPress={() => decide(false)}
              size="xs"
            >
              {messages.agent_request_phone_deny()}
            </Button>
            <Button
              hierarchy="primary"
              isDisabled={busy}
              onPress={() => decide(true)}
              size="xs"
            >
              {messages.agent_request_phone_allow()}
            </Button>
          </>
        }
        lead={
          seconds !== null ? (
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
}

/**
 * A Router asks to install a plugin. Adding it is the Plugins page's install (its browser authorization, key dialog or
 * scan included); the server ends the request once the plugin is installed, by this card or anywhere else.
 */
function PluginRequestCard({
  request,
  groupId,
  conversationId,
}: {
  request: AgentPluginRequest;
  groupId: string;
  conversationId: string;
}) {
  const messages = useCommaMessages();
  const call = useCall();
  const installation = usePluginInstall();
  const titleId = useId();
  const { id: pluginId, name, workspace } = request.plugin;
  const pending = request.status === "pending";
  const seconds = useSecondsLeft(request.expiresAt, pending);
  // A scan outlives the request: a new Lark/Feishu install is installed (which ends the request) before the member's
  // own sign-in, its second code, so the card follows the plugin until the scan is over.
  const [scanning, setScanning] = useState(false);
  const { value: catalog } = useTopic(
    pending || scanning ? { topic: "plugins", workspace } : null
  );
  const row =
    catalog?.status === "ready" && catalog.workspace === workspace
      ? catalog.plugins.find((plugin) => plugin.id === pluginId)
      : undefined;
  const activity = row?.activity ?? "idle";
  const scan = activity === "scanning" ? row?.scan : undefined;
  if (scanning !== (scan !== undefined)) setScanning(scan !== undefined);
  const [declining, setDeclining] = useState(false);
  const [declineFailed, setDeclineFailed] = useState(false);
  const title = messages.agent_request_plugin_title({ name });
  const mark = (
    <PluginBrandArtwork
      brand={request.plugin.brand ?? row?.brand ?? pluginId}
      name={name}
    />
  );

  // An install by a scan (Lark, Feishu) shows its code until the member confirms.
  const scanDialog = scan ? (
    <PluginScanDialog
      name={name}
      onCancel={() => installation.cancel({ pluginId, workspaceId: workspace })}
      step={scan.step}
      url={scan.url}
    />
  ) : null;

  const expired = request.status === "expired" || (pending && seconds === 0);
  if (!pending || expired)
    return (
      <>
        <PluginRequestReceipt
          expired={expired}
          name={name}
          request={request}
          title={title}
        />
        {scanDialog}
      </>
    );

  // As on the Plugins page, an authorization waiting on the browser can be started again.
  const browser = activity === "authorizing";
  const busy = (activity !== "idle" && !browser) || declining;
  const add = () => void installation.install({ pluginId, workspaceId: workspace });
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

  return (
    <AgentCard
      state={browser ? "browser" : "pending"}
      testId="agent-request-card"
      titleId={titleId}
    >
      <AgentCardHead
        mark={mark}
        reason={request.plugin.reason}
        title={title}
        titleId={titleId}
      />
      <output className="comma-agent-card-note">
        {declineFailed ? messages.agent_request_decline_failed() : ""}
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
              hierarchy={browser ? "secondary-gray" : "primary"}
              isDisabled={busy}
              onPress={add}
              size="xs"
            >
              {browser
                ? messages.agent_request_reopen()
                : messages.plugins_add_to_comma()}
            </Button>
          </>
        }
        lead={
          activity === "authorizing" || activity === "verifying" ? (
            <output className="comma-agent-card-status">
              <LoadingCircleIcon
                aria-hidden="true"
                className="motion-safe:animate-spin"
              />
              {messages.agent_request_waiting_browser()}
            </output>
          ) : activity === "installing" || activity === "scanning" ? (
            <output className="comma-agent-card-status">
              <LoadingCircleIcon
                aria-hidden="true"
                className="motion-safe:animate-spin"
              />
              {messages.agent_request_plugin_installing()}
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
      {scanDialog}
    </AgentCard>
  );
}

/** How a Router's plugin install request ended. */
function PluginRequestReceipt({
  request,
  name,
  title,
  expired,
}: {
  request: AgentPluginRequest;
  name: string;
  title: string;
  expired: boolean;
}) {
  const messages = useCommaMessages();
  if (request.status === "completed" && request.outcome === "installed")
    return (
      <AgentReceipt
        about={title}
        label={title}
        outcome={messages.agent_request_plugin_installed({ name })}
        testId="agent-request-receipt"
      />
    );
  if (request.status === "completed" && request.outcome === "declined")
    return (
      <AgentReceipt
        about={title}
        icon={<XIcon aria-hidden="true" />}
        label={title}
        muted
        outcome={messages.agent_request_plugin_declined({ name })}
        testId="agent-request-receipt"
      />
    );
  if (expired)
    return (
      <AgentReceipt
        about={title}
        icon={<ClockIcon aria-hidden="true" />}
        label={title}
        muted
        note={messages.agent_request_plugin_expired_note()}
        outcome={messages.agent_request_expired()}
        testId="agent-request-receipt"
      />
    );
  return (
    <AgentReceipt
      about={title}
      icon={<ReloadIcon aria-hidden="true" />}
      label={title}
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
