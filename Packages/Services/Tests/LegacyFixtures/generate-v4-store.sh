#!/bin/bash

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_directory="$(cd -- "${script_directory}/../.." && pwd)"
fixture_path="${1:-${script_directory}/StoreSchemaV4.fixture}"
temporary_directory="$(mktemp -d "${script_directory}/.store-schema-v4.XXXXXX")"
temporary_fixture="${temporary_directory}/StoreSchemaV4.fixture"
trap 'rm -rf -- "${temporary_directory}"' EXIT

swift run \
    --disable-sandbox \
    --disable-automatic-resolution \
    --package-path "${package_directory}" \
    StoreFixtureGenerator \
    v4 \
    "${temporary_fixture}"

sqlite3 "${temporary_fixture}" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -f -- "${temporary_fixture}-shm" "${temporary_fixture}-wal"
mv -f -- "${temporary_fixture}" "${fixture_path}"
