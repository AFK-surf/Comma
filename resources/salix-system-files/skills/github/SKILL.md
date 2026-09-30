---
name: github
description: Work with GitHub through the `gh` CLI, including issues, pull requests, reviews, Actions runs, releases, repository metadata, API queries, and CLI authentication/setup on persistent environments.
---

# GitHub

Use this skill whenever the task involves GitHub and the `gh` CLI is available or should be made available. Prefer direct `gh` commands for operations that have stable CLI support.

Tool names below are canonical call targets. In the internal LLM runtime, invoke them with `call(tool="<name>", params={...})`.

## Comma plugin connections

Comma connects this plugin through Salix-managed OAuth. Reuse its active `github` credential alias for API or VM operations.
Use the connected official MCP tools when they cover the task. Check the current tool catalog before choosing a tool.
The API credential also authorizes the official MCP server.
Existing Composio connections can still serve supported tasks. Their presence does not require a new Composio authorization.

## Typical Goals

- Inspect, create, update, label, assign, or close issues.
- Inspect, create, checkout, review, comment on, merge, or monitor pull requests.
- Check GitHub Actions runs, jobs, failed logs, and commit statuses.
- Query repository metadata, branches, tags, releases, artifacts, and security or Dependabot alerts when permissions allow.
- Use `gh api` or GraphQL for fields not exposed by first-class subcommands.
- Install or authenticate `gh` on a persistent VM when the user needs reusable GitHub CLI access.

## Operating Principles

- Use `--repo owner/name` when outside the target repository or when ambiguity is possible.
- Prefer `--json` with `--jq` for machine-readable output instead of parsing tables.
- First try bare `gh` commands without injected credentials. Persistent environments may already have GitHub CLI auth configured; use managed OAuth only when bare `gh` is missing credentials, expired, or insufficient.
- Confirm destructive or hard-to-reverse actions before running them unless the user explicitly requested the action.
- Do not claim an issue, PR, workflow, or release was changed until the CLI command succeeds.
- If auth or permissions fail, report the concrete blocker and the command that exposed it.
- Keep generated issue and PR text concise and specific; avoid adding unrelated templates or markdown documents unless asked.

## Managed OAuth

Before requesting authorization or injecting OAuth credentials, first check whether bare `gh` already works in the environment:

1. Run a simple bare `gh` auth check without credential injection, such as:
   ```bash
   gh auth status -h github.com
   gh api user --jq '.login'
   ```
2. If bare `gh` works and has sufficient permissions for the task, continue using bare `gh`; do not inject `GH_TOKEN`.
3. If bare `gh` is unauthenticated or lacks permissions, call `oauth.list_credentials`.
4. If a `github` credential is available and active from `oauth.list_credentials`, use its alias in `env.exec` using `credential_env`; replace `"default"` below with the actual alias returned by `oauth.list_credentials`:
   ```json
   [
     {
       "env_var": "GH_TOKEN",
       "provider": "github",
       "alias": "default",
       "value": "access_token"
     }
   ]
   ```
5. If no usable GitHub credential exists, call `oauth.request_authorization` with `provider: "github"`, a short stable `alias` such as `"default"`, and a concise `reason`. Request scopes that match the task, for example `["repo"]` for private repository read/write, `["read:org"]` for organization metadata, and `["workflow"]` only when workflow file changes or Actions operations require it.
6. Share the returned `authorization_url` with the user and wait for them to confirm they completed authorization.
7. Call `oauth.complete_authorization` with the returned `state`. If it returns `completed`, retry the GitHub command with `env.exec` using `credential_env` and the returned alias. If it returns `pending`, ask the user to finish the authorization flow. If it returns `failed` or `expired`, start a fresh authorization flow.

For a Compute Workload, use the same `credential_env` array on `compute.exec` or `process.start`.
Pass `command` as an argument array, for example `["gh", "api", "user", "--jq", ".login"]`.
Use `env.exec` only for a connector environment. The credential applies only to the requested subprocess.

Managed OAuth injects the token into the subprocess that needs GitHub access. `gh` honors `GH_TOKEN`.

### If oauth.\* tools are unavailable (Composio tenants)

Some tenants use Composio instead of per-provider OAuth apps, and the tool
catalog reflects the available capabilities. If the `oauth.*` tools are not in
the current tool catalog but `composio.*` tools are, do not try this skill's
managed-OAuth or `env.exec` `credential_env` flow for GitHub. Instead:

