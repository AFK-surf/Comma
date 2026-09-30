import * as schema from "../metadata/schema";
import { Database } from "bun:sqlite";
import { drizzle } from "drizzle-orm/sqlite-proxy";

import { SqlQueryService } from "../query-service";

export class SqliteQueryService extends SqlQueryService {
  constructor(database: Database) {
    super(
      drizzle(
        async (sql, params, method) => {
          const query = database.query(sql);
          if (method === "run") {
            query.run(...params);
            return { rows: [] };
          }
          return { rows: query.values(...params) };
        },
        { schema }
      )
    );
  }
}
