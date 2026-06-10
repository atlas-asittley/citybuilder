"""Regression tests for the numeric-precision bug class.

The food-drain / processor / extractor / population code paths used to
write multiplicative or division-derived numerics into the database
without rounding. PostgreSQL `numeric` is unbounded precision, so
each tick added ~20 trailing digits to the stored value, eventually
hitting the 16383-digit ceiling.

Three migrations fixed it (see `migration_patches/numeric_precision_fix*.sql`
and `audit_cleanup_2026_05_08.sql`). These tests ensure no future
regression by running many ticks and asserting the stored values stay
under a sane digit cap.
"""

import psycopg2
import pytest

def _tick_and_upgrade_all(cur):
    """process_production + auto-step every now-eligible house. Mirrors
    what the player does in the UI (the click on the Upgrade button)
    so tests written against the pre-2026-05-08 auto-upgrade flow stay
    truthful. Safe to call even when nothing is eligible."""
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT id FROM public.buildings WHERE evolution_eligible_at IS NOT NULL")
    for (bid,) in cur.fetchall():
        cur.execute("SAVEPOINT __tu")
        try:
            cur.execute("SELECT public.upgrade_house(%s)", (str(bid),))
            cur.execute("RELEASE SAVEPOINT __tu")
        except Exception:
            cur.execute("ROLLBACK TO SAVEPOINT __tu")




MAX_DIGITS = 30  # 6 decimals + room for integer part + sign + dot


def _digit_count(value):
    """How many characters in the value's text representation."""
    if value is None:
        return 0
    return len(str(value))


def test_food_drain_does_not_bloat_quantity(make_player, place, cur, clear_resources):
    """Tier-2 cottage drains food every tick; inventory must stay sane
    after many drains. Pre-fix this rolled past 16k digits in <12 hours."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))

    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'grain', 1000.0), (%s, 'flour', 500.0), (%s, 'pottery', 1000.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                (str(p['id']), str(p['id']), str(p['id'])))

    # Run 50 production ticks back-to-back with backdated last_food_tick_at
    # to force drain on each.
    for _ in range(50):
        cur.execute("""UPDATE public.player_profiles
                       SET last_food_tick_at = now() - interval '60 seconds'
                       WHERE id = %s""", (str(p['id']),))
        _tick_and_upgrade_all(cur)

    cur.execute("""SELECT MAX(length(quantity::text))
                   FROM public.inventories WHERE player_id = %s""", (str(p['id']),))
    max_digits = cur.fetchone()[0] or 0
    assert max_digits <= MAX_DIGITS, (
        f"inventory quantity bloated to {max_digits} digits after 50 ticks "
        f"(precision-bug regression in food drain path)"
    )


def test_processor_output_does_not_bloat_quantity(make_player, place, cur, clear_resources):
    """Sawmill consumes timber → produces lumber over many ticks.
    Both columns must stay sane in storage size."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('sawmill', hx + 1, hy + 2)
    cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                   VALUES (%s, 'timber', 10000.0)
                   ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 10000.0""",
                (str(p['id']),))

    for _ in range(50):
        cur.execute("""UPDATE public.buildings SET last_processed_at = now() - interval '60 seconds'
                       WHERE player_id = %s""", (str(p['id']),))
        _tick_and_upgrade_all(cur)

    cur.execute("""SELECT resource_key, length(quantity::text)
                   FROM public.inventories WHERE player_id = %s
                   AND resource_key IN ('timber', 'lumber')""", (str(p['id']),))
    for resource_key, digits in cur.fetchall():
        assert digits <= MAX_DIGITS, (
            f"{resource_key} quantity bloated to {digits} digits after 50 sawmill ticks"
        )


def test_population_and_migration_rate_do_not_bloat(make_player, cur):
    """Population is updated as v_pop + v_rate × v_minutes where v_rate
    comes from a division. Without rounding, both balloon."""
    p = make_player()
    for _ in range(50):
        cur.execute("""UPDATE public.player_profiles
                       SET last_population_tick_at = now() - interval '60 seconds'
                       WHERE id = %s""", (str(p['id']),))
        _tick_and_upgrade_all(cur)

    cur.execute("""SELECT length(population::text), length(migration_rate::text), length(happiness::text)
                   FROM public.player_profiles WHERE id = %s""", (str(p['id']),))
    pop_d, mig_d, hap_d = cur.fetchone()
    assert pop_d <= MAX_DIGITS, f"population bloated to {pop_d} digits"
    assert mig_d <= MAX_DIGITS, f"migration_rate bloated to {mig_d} digits"
    assert hap_d <= MAX_DIGITS, f"happiness bloated to {hap_d} digits"


def test_no_bloated_columns_in_clean_schema(cur):
    """Schema-wide invariant: no numeric column in the public schema
    should hold a value with > 30 chars (= 6 decimals + integer +
    sign). Catches new code paths that forget to ROUND."""
    cur.execute("""
        SELECT table_name, column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND data_type = 'numeric'
    """)
    for table, col in cur.fetchall():
        cur.execute(f'SELECT MAX(length("{col}"::text)) FROM public."{table}"')
        max_d = cur.fetchone()[0] or 0
        assert max_d <= MAX_DIGITS, (
            f"public.{table}.{col} has a value of {max_d} chars — "
            f"likely a new precision-bug regression. Check writes to this "
            f"column for unrounded division/multiplication results."
        )
