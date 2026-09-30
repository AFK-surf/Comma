import "@comma/ui/styles.css";

import { Login } from "@comma/ui";
import { StrictMode, useState } from "react";
import { createRoot } from "react-dom/client";

function LoginFixture() {
  const showError = new URLSearchParams(window.location.search).has("error");
  const [code, setCode] = useState("");
  const [completedCode, setCompletedCode] = useState("");
  const [errorMessage, setErrorMessage] = useState(
    showError ? "Please enter a valid verification code" : undefined
  );

  return (
    <main className="min-h-screen bg-primary p-8 text-primary">
      <Login
        mode="verification"
        email="person@comma.ai"
        code={code}
        onCodeChange={setCode}
        onCodeComplete={setCompletedCode}
        {...(errorMessage
          ? {
              errorMessage,
              onRetry: () => setErrorMessage(undefined),
            }
          : {})}
      />
      <output data-testid="verification-value">{code}</output>
      <output data-testid="completed-code">{completedCode}</output>
    </main>
  );
}

createRoot(document.getElementById("root") as HTMLElement).render(
  <StrictMode>
    <LoginFixture />
  </StrictMode>
);
