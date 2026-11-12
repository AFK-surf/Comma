#!/usr/bin/env node

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import {
  cardColorTokens,
  cardLengthTokens,
  cardRawTokens,
} from "../src/dynamic-ui/cardTypes.ts";
import { renderCardTokenDefaultsModule } from "./card-token-defaults-codegen.mjs";

const theme = readFileSync(
  fileURLToPath(new URL("../../ui/src/styles/theme.css", import.meta.url)),
  "utf8"
);
writeFileSync(
  fileURLToPath(new URL("../src/dynamic-ui/cardTokenDefaults.ts", import.meta.url)),
  renderCardTokenDefaultsModule(theme, [
    ...cardColorTokens,
    ...cardLengthTokens,
    ...cardRawTokens,
  ])
);
