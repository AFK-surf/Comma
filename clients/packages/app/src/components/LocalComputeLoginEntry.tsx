import { useState } from "react";
import { Button, SettingsDialog, createSettingsRegistry } from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import { useLocalComputeCategory } from "./useLocalComputeCategory";

export function LocalComputeLoginEntry() {
  const m = useCommaMessages();
  const [open, setOpen] = useState(false);
  const local = useLocalComputeCategory(open);
  if (!local.available) return null;
  return (
    <>
      <Button hierarchy="tertiary-gray" onPress={() => setOpen(true)}>
        {m.compute_local_manage()}
      </Button>
      {open ? (
        <SettingsDialog
          activeCategoryId="local-compute"
          ariaLabel={m.compute_local_manage()}
          closeLabel={m.settings_close()}
          contentAriaLabel={m.shell_settings_content()}
          emptySearchDescription={m.settings_search_empty_description()}
          emptySearchTitle={m.settings_search_empty()}
          searchAriaLabel={m.settings_search()}
          searchPlaceholder={m.settings_search_placeholder()}
          onClose={() => setOpen(false)}
          registry={createSettingsRegistry({
            groups: [
              {
                id: "local",
                label: m.compute_this_mac(),
                categories: [local.category],
              },
            ],
          })}
        />
      ) : null}
    </>
  );
}
