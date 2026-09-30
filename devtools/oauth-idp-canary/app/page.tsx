import { auth, signIn, signOut } from "../auth";

export default async function Home() {
  const session = await auth();

  if (!session?.user) {
    return (
      <main>
        <h1>Comma OAuth IdP canary</h1>
        <form
          action={async () => {
            "use server";
            // Land back on 127.0.0.1 — the host the session cookie lives on
            // (see the redirect callback in auth.ts).
            await signIn("comma", { redirectTo: "http://127.0.0.1:8765/" });
          }}
        >
          <button type="submit">Continue with Comma</button>
        </form>
      </main>
    );
  }

  const user = session.user as { id?: string; email?: string | null };

  return (
    <main>
      <h1>Signed in via Comma</h1>
      {/* Acceptance check: `sub` must be the comma user id (usr_*). */}
      <p>
        subject: <code>{user.id ?? "MISSING — IdP bug or callback drift"}</code>
      </p>
      <p>
        email: <code>{user.email ?? "MISSING"}</code>
      </p>
      <pre>{JSON.stringify(session.user, null, 2)}</pre>
      <form
        action={async () => {
          "use server";
          await signOut();
        }}
      >
        <button type="submit">Sign out (canary session only)</button>
      </form>
    </main>
  );
}
