import "@comma/ui/styles.css";

declare global {
  interface Window {
    focusRingFixtureReady?: true;
  }
}

window.focusRingFixtureReady = true;
