import "@comma/app/styles.css";
import { showTaskWindowBoot } from "./taskWindowBoot";

// TaskWindowEntrance.tla: hydrate only after the source-to-dialog transition.
// Application module evaluation must not compete with the entrance for frames.
const entrance = showTaskWindowBoot();
if (entrance) {
  void entrance.then(() => import("./renderComma"));
} else {
  void import("./renderComma");
}
