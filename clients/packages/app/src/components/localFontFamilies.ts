import { getNativeBridge } from "@comma/native-bridge";
import { useCallback, useEffect, useState } from "react";

// Local Font Access, a browser's own list: one entry per face, seconds to
// build on the first read, and a permission prompt before it.
declare global {
  interface Window {
    queryLocalFonts?: () => Promise<readonly { readonly family: string }[]>;
  }
}

const familyOrder = new Intl.Collator(undefined, {
  numeric: true,
  sensitivity: "base",
});
let loadedFamilies: readonly string[] | undefined;

// Electron's Main asks the OS for family names, which takes tens of
// milliseconds. Main answers null where it has no list, as in a browser.
async function readFamilies() {
  const { families } = await getNativeBridge().appearance.fontFamilies();
  const names =
    families ?? (await window.queryLocalFonts!()).map((font) => font.family);
  loadedFamilies = [...new Set(names)].toSorted(familyOrder.compare);
  return loadedFamilies;
}

/**
 * The font families installed on this computer. While `active`, Electron
 * reads a current list at once; a browser reads ahead only after the reader
 * has allowed it, and otherwise `load` reads when the font menu opens.
 */
export function useLocalFontFamilies(active: boolean) {
  const electron = getNativeBridge().platform === "electron";
  const supported = electron || typeof window.queryLocalFonts === "function";
  const [families, setFamilies] = useState(loadedFamilies);
  const [loading, setLoading] = useState(false);

  const load = useCallback(() => {
    setLoading(true);
    readFamilies().then(
      (loaded) => {
        setFamilies(loaded);
        setLoading(false);
      },
      () => setLoading(false)
    );
  }, []);

  useEffect(() => {
    if (!active || !supported) return;
    if (electron) {
      load();
      return;
    }
    void navigator.permissions
      .query({ name: "local-fonts" as PermissionName })
      .then((status) => {
        if (status.state === "granted") load();
      });
  }, [active, electron, load, supported]);

  // A refresh behind a list already shown needs no loading row.
  return { families, load, loading: loading && !families, supported };
}
