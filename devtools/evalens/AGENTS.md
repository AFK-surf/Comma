# Evalens engineering rules

## Data boundaries

- Parse untrusted config, dataset, adapter, provider, and persisted data with a Zod
  schema at the boundary. Downstream experiment and evaluator code must consume the
  parsed type instead of repeatedly narrowing `unknown` or walking arbitrary JSON.
- A malformed boundary payload is an execution error. Do not coerce it to `false`, an
  empty string, an empty object, or an empty collection that could become an evaluable
  failure or a passing negative assertion.
- Shape provider observations into the result fields evaluators need. Do not make an
  evaluator rediscover typed facts by recursively searching serialized operation data.

## Helpers and shared utilities

- Inline a validation or expression when its only purpose is to throw for one missing
  value, read one nested property, wrap one `Promise.allSettled`, or forward to one
  operation. Do not add `required*`, `first*`, `nested*`, or similarly thin helpers that
  hide the control flow from the caller.
- Extract a helper only when it names reusable domain behavior or removes substantive
  duplication. Put provider-independent reusable code in `@evalens/utils`, split by
  concern such as `math.ts` or `http.ts`; do not grow another generic `utils.ts` dumping
  ground inside a feature or package.
- Keep provider schemas and provider-specific normalization at the adapter or experiment
  boundary that owns the protocol. Generic utilities must not contain provider-specific
  field aliases, error messages, or fallback behavior.
