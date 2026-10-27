import type { MiniAppVisibility } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { ChoiceList } from "@comma/ui/components/choice-list";
import { useId } from "react";

/** Who can open an app: only its owner's members, the Workspace, or anyone with its link. */
export function MiniAppVisibilityPicker({
  value,
  onChange,
  disabled,
}: {
  value: MiniAppVisibility;
  onChange: (next: MiniAppVisibility) => void;
  disabled?: boolean;
}) {
  const messages = useCommaMessages();
  const labelId = useId();
  return (
    <div className="flex w-full flex-col gap-xs" data-testid="mini-app-visibility">
      <p className="text-sm text-secondary" id={labelId}>
        {messages.mini_app_publish_visibility()}
      </p>
      <ChoiceList
        {...(disabled ? { disabled } : {})}
        labelledBy={labelId}
        name={`mini-app-visibility-${labelId}`}
        onChange={(next) => {
          const picked = next[0];
          if (picked === "private" || picked === "workspace" || picked === "link")
            onChange(picked);
        }}
        options={[
          { id: "private", label: messages.mini_app_visibility_private() },
          { id: "workspace", label: messages.mini_app_visibility_workspace() },
          { id: "link", label: messages.mini_app_visibility_link() },
        ]}
        value={[value]}
      />
    </div>
  );
}
