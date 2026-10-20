import { useState } from "react";
import { Button } from "@comma/ui/components/Button";
import { SettingsDialog, createSettingsRegistry } from "@comma/ui/components/settings";
import { useCommaMessages } from "@comma/i18n/react";
import { useComputeSettingsController } from "./useComputeSettingsController";
import { ComputeSettingsView } from "./ComputeSettingsView";

export function LocalComputeLoginEntry() {
  const m = useCommaMessages();
  const [open, setOpen] = useState(false);
  const controller = useComputeSettingsController(false, open);
  const local = controller.local;
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
          searchable={false}
          searchAriaLabel={m.settings_search()}
          searchPlaceholder={m.settings_search_placeholder()}
          onClose={() => setOpen(false)}
          registry={createSettingsRegistry({
            groups: [
              {
                id: "local",
                label: m.compute_this_mac(),
                categories: [
                  {
                    id: "local-compute",
                    icon: "devices",
                    label: m.compute_local_manage(),
                    sections: [],
                    content: <ComputeSettingsView controller={controller} />,
                    overlay: controller.nodeOverlay,
                  },
                ],
              },
            ],
          })}
        />
      ) : null}
    </>
  );
}
