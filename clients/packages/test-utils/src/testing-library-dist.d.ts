// The package's own entry, which observed-testing-library re-exports while
// records are written (its bare name is aliased to that module then).
declare module "@testing-library/react/dist/index.js" {
  export * from "@testing-library/react";
}
