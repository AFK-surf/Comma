import type { Meta, StoryObj } from "@storybook/react-vite";
import { useState } from "react";
import "../../styles.css";
import { NearbyConnectCard, type NearbyPhase } from "./NearbyConnectCard";
import { NearbyPeopleDialog, type NearbyPerson } from "./NearbyPeopleDialog";

const nearby: NearbyPerson[] = [
  { id: "u1", name: "Zanwei Guo", via: "airdrop", status: "idle" },
  { id: "u2", name: "Rui Chen", via: "airdrop", status: "idle" },
  { id: "u3", name: "Heyang Zhou", via: "airdrop", status: "idle" },
];

function Card({ phase, open = true }: { phase: NearbyPhase; open?: boolean }) {
  return (
    <NearbyConnectCard
      onAccept={() => {}}
      onClose={() => {}}
      onSendFirst={() => {}}
      open={open}
      peer={{ name: "Jinfei Yang", email: "jinfei@cue.surf" }}
      phase={phase}
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
export const Connected: Story = { render: () => <Card phase="connected" /> };
export const PeopleNearby: Story = { render: () => <List /> };
