# Tests

A safety net for the bugs we've already hit and the ones we haven't yet.

## What's tested

The current suite covers the **database layer** — the RPCs and policies that have caused the most pain. Each of these came from a real bug we shipped:

| Test file | What it pins |
|---|---|
| `db/test_choose_industry.py` | The validator accepts all 4 industries (timber/stone/grain/clay), creates a player + starting chunk, seeds resources |
| `db/test_place_building.py` | District ownership, industry filter, road-adjacency for extractors, the `v_path` init that prevents non-extractor placements from crashing |
| `db/test_pathfinding.py` | BFS finds the nearest unclaimed resource, skips occupied tiles, respects district ownership, doesn't double-claim |
| `db/test_production.py` | Housing evolution actually fires (the `upgrade_secs` typo regression), idle extractors produce nothing |
| `db/test_districts.py` | Spiral allocator gives each player a unique chunk, expansion costs grow quadratically |
| `db/test_rls.py` | RLS DELETE policy on buildings actually persists demolitions |

35 tests, run in ~12 seconds.

## How they stay safe

The tests run against the **live Supabase database** but never persist any changes. The mechanism:

1. The whole session runs in one transaction (`autocommit=False`).
2. Each test gets a `SAVEPOINT` and a `ROLLBACK TO SAVEPOINT` in its teardown.
3. The outer transaction is rolled back at the end of the session.

If pytest crashes hard mid-run, nothing is committed — Postgres throws away the session's work.

Auth is simulated by setting `request.jwt.claims` GUC, which is what Supabase's `auth.uid()` reads. So the RPCs see a "logged-in" user without needing real Supabase auth tokens.

## Running

```bash
./tests/run.sh                       # everything
./tests/run.sh tests/db/test_rls.py  # one file
./tests/run.sh -k housing            # by keyword
./tests/run.sh -v                    # verbose
```

Prerequisites:
- `~/.citybuilder_db_url` exists with a Supabase Session-pooler URL.
  See `~/.claude/projects/-home-atlas-citybuilder/memory/reference_database_access.md`
  for the format.
- Python 3.10+
- `pip install --user pytest psycopg2-binary` (psycopg2 is usually pre-installed)

## Adding a test

Drop a `test_*.py` file under `tests/db/`. Use the fixtures from `conftest.py`:

```python
def test_something(make_player, place, cur):
    p = make_player(industry='timber')
    hx, hy = p['home_x'], p['home_y']
    place('road', hx + 1, hy)
    result = place('timber_camp', hx + 1, hy + 1)
    assert result['extractor_target'] is not None
```

Available fixtures:

- `cur` — a cursor inside its own savepoint
- `make_player(industry='timber')` — creates an auth user + invokes `choose_industry`, returns dict with `id`, `home_x`, `home_y`, etc.
- `as_user(user_id)` — switches the current connection to act as that user
- `tile_id_at(x, y)` — resolves coords to a tile UUID
- `place(building_type, x, y)` — calls `place_building` RPC, returns the JSON result

## When to add a test

**Always after a bug fix.** If a bug got past us once, regression coverage prevents it from coming back. Each existing test in this suite corresponds to a real bug — that's the bar.

Optional but valuable:
- New RPCs (test happy path + 1–2 error paths)
- Schema changes that affect RLS or constraints
- Anything where you find yourself thinking "I hope this still works"

Skip:
- Changes to art, copy, or pure-rendering JS
- Tuning numbers in seed data (covered by playtesting)

## What's NOT tested

- **JS code.** No test runner is set up for the frontend. Most JS is rendering and event handlers, which are hard to unit-test without a DOM mock and don't give much ROI right now. If we extract pure-function modules (the road-graph helper, walker BFS), those become unit-testable cheaply.
- **End-to-end flows.** No headless browser, no full game loop. Manual playtesting still covers this.
- **Visual regression.** Buildings, walkers, etc. are eyeballed.

If this list starts to feel like it's hiding bugs, the next logical step is a JS unit-test runner (`node --test` is built-in and free) for the pure-function pieces.
