#!/usr/bin/env node

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { cardDataSchemas, cardFrame } from "../src/dynamic-ui/cardContract.ts";
import { renderCardContract } from "./card-contract-codegen.mjs";

// ui.create compiles this file in, so it lives with the server that reads it.
const output = fileURLToPath(
  new URL(
    "../../../../systems/apps/salix_agent/priv/dynamic_ui/card-contract.json",
    import.meta.url
  )
);
writeFileSync(output, renderCardContract(cardDataSchemas, cardFrame));
