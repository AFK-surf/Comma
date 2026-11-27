import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import "../../styles.css";
import {
  NearbyConnectCard,
  type NearbyInviteRead,
  type NearbyPhase,
} from "./NearbyConnectCard";
import { NearbyPeopleDialog, type NearbyPerson } from "./NearbyPeopleDialog";

const nearby: NearbyPerson[] = [
  { id: "u1", name: "Zanwei Guo", via: "airdrop", status: "idle" },
  { id: "u2", name: "Rui Chen", via: "airdrop", status: "idle" },
  { id: "u3", name: "Heyang Zhou", via: "airdrop", status: "idle" },
  { id: "u4", name: "Jinfei Yang", via: "wifi", status: "unreachable" },
];

function Card({
  phase,
  open = true,
  read,
}: {
  phase: NearbyPhase;
  open?: boolean;
  read?: NearbyInviteRead;
}) {
  return (
    <NearbyConnectCard
      onAccept={() => {}}
      onClose={() => {}}
      onSendFirst={() => {}}
      open={open}
      // Before the core read the invite, only the name their computer gave is known.
      peer={
        read
          ? { name: "Jinfei", email: "" }
          : { name: "Jinfei Yang", email: "jinfei@cue.surf" }
      }
      phase={phase}
      read={read}
    />
  );
}

/** The asking side: the people a scan found; picking one waits for them. */
function List() {
  const [people, setPeople] = useState<NearbyPerson[]>(nearby);
  return (
    <NearbyPeopleDialog
      isOpen
      onClose={() => {}}
      onRescan={() => {}}
      onPick={(id) =>
        setPeople((was) =>
          was.map((p) => (p.id === id ? { ...p, status: "asking" } : p))
        )
      }
      people={people}
      scan="done"
    />
  );
}

const meta = {
  title: "App/Nearby connect",
  parameters: { layout: "fullscreen" },
} satisfies Meta;

export default meta;
type Story = StoryObj<typeof meta>;

export const Invited: Story = { render: () => <Card phase="invited" /> };
/** The card is up while the core still reads whose invite it is: Connect waits. */
export const Reading: Story = { render: () => <Card phase="invited" read="reading" /> };
/** The core could not read the invite: the card says so and only closes. */
export const Unreadable: Story = {
  render: () => <Card phase="invited" read="unreadable" />,
};
export const Connected: Story = { render: () => <Card phase="connected" /> };
export const PeopleNearby: Story = { render: () => <List /> };
