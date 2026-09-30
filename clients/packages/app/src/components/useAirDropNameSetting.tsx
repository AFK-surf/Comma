import { useState } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  airDropNameMaxLength,
  defaultAirDropName,
  type AppPreferences,
  type AppPreferencesPatch,
} from "@comma/native-bridge";
import {
  Button,
  ChevronRightSmallIcon,
  Dialog,
  type SettingsPanelItem,
} from "@comma/ui";
import { useCommaAuth } from "./auth-context";

/**
 * The name nearby devices see for Comma in AirDrop, and the dialog that
 * renames it. A cleared name, or the default typed back in, follows the
 * account's name again.
 */
export function useAirDropNameSetting({
  pending,
  preferences,
  update,
}: {
  pending: boolean;
  preferences: AppPreferences | null;
  update: (patch: AppPreferencesPatch) => Promise<void>;
}) {
  const m = useCommaMessages();
  const auth = useCommaAuth();
  const [draft, setDraft] = useState<string>();
  const defaultName = defaultAirDropName({
    email: auth.userEmail,
    name: auth.userDisplayName,
  });
  const savedName = preferences?.airDropName ?? null;
  const currentName = savedName ?? defaultName;
  const typed = (draft ?? "").replace(/\p{Cc}+/gu, " ").trim();
  const tooLong = typed.length > airDropNameMaxLength;
  const nextName = typed && typed !== defaultName ? typed : null;
  const close = () => setDraft(undefined);

  const item: SettingsPanelItem = {
    id: "app.airdrop-name",
    title: m.settings_airdrop_name(),
    description: m.settings_airdrop_name_description(),
    keywords: ["airdrop", "rename", "隔空投送", "名称"],
    control: {
      type: "custom",
      content: (
        <Button
          aria-label={`${m.settings_airdrop_edit_name()}: ${currentName}`}
          className="max-w-72 gap-xs text-quaternary"
          disabled={!preferences || pending}
          hierarchy="link-gray"
          iconTrailing={<ChevronRightSmallIcon className="size-4 shrink-0" />}
          onPress={() => setDraft(currentName)}
          size="sm"
        >
          <span className="max-w-64 truncate">{currentName}</span>
        </Button>
      ),
    },
  };

  return {
    item,
    overlay:
      draft === undefined ? undefined : (
        <Dialog
          actions={[
            {
              label: m.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: close,
            },
            {
              label: m.settings_profile_save(),
              hierarchy: "primary",
              disabled: tooLong || nextName === savedName,
              onPress: () => {
                close();
                void update({ airDropName: nextName });
              },
            },
          ]}
          description={m.settings_airdrop_name_default_hint({ name: defaultName })}
          input={{
            "aria-label": m.settings_airdrop_name(),
            autoFocus: true,
            ...(tooLong ? { errorMessage: m.settings_airdrop_name_too_long() } : {}),
            maxLength: airDropNameMaxLength + 1,
            onChange: (event) => setDraft(event.target.value),
            placeholder: defaultName,
            value: draft,
          }}
          isDismissable
          isOpen
          onOpenChange={(open) => {
            if (!open) close();
          }}
          title={m.settings_airdrop_name()}
          variant="input"
        />
      ),
  };
}
