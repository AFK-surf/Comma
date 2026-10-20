import "@comma/app/styles.css";
import { showMainWindowBoot } from "./mainWindowBoot";

// The boot paints before any application module loads.
showMainWindowBoot();

void import("./renderComma");
