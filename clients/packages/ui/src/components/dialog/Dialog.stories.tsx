import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import { Button, Dialog, DialogActions } from "../index";

const meta = {
  title: "App components/Dialog",
  parameters: {
    layout: "fullscreen",
  },
  decorators: [
    (Story) => (
      <div className="flex min-h-screen items-center justify-center bg-primary p-xl">
        <Story />
      </div>
    ),
  ],
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

const dialogActions = [
  { label: "Cancel", hierarchy: "secondary-gray" as const },
  { label: "Confirm", hierarchy: "primary" as const },
];

export const Default: Story = {
  render: () => (
    <Dialog
      trigger={<Button hierarchy="primary">Open dialog</Button>}
      title="Blog post published"
      description="This blog post has been published. Team members will be able to edit this post and republish changes."
      actions={dialogActions}
    />
  ),
};

export const Controlled: Story = {
  render: () => {
    const [open, setOpen] = useState(false);

    return (
      <div className="flex flex-col items-center gap-md">
        <Button hierarchy="secondary-gray" onPress={() => setOpen(true)}>
          Open controlled dialog
        </Button>
        <Dialog
          isOpen={open}
          onOpenChange={setOpen}
          title="Blog post published"
          description="This blog post has been published. Team members will be able to edit this post and republish changes."
          actions={[
            {
              label: "Cancel",
              hierarchy: "secondary-gray",
              onPress: () => setOpen(false),
            },
            { label: "Confirm", hierarchy: "primary", onPress: () => setOpen(false) },
          ]}
        />
      </div>
    );
  },
};

export const WithInput: Story = {
  render: () => (
    <Dialog
      trigger={<Button hierarchy="primary">Rename project</Button>}
      variant="input"
      title="Rename project"
      description="Enter a new name for this project."
      input={{
        label: "Project name",
        placeholder: "Untitled project",
        defaultValue: "Marketing site",
      }}
      actions={[
        { label: "Cancel", hierarchy: "secondary-gray" },
        { label: "Save changes", hierarchy: "primary" },
      ]}
    />
  ),
};

export const ThreeButtons: Story = {
  render: () => (
    <Dialog
      trigger={<Button hierarchy="primary">Rename chat</Button>}
      variant="input"
      title="Rename chat"
      description="Keep it short and recognizable"
      input={{
        label: "Chat name",
        placeholder: "Text content",
      }}
      actions={[
        { label: "Skip", hierarchy: "secondary-gray", shortcut: false },
        { label: "Cancel", hierarchy: "secondary-gray" },
        { label: "Save", hierarchy: "primary" },
      ]}
    />
  ),
};

export const Destructive: Story = {
  render: () => (
    <Dialog
      trigger={<Button hierarchy="destructive">Delete project</Button>}
      title="Delete project"
      description="Are you sure you want to delete this project? This action cannot be undone."
      actions={[
        { label: "Cancel", hierarchy: "secondary-gray" },
        { label: "Delete", hierarchy: "destructive" },
      ]}
    />
  ),
};

export const DismissBehavior: Story = {
  render: () => (
    <Dialog
      trigger={<Button hierarchy="primary">Open dialog</Button>}
      title="Dismiss behavior"
      description="Close with the X button, Cancel, Esc, or by clicking the backdrop."
      actions={dialogActions}
    />
  ),
};

export const FooterButtons: Story = {
  render: () => (
    <div className="w-dialog-default max-w-full rounded-xl border-[0.5px] border-solid border-primary bg-popup-primary p-xl shadow-md">
      <DialogActions
        actions={[
          { label: "Cancel", hierarchy: "secondary-gray" },
          { label: "Confirm", hierarchy: "primary" },
        ]}
      />
    </div>
  ),
};
