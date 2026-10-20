# Evalens engineering rules

## Data boundaries

- Parse untrusted config, dataset, adapter, provider, and persisted data with a Zod
  schema at the boundary. Downstream code consumes the parsed type. It does not
  narrow `unknown` or walk arbitrary JSON again.
- A malformed boundary payload is an execution error. Do not coerce it to `false`, an
  empty string, or an empty object or collection that could become an evaluable
  failure or a passing negative assertion.
- Shape provider observations into the result fields evaluators need. Evaluators must
  not search serialized operation data for typed facts.

## Helpers and shared utilities

- Inline a check or expression that only throws for one missing value, reads one
  nested property, wraps one `Promise.allSettled`, or forwards to one operation. Do not
  add `required*`, `first*`, `nested*`, or similar thin helpers.
- Extract a helper only when it names reusable domain behavior or removes real
  duplication. Put provider-independent reusable code in `@evalens/utils`, split by
  concern such as `math.ts` or `http.ts`. Do not add another generic `utils.ts`.
- Keep provider schemas and provider-specific normalization at the adapter or
  experiment that owns the protocol. Generic utilities must not contain
  provider-specific field aliases, error messages, or fallback behavior.
