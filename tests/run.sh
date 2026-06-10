#!/usr/bin/env bash
# Run the full test suite. Single command, exit code 0 = all pass.
#
# Requires:
#   - python3 with psycopg2 + pytest (see tests/README.md)
#   - ~/.citybuilder_db_url with a Supabase Session-pooler connection string
#
# Each test runs inside a savepoint and rolls back, so the live database
# stays untouched.

set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f ~/.citybuilder_db_url ]; then
  echo "ERROR: ~/.citybuilder_db_url not found."
  echo "       Save your Supabase Session-pooler connection string there first."
  echo "       See tests/README.md or memory/reference_database_access.md."
  exit 1
fi

exec python3 -m pytest "$@"
