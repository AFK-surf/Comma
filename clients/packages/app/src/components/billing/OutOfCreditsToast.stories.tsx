import { useCommaI18n } from "@comma/i18n/react";
import { Button, Toaster, toast } from "@comma/ui";
import type { Meta, StoryObj } from "@storybook/react-vite";
import { useEffect } from "react";
import "../../styles.css";
import { showOutOfCreditsToast } from "./outOfCredits";

function OutOfCreditsToastDemo() {
  const { locale } = useCommaI18n();
  useEffect(() => {
    showOutOfCreditsToast(locale);
    return () => {
      toast.dismissAll();
    };
  }, [locale]);
  return (
    <Button hierarchy="secondary-gray" onPress={() => showOutOfCreditsToast(locale)}>
      Show toast
    </Button>
  );
}

const meta = {
  title: "App components/Out of credits toast",
  parameters: { layout: "fullscreen" },
  decorators: [
    (Story) => (
      <>
        <Toaster />
        <div className="flex min-h-screen items-center justify-center p-xl">
          <Story />
        </div>
      </>
    ),
  ],
  render: () => <OutOfCreditsToastDemo />,
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

/** Raised again with the same id, it replaces itself rather than stacking. */
export const Default: Story = {};
