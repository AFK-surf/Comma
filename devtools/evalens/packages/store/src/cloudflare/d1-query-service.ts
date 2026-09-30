import * as schema from "../metadata/schema";
import { drizzle } from "drizzle-orm/d1";

import { SqlQueryService } from "../query-service";

export class D1QueryService extends SqlQueryService {
  constructor(database: D1Database) {
    super(drizzle(database, { schema }));
  }
}
