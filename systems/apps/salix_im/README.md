# SalixIM

SalixIM owns the IM connect and provider domain for Salix.

It exposes the unified IM provider backend used by agent tools and the domain
functions used by web HTTP routes. HTTP routing belongs in `salix_web`; provider
manuals, provider API dispatch, connect visibility, and provider callback
handling belong here.

The static agent discovery surface is `im.connects_list` and
`im.provider_apis_list`. Provider API manuals are read through the runtime
`help` meta tool, and provider APIs execute through the runtime tool dispatcher
as dynamic operation ids such as `im_api.slack.post_message`. SalixIM decides
which connects are visible at runtime. Routers see `internal` plus enabled
external connects in their group. Workers see `internal` plus their group's
router-bound Slack connects, and may dispatch only granted Slack operations:
everything the operation registry classifies as `safety: read`, plus the
enumerated non-mutating download `slack.fetch_file` (connect discovery,
listing, and dispatch all apply the same grant); every other external connect
or operation is reported as not found or role-restricted.
