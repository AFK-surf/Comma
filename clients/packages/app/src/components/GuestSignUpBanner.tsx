import { useCommaMessages } from "@comma/i18n/react";
import { Button, toast } from "@comma/ui";
import { useState } from "react";
import { useCommaAuth } from "./auth-context";

/**
 * The guest Session's persistent sign-up prompt. It sits in the window bar's
 * centre slot, so it stays visible on every surface a guest can reach.
 */
export function GuestSignUpBanner() {
  const messages = useCommaMessages();
  const { beginGuestSignUp } = useCommaAuth();
  const [pending, setPending] = useState(false);

  const signUp = () => {
    if (!beginGuestSignUp || pending) return;
    setPending(true);
    void beginGuestSignUp()
      .catch((error: unknown) => {
        toast.error(error instanceof Error ? error.message : String(error));
      })
      .finally(() => setPending(false));
  };

  return (
    <div
      className="comma-window-bar-search-slot flex min-w-0 items-center justify-center px-md"
      data-testid="comma-guest-banner"
    >
      <div className="flex min-w-0 max-w-full items-center gap-md rounded-full border-[0.5px] border-primary bg-main-panel-bg px-md py-xs text-xs text-secondary shadow-xs">
        <span className="truncate">{messages.guest_banner_message()}</span>
        <Button
          className="shrink-0"
          disabled={!beginGuestSignUp}
          hierarchy="link-color"
          isPending={pending}
          onPress={signUp}
          size="sm"
        >
          {messages.guest_banner_sign_up()}
        </Button>
      </div>
    </div>
  );
}