1. Check `composio.list_connections` for an ACTIVE `github` connection.
2. If none, connect with `composio.request_connection` (toolkit `github`),
   post the returned Connect Link to the requester, and verify with
   `composio.check_connection`.
3. Run GitHub operations directly with `composio.execute`
   (e.g. `GITHUB_LIST_REPOSITORY_ISSUES`); discover tool slugs and schemas with
   `composio.list_tools` / `composio.get_tool`.

See the `composio` skill for the full flow and how to choose between the two
paths when both are available.

## Initial Checks

```bash
gh --version
gh auth status -h github.com
git remote -v
```

When the repository is known:

```bash
gh repo view owner/name --json nameWithOwner,defaultBranchRef,viewerPermission
```

## Issues

Search issues:

```bash
gh issue list --repo owner/name --search "login timeout session expired" --json number,title,state,url,labels,updatedAt
```

View an issue:

```bash
gh issue view 123 --repo owner/name --json number,title,body,state,url,labels,assignees,comments
```

Create an issue:

```bash
gh issue create --repo owner/name --title "Investigate login timeout on macOS" --body "..."
```

Update or comment:

```bash
gh issue edit 123 --repo owner/name --add-label bug --add-assignee @me
gh issue comment 123 --repo owner/name --body "..."
```

## Pull Requests

List and view PRs:

```bash
gh pr list --repo owner/name --state open --json number,title,author,headRefName,baseRefName,isDraft,reviewDecision,statusCheckRollup
gh pr view 55 --repo owner/name --json number,title,body,state,url,files,commits,reviews,comments
```

Check out a PR when code inspection is needed:

```bash
gh pr checkout 55 --repo owner/name
```

Create or update a PR:

```bash
gh pr create --repo owner/name --base main --head feature-branch --title "Title" --body "..."
gh pr edit 55 --repo owner/name --title "New title" --body "..."
```

Review, comment, and merge:

```bash
gh pr review 55 --repo owner/name --comment --body "..."
gh pr review 55 --repo owner/name --approve --body "..."
gh pr merge 55 --repo owner/name --squash --delete-branch
```

Use the repository's merge policy and user instructions when choosing merge mode.

## Actions And CI

Check PR checks:

```bash
gh pr checks 55 --repo owner/name
```

List and inspect workflow runs:

```bash
gh run list --repo owner/name --limit 20
gh run view <run-id> --repo owner/name --json status,conclusion,event,headBranch,headSha,jobs
gh run view <run-id> --repo owner/name --log-failed
```

Rerun only when requested or when it is clearly part of the task:

```bash
gh run rerun <run-id> --repo owner/name --failed
```

## Releases, Tags, And Artifacts

```bash
gh release list --repo owner/name
gh release view v1.2.3 --repo owner/name --json tagName,name,body,isDraft,isPrerelease,assets
gh release create v1.2.3 --repo owner/name --title "v1.2.3" --notes "..."
gh run download <run-id> --repo owner/name --dir /tmp/artifacts
```

## Advanced API Queries

Use REST when it is straightforward:

```bash
gh api repos/owner/name/pulls/55 --jq '{title, state, user: .user.login}'
```

Use GraphQL for review threads, project items, or nested data:

```bash
gh api graphql -f query='
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      title
      reviewThreads(first:50) {
        nodes { isResolved comments(first:10) { nodes { body author { login } } } }
      }
    }
  }
}' -F owner=owner -F repo=name -F number=55
```

## Authentication And Setup

If bare `gh` is already authenticated, use it without injecting credentials. If setup is required on a persistent VM, use the managed OAuth flow above and run `gh` commands with `env.exec` using `credential_env` only after confirming the environment does not already have sufficient persistent `gh` credentials. Install `gh` using the platform package manager or GitHub's documented package source when needed.

Preferred verification:

```bash
gh auth status -h github.com
gh api user --jq '.login'
```

## Failure Handling

- `gh auth status` fails: authenticate or explain the missing credentials.
- `HTTP 404` from `gh api`: check repository name, token scopes, and whether the authenticated user has access.
- Empty search results: report the query used before creating new GitHub objects.
- CI logs unavailable: inspect run permissions, retention, and whether the job is still running.
- Rate limit or SSO failures: surface the exact `gh` error and do not retry blindly.
