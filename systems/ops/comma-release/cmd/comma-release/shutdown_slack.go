package main

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
	"github.com/slack-go/slack"
)

const shutdownApprovalSlackChannel = "C0BAJ7A71H8"

// Reuse the release identity's Secret Manager access and the product-selected approval channel.
func shutdownSlackNotifier(spec release.EnvironmentSpec, gcloud release.Runner, options ...slack.Option) func(context.Context, string) error {
	return func(ctx context.Context, issueURL string) error {
		if spec.Environment != "staging" {
			return errors.New("staging Slack channel is not configured")
		}
		ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		secret, err := readSecretJSON(ctx, gcloud, spec.Project, "alert-router-slack-staging")
		if err != nil {
			return errors.New("cannot read existing staging Slack secret")
		}
		token := stringField(secret, "SLACK_BOT_TOKEN")
		if token == "" {
			return errors.New("existing staging Slack secret has no bot token")
		}
		opts := append([]slack.Option{slack.OptionHTTPClient(&http.Client{Timeout: 15 * time.Second})}, options...)
		client := slack.New(token, opts...)
		_, _, err = client.PostMessageContext(ctx, shutdownApprovalSlackChannel,
			slack.MsgOptionText("Comma staging deployment needs human shutdown approval: "+issueURL+"\nReply yes / ok / lgtm / 同意 on the GitHub issue within 10 minutes. Agents must not approve.", false),
			slack.MsgOptionDisableLinkUnfurl(), slack.MsgOptionDisableMediaUnfurl())
		if err != nil {
			return errors.New("Slack could not send the shutdown approval link")
		}
		return nil
	}
}
