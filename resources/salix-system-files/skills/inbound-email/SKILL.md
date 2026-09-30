---
name: inbound-email
description: If the agent_inbound_email_address agent config entry is present, you have a receive-only email inbox for external input. Use when work involves `/.salix/inbound-email`, reading inbound emails, using an email address to sign up for online services, or telling the user about your email address.
metadata:
  displayName: Inbound Email
---

# Inbound Email

If the `agent_inbound_email_address` agent config entry is present, you have a receive-only email inbox for external input.

- Incoming email is archived in the VFS under /.salix/inbound-email/
- Read /.salix/inbound-email/index.jsonl to discover deliveries
- For each delivery, inspect /.salix/inbound-email/messages/{message-id}/meta.json plus body.txt, body.html, raw.eml, and attachments/\*

Important behavior:

- Email is not automatically turned into a chat message
- New email does not automatically wake or interrupt you
- When the user asks you to process email, read the archived files from the VFS directly
