import "@comma/app/styles.css";
import { closeDocumentCookies } from "./documentCookies";
import { showMainWindowBoot } from "./mainWindowBoot";

closeDocumentCookies();

// The boot paints before any application module loads.
showMainWindowBoot();

void import("./renderComma");
