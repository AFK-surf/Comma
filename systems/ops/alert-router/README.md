# Alert Router staging activation

Cluster update availability and shutdown approval follow the [rollout policy](../../../docs/release-operations.md#rollout-policy-and-human-shutdown-approval).

Staging sends Alert Router messages to the public Slack channel
`#comma-app-alerts` (`C0BJ1699HSN`) as the dedicated `Comma Alerts` bot. The existing
Cloud Monitoring and Grafana direct Slack destinations remain in place during
initial live acceptance. The separately reviewed staging cutover removes those
two direct Slack bindings only after lifecycle acceptance; GCP email remains
outside the Router. Production and unrelated legacy GCP routes are unchanged.

## One-time Slack app setup

1. In Slack app administration, create an app from
   [`slack-app-manifest.yaml`](slack-app-manifest.yaml) in the Comma workspace.
2. Install the app to the workspace. The manifest requests only
   `chat:write` and `channels:history`; it has no Events API, Socket Mode,
   interactive actions, signing secret, or user token.
3. Invite `@Comma Alerts` to `#comma-app-alerts`.
4. Validate the installed bot token with Slack `auth.test`, then make one
   read-only `conversations.history` request for `C0BJ1699HSN`. Do not send a
   canary before deployment authorization.
5. Add the token as a new Secret Manager version of
   `alert-router-slack-staging` using the JSON field `SLACK_BOT_TOKEN`. Never put
   the token in Terraform input, GitHub Actions input, a local file, logs, or a
   shell history entry. The Secret container and Comma deploy-service-account
   access are Terraform-owned; the token version is intentionally entered only
   after Slack installation.

If app installation is rejected by workspace policy, stop there. Do not add
broader scopes or reuse a different bot as a workaround.

## Staging activation order

1. Merge and apply the reviewed `gcp-infra` change. It creates the Pub/Sub push
   path, OIDC identity, Grafana HMAC value, and both Alert Router Secret Manager
   containers. This step does not change any alert condition.
2. Complete the Slack app setup above and confirm the deploy identity can read
   both `alert-router-staging` and `alert-router-slack-staging` without printing
   their payloads.
3. Merge the reviewed Comma change. The staging environment spec selects
   `enabled=true`, `mode=live`, and channel `C0BJ1699HSN`; production remains
   disabled. Alert Router is not a deployment-dispatch input.
4. Deploy the reviewed Comma commit to staging. The release validates both
   Secret payloads before serving rollout and then verifies the dedicated
   database during its migration plan.
5. Bind one reviewed Cloud Monitoring notification channel and one signed
   Grafana webhook to the Router while retaining their existing direct Slack
   routes. Exercise one controlled firing-to-terminal lifecycle from each
   source and compare source event counts with Router root/thread state.
6. For the separately authorized staging cutover, remove `public_slack` from
   the Cloud Monitoring staging channel catalog and remove only the Slack
   integration from Grafana contact point `comma-app-alerts`. Keep the GCP email
   channel, Router Pub/Sub binding, and Grafana HMAC webhook unchanged. Require
   a no-create/no-destroy Terraform plan, post-apply no-op, and provider
   readback before treating duplicates as removed.

The normal Router rollback is to restore the provider-direct Slack integrations
first, then revert the staging environment spec to `mode=disabled` and redeploy
the previous reviewed Comma artifact. GCP email remains available throughout.
Disabling provider bindings or rotating the bot token remains a separate
reviewed operation.
