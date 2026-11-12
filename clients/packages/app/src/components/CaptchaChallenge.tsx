/* oxlint-disable react/iframe-missing-sandbox -- Turnstile needs scripts and real-origin browser APIs. The core restricts this credential-free frame to its API origin. */
import { useEffect, useRef, useSyncExternalStore } from "react";
import { Dialog } from "@comma/ui/components/dialog";
import { useCommaMessages } from "@comma/i18n/react";
import type { SessionAuthenticatorController } from "../session/controller";

const empty = () => undefined;
const unwatched = () => () => undefined;

/** The core keeps credentials and sequencing. This surface only presents its public challenge. */
export function CaptchaChallenge({
  authenticator,
}: {
  authenticator: SessionAuthenticatorController;
}) {
  const messages = useCommaMessages();
  const source = authenticator.captcha;
  const challenge = useSyncExternalStore(
    source?.subscribe ?? unwatched,
    source?.get ?? empty,
    empty
  );
  const frame = useRef<HTMLIFrameElement>(null);
  useEffect(() => {
    if (!challenge || !source) return;
    const origin = new URL(challenge.url).origin;
    const receive = (event: MessageEvent<unknown>) => {
      if (event.origin !== origin || event.source !== frame.current?.contentWindow)
        return;
      const data = event.data as {
        type?: unknown;
        challengeId?: unknown;
        token?: unknown;
      } | null;
      if (
        !data ||
        data.type !== "comma.captcha" ||
        data.challengeId !== challenge.challengeId ||
        typeof data.token !== "string" ||
        data.token.length === 0 ||
        data.token.length > 2048
      )
        return;
      void source.answer(challenge.challengeId, data.token);
    };
    window.addEventListener("message", receive);
    return () => window.removeEventListener("message", receive);
  }, [challenge, source]);
  if (!challenge || !source) return null;
  const cancel = () => void source.answer(challenge.challengeId, null);
  return (
    <Dialog
      isOpen
      title={messages.auth_captcha_title()}
      onOpenChange={(open) => {
        if (!open) cancel();
      }}
      actions={[
        {
          label: messages.auth_captcha_cancel(),
          hierarchy: "secondary-gray",
          onPress: cancel,
        },
      ]}
    >
      <iframe
        ref={frame}
        src={challenge.url}
        title={messages.auth_captcha_title()}
        className="h-11xl w-full border-0"
        sandbox="allow-scripts allow-same-origin"
        referrerPolicy="no-referrer"
      />
    </Dialog>
  );
}
