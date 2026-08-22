// GRDBMigrations.swift — Versioned schema migrations for API cache
// Phase 2A: Persistence Layer

import Foundation
import GRDB

/// Manages GRDB database schema migrations for the API cache.
///
/// Each migration is versioned and idempotent. GRDB tracks which
/// migrations have run, so adding new versions is safe.
enum GRDBMigrations {
    /// Register all migrations with the migrator.
    static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_create_api_results") { database in
            try database.create(table: "api_results") { table in
                table.column("artist", .text).notNull()
                table.column("album", .text).notNull()
                table.column("source", .text).notNull()
                table.column("year", .integer)
                table.column("confidence", .integer).notNull().defaults(to: 0)
                table.column("timestamp", .datetime).notNull()
                table.column("ttl", .double)
                table.column("metadata", .text).notNull().defaults(to: "{}")
                table.primaryKey(["artist", "album", "source"])
            }
        }

        migrator.registerMigration("v1_create_album_years") { database in
            try database.create(table: "album_years") { table in
                table.column("artist", .text).notNull()
                table.column("album", .text).notNull()
                table.column("year", .integer)
                table.column("confidence", .integer).notNull().defaults(to: 0)
                table.column("timestamp", .datetime).notNull()
                table.primaryKey(["artist", "album"])
            }
        }

        migrator.registerMigration("v1_create_generic_cache") { database in
            try database.create(table: "generic_cache") { table in
                table.primaryKey("key", .text)
                table.column("value", .blob).notNull()
                table.column("ttl", .double)
                table.column("timestamp", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_add_generic_access_order") { database in
            try database.alter(table: "generic_cache") { table in
                table.add(column: "accessOrder", .integer).notNull().defaults(to: 0)
            }

            let keys = try String.fetchAll(
                database,
                sql: "SELECT key FROM generic_cache ORDER BY timestamp ASC, key ASC"
            )
            for (offset, key) in keys.enumerated() {
                try database.execute(
                    sql: "UPDATE generic_cache SET accessOrder = ? WHERE key = ?",
                    arguments: [offset + 1, key]
                )
            }

            try database.create(
                index: "generic_cache_on_accessOrder",
                on: "generic_cache",
                columns: ["accessOrder"]
            )
        }

        registerAnalyticsMigration(&migrator)
    }

    private static func registerAnalyticsMigration(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_create_analytics_events") { database in
            try database.create(table: "analytics_events") { table in
                table.primaryKey("id", .text)
                table.column("sessionID", .text).notNull()
                table.column("operation", .text).notNull()
                table.column("startedAt", .datetime).notNull()
                table.column("durationSeconds", .double).notNull()
                table.column("outcome", .text).notNull()
            }
            try database.create(
                index: "analytics_events_on_startedAt",
                on: "analytics_events",
                columns: ["startedAt"]
            )
            try database.create(
                index: "analytics_events_on_session_startedAt",
                on: "analytics_events",
                columns: ["sessionID", "startedAt"]
            )
            try database.create(
                index: "analytics_events_on_operation",
                on: "analytics_events",
                columns: ["operation"]
            )
        }
    }
}
