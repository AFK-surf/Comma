# Public report template

Replace placeholders with reviewed facts. Omit unavailable optional fields. Mark an unknown client version as unknown.
Do not include private correlation identifiers or conversation links.

```markdown
Title: <component>: <observable failure>

## Environment
- Version/build (identify client or station):
- Client surface:
- OS:
- Architecture:
- Error code, if known:
- Frequency:

## Conditions and reproduction
<Required settings and synthetic starting data>
1. <Action>
2. <Action>

Reproduction status: <observed, reproduced, or steps inferred and untested>

## Expected result
<Observable result>

## Actual result
<Observable failure and reviewed error code>

## Minimal diagnostics
<Optional log excerpt, approved individually. No credentials, prompts, files, private URLs or identifiers.>

## Workaround
<Only a workaround that was tried, or unknown>
```
