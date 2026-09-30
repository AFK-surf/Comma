import { isolation, shutdown, upgrade } from "./salix_connect_cases.ts";

Deno.test(upgrade);
Deno.test(shutdown);
Deno.test(isolation);
