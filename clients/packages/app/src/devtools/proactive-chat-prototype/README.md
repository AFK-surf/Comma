# Proactive reminder UI prototype

Run `make prototype-proactive-ui` from the repository root.
Open `http://127.0.0.1:54870`.

This throwaway UI asks how reminders should appear within Comma Home.
It uses existing Comma icons, mascot, and ScrollArea with fictional emails and bills.
It does not call a provider, model, scheduler, or product API.
The separate backend simulator remains at `make prototype-proactive-chat`.

- A: conversational reminder with a Routine reference and the existing Task rail.
- B: an action card inside the chat message.
- C: a quiet Home preview that opens the chat when selected.

Use `?variant=A|B|C&scene=urgent|bill|unhandled|waiting|quiet` to share a starting view.
The bottom switcher appears in development and in builds that use `--mode prototype`.
Scenario controls reset the in-memory state. Reloading also resets it.

Try drafting, snoozing, confirming completion, opening a source, and simulating an incoming reply.
Drafts remain unsent and await review.
An incoming reply stops follow-up and leaves the existing Task awaiting user acceptance.
The quiet scenario adds no new chat message.

The proposed default is A. Product selection is pending user feedback.
After selection, remove the unused variants and implement the accepted behavior through the existing product owners.
