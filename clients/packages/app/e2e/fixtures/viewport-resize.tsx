import { useState } from "react";
import { createRoot } from "react-dom/client";
import { CommandPalette } from "../../../ui/src/components/command-palette/CommandPalette";
import { Toaster } from "../../../ui/src/components/toast/Toaster";
import { toast } from "../../../ui/src/components/toast/toastApi";
import "../../src/styles.css";

function ResponsiveSurfaces() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button onClick={() => setOpen(true)}>Open search</button>
      <button
        onClick={() =>
          toast("Notification", { duration: Infinity, testId: "notification" })
        }
      >
        Show notification
      </button>
      <Toaster />
      {/* A narrow content container must not replace the window breakpoint. */}
      <div style={{ containerType: "inline-size", width: 280 }}>
        <div className="comma-settings-route" data-testid="settings">
          <div className="comma-appearance-options">
            <div>Light</div>
            <div>Dark</div>
            <div>System</div>
          </div>
        </div>
        <div className="comma-settings-page" data-layout="rail">
          <aside className="comma-settings-sidebar">Settings</aside>
        </div>
        <div className="markstream-react">
          {/* Exercise the vendor class without making Tailwind generate a duplicate. */}
          <ul
            className={["max-lg", "pl-[calc(14/9*1em)]"].join(":")}
            data-testid="markdown-list"
          >
            <li>Markdown list</li>
          </ul>
        </div>
        <div className="html-preview-frame">HTML preview</div>
        <div className="comma-meeting-recorder" data-phase="recording">
          Recording
        </div>
      </div>
      <CommandPalette
        open={open}
        onOpenChange={setOpen}
        query=""
        onQueryChange={() => {}}
        onSelect={() => {}}
        label="Search"
        groups={[
          {
            id: "tasks",
            items: [{ value: "task", title: "A task", meta: "Yesterday" }],
          },
        ]}
      />
    </>
  );
}

createRoot(document.getElementById("root")!).render(
  new URLSearchParams(location.search).has("surfaces") ? (
    <ResponsiveSurfaces />
  ) : (
    // Fixed transcript width: resizing its ancestors should reuse these layouts.
    <main style={{ width: 700, font: "14px/20px Arial" }}>
      {Array.from({ length: 1500 }, (_, i) => (
        <section key={i}>
          <p>Message {i}: retained content with a stable width during window resize.</p>
          <p>
            <span>Previous messages remain mounted.</span> <strong>Stable text.</strong>
          </p>
        </section>
      ))}
    </main>
  )
);
