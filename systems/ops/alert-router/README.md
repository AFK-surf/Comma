# Alert Router staging activation

Cluster update availability and shutdown approval follow the [rollout policy](../../../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).

Staging sends Alert Router messages to the public Slack channel `#comma-app-alerts` (`C0BJ1699HSN`) as the dedicated `Comma Alerts` bot.
GCP email stays outside the Router. Production does not use the Router.

## One-time Slack app setup

1. In Slack app administration, create an app from [`slack-app-manifest.yaml`](slack-app-manifest.yaml) in the Comma workspace.
2. Install the app to the workspace. The manifest requests only `chat:write` and `channels:history`.
   It has no Events API, Socket Mode, interactive actions, signing secret, or user token.
3. Invite `@Comma Alerts` to `#comma-app-alerts`.
4. Validate the installed bot token with Slack `auth.test`. Then make one read-only `conversations.history` request for `C0BJ1699HSN`.
   Do not send a canary before deployment authorization.
5. Add the token as a new Secret Manager version of `alert-router-slack-staging` in the JSON field `SLACK_BOT_TOKEN`.
   Never put the token in Terraform input, GitHub Actions input, a local file, logs, or a shell history entry.
   Terraform owns the Secret container and the Comma deploy service account access.

If workspace policy rejects the app installation, stop. Do not add broader scopes or reuse a different bot.

## Staging activation order

Staging activation is complete. The staging environment spec (`systems/ops/comma-release/environments/staging.json`) selects `enabled=true`, `mode=live`, and channel `C0BJ1699HSN`.
Alert Router is not a deployment-dispatch input.
The release validates both Secret payloads (`alert-router-staging` and `alert-router-slack-staging`) before the serving rollout.
Staging Cloud Monitoring policies use `alert_router_pubsub` and `oncall_email`. Grafana reaches the Router through its signed HMAC webhook.

To roll back:

1. Restore the provider-direct Slack integrations.
2. Revert the staging environment spec to `mode=disabled`.
3. Redeploy the previous reviewed Comma artifact.

GCP email stays available throughout. Disabling provider bindings or rotating the bot token is a separate reviewed operation.
