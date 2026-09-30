import { useEffect, useId } from "react";
import {
  claimNativeSurfaceSuppression,
  releaseNativeSurfaceSuppression,
} from "./nativeSurfaceSuppression";

/**
 * Holds a native-surface suppression claim for as long as it is mounted.
 *
 * Render one inside every modal surface (react-aria `ModalOverlay` mounts its
 * children only while the overlay is open or exiting, so mount scope equals
 * the overlay's lifetime, entry and exit animations included). A DOM backdrop
 * neither paints over a native `WebContentsView` nor blocks its input, so a
 * modal is only actually modal while the surface is hidden.
 *
 * `ModalOverlay` must not be used without one — a conformance test walks the
 * source tree and fails on any importer that lacks it.
 */
export const NativeSurfaceSuppressor = () => {
  const claimId = useId();
  useEffect(() => {
    claimNativeSurfaceSuppression(claimId);
    return () => releaseNativeSurfaceSuppression(claimId);
  }, [claimId]);
  return null;
};
