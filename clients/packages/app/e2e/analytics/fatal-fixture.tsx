import { createRoot } from "react-dom/client";
import { reportCommaClientError } from "../../src/analytics/client";

export function crashRenderer() {
  const node = document.createElement("div");
  document.body.appendChild(node);
  createRoot(node, {
    onUncaughtError: (error) => reportCommaClientError(error, "react_uncaught"),
  }).render(<BrokenView />);
}

function BrokenView(): never {
  const error = new TypeError("private exception message comma_sess_secret");
  error.stack =
    "TypeError: private exception message\n    at privateFunction (file:///Users/private/index-abc123.js?secret=private:42:7)";
  throw error;
}
