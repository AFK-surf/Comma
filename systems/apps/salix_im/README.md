# SalixIM

SalixIM owns the IM connect and provider domain for Salix.

It provides the IM provider backend for agent tools and the domain functions for
web HTTP routes. HTTP routing belongs in `salix_web`. Provider manuals, provider
API dispatch, connect visibility, and provider callback handling belong here.

Agents discover IM through `im.connects_list` and `im.provider_apis_list`. They
read provider API manuals through the runtime `help` meta tool. Provider APIs run
through the runtime tool dispatcher as dynamic operation ids such as
`im_api.slack.post_message`.

SalixIM decides which connects and operations each role can see and dispatch.
Routers see `internal` and the enabled external connects in their group. Workers
see `internal`, Slack `safety: read` operations and `slack.fetch_file` through
router-bound connects, and Feishu cloud-document operations through the Group's
Feishu connect. A Task execution scope can also expose its exact granted IM
writes. Discovery and dispatch apply the same rules. Any other connect or
operation is reported as not found or role-restricted. `SalixIM.Provider` owns
these rules.
