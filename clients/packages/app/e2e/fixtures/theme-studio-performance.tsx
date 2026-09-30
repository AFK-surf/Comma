import { useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import {
  CommaWebClientSettingsProvider,
  CommaClientSettingsI18nProvider,
} from "../../src/components/commaClientSettings";
import { CommaAppearanceProvider } from "../../src/components/commaAppearance";
import {
  CustomThemeStudio,
  ThemePicker,
} from "../../src/components/commaCustomThemeStudio";
import "../../src/styles.css";

initializeCommaI18n(["en"]);

function Fixture() {
  const [open, setOpen] = useState(true);
  const picker = new URLSearchParams(location.search).has("picker");
  return (
    <CommaWebClientSettingsProvider>
      <CommaClientSettingsI18nProvider>
        <CommaAppearanceProvider>
          {!picker && (
            <button type="button" onClick={() => setOpen((current) => !current)}>
              {open ? "Close studio" : "Open studio"}
            </button>
          )}
          <div style={{ width: "min(400px, calc(100vw - 80px))", margin: 40 }}>
            {picker ? <ThemePicker /> : open ? <CustomThemeStudio /> : null}
          </div>
        </CommaAppearanceProvider>
      </CommaClientSettingsI18nProvider>
    </CommaWebClientSettingsProvider>
  );
}

createRoot(document.getElementById("root")!).render(<Fixture />);
