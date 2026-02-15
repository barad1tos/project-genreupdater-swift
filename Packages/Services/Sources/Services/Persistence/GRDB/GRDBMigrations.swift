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
    }
}
