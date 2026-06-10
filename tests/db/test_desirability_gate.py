"""Tests for the desirability v2 housing tier gate.

These tests explicitly RESET the `city.skip_desirability_gate` GUC
that conftest sets at session scope, so the gate is active for them.
Verifies:
  - upgrade is blocked when desirability is below the next tier's threshold
  - upgrade succeeds when desirability meets the threshold
  - devolve fires when desirability drops far below current tier's
    threshold (cur_tier.min_desirability − 30)
  - existing housing on borderline-low desirability is NOT immediately
    devolved (the wide hysteresis is the safeguard)
"""
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




def _enable_gate(cur):
    cur.execute("RESET \"city.skip_desirability_gate\"")


def _backdate_house(cur, player_id, house_id, secs):
    cur.execute("""UPDATE public.buildings
                   SET last_processed_at = now() - make_interval(secs => %s)
                   WHERE id = %s""", (secs, str(house_id)))


def _stamp_desirability(cur, player_id, value):
    """Stamp every owned tile to the given desirability and disable the
    auto-recompute for THIS PLAYER by adding a signal that
    _pp_update_desirability respects... actually simpler: just stamp,
    accept that process_production will recompute, and call the gate
    via a manual evolve. For these tests we stamp pre-eval and skip
    process_production entirely, calling _pp_evolve_housing directly."""
    cur.execute("""UPDATE public.map_tiles SET desirability = %s
                   WHERE owner_player_id = %s""",
                (value, str(player_id)))


def _eval_housing(cur, player_id, operating_services_array='ARRAY[]::uuid[]'):
    """Run housing eval directly without going through process_production
    (which would re-derive desirability and overwrite our stamp). Now
    that upgrades are manual, also walk every newly-eligible house and
    call upgrade_house — this preserves the pre-2026-05-08 invariant
    that "after eval with conditions met, the house has stepped up"."""
    cur.execute(f"SELECT public._pp_evolve_housing(%s::uuid, {operating_services_array})",
                (str(player_id),))
    cur.execute(
        "SELECT id FROM public.buildings WHERE player_id = %s AND evolution_eligible_at IS NOT NULL",
        (str(player_id),)
    )
    for (bid,) in cur.fetchall():
        cur.execute("SAVEPOINT __eh")
        try:
            cur.execute("SELECT public.upgrade_house(%s)", (str(bid),))
            cur.execute("RELEASE SAVEPOINT __eh")
        except Exception:
            cur.execute("ROLLBACK TO SAVEPOINT __eh")


def _set_money(cur, player_id, money):
    cur.execute("UPDATE public.player_profiles SET money = %s WHERE id = %s",
                (money, str(player_id)))


def test_upgrade_blocked_below_threshold(make_player, place, cur, clear_resources):
    """Tier 2 (Cottage) requires desirability ≥ 40. Pin to 30 → upgrade
    should NOT fire even when all other prereqs are met."""
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s", (house_id,))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'berries', 5) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5", (str(p['id']),))
    _backdate_house(cur, p['id'], house_id, 240)

    _stamp_desirability(cur, p['id'], 30)  # below tier-2 threshold of 40
    _eval_housing(cur, p['id'])

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, 'should not upgrade past Mud Hut at desirability 30'


def test_upgrade_succeeds_at_threshold(make_player, place, cur, clear_resources):
    """Same setup, desirability pinned at 50 (≥ tier-2 threshold of 40)
    → Mud Hut should upgrade to Cottage."""
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 1 WHERE id = %s", (house_id,))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'berries', 5) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5", (str(p['id']),))
    # Cottage (T2) requires pottery as a lifestyle demand.
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'pottery', 5) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5", (str(p['id']),))
    _backdate_house(cur, p['id'], house_id, 240)

    _stamp_desirability(cur, p['id'], 50)  # ≥ tier-2 threshold
    _eval_housing(cur, p['id'])

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 2, 'should upgrade to Cottage at desirability 50'


def test_devolve_fires_when_far_below_threshold(make_player, place, cur, clear_resources):
    """Cottage (tier 2) min desirability is 40. Hysteresis is 30 — devolves
    when desirability < 10. Pin to 5 → should devolve back to Mud Hut."""
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    _backdate_house(cur, p['id'], house_id, 240)

    _stamp_desirability(cur, p['id'], 5)
    _eval_housing(cur, p['id'])

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 1, 'should devolve to Mud Hut at desirability 5'


def test_devolve_does_not_fire_in_hysteresis_band(make_player, place, cur, clear_resources):
    """Hysteresis safeguard: a Cottage (min_desirability 40) on a tile at
    desirability 25 should NOT devolve, since 25 ≥ (40 − 30 = 10).
    Real-world: protects existing housing when v2 gate flipped on, even
    if their tile's desirability is below the current tier's threshold."""
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    place('well', hx + 2, hy + 1)
    house_id = place('house', hx + 1, hy + 2)['building_id']
    cur.execute("UPDATE public.buildings SET housing_tier = 2 WHERE id = %s", (house_id,))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'berries', 5) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5", (str(p['id']),))
    # Cottage (T2) requires pottery to maintain its tier.
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'pottery', 5) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 5", (str(p['id']),))
    _backdate_house(cur, p['id'], house_id, 240)

    _stamp_desirability(cur, p['id'], 25)
    _eval_housing(cur, p['id'])

    cur.execute("SELECT housing_tier FROM public.buildings WHERE id = %s", (house_id,))
    assert cur.fetchone()[0] == 2, 'should NOT devolve in hysteresis band (25 ≥ 40-30)'


# ── Chebyshev service coverage in the desirability formula ──────
# Companion to the housing-gate Chebyshev switch (2026-05-20). The
# desirability formula counts +5 per nearby staffed school within range
# 5. A school at dx=2, dy=4 from a tile is Manhattan-6 (out under the
# old formula) but Chebyshev-4 (in under the new). Jill's tier-3
# townhouse at (-14, 51) sat at desirability 53 because of this exact
# mismatch — 6 services were Chebyshev-close but Manhattan-out.

def test_desirability_credits_chebyshev_close_services(make_player, place, cur, clear_resources):
    """A staffed school at dx=2, dy=4 should contribute +5 to the tile's
    desirability. Manhattan=6 (would be excluded), Chebyshev=4 (included).
    """
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 50000)
    hx, hy = p['home_x'], p['home_y']

    # Tile under test: (hx+1, hy+2). School at (hx+3, hy+6) — diagonals
    # of 2 and 4 → Manhattan=6, Chebyshev=4. The school's 2×2 footprint
    # is clear of the road cross; lay a stub road to give it perimeter
    # access so it staffs.
    place('road', hx + 1, hy + 5)
    place('road', hx + 2, hy + 5)
    place('road', hx + 3, hy + 5)
    place('school', hx + 3, hy + 6)
    # Inputs so the school operates (and stays staffed) when the next
    # _pp_update_desirability run reads is_staffed.
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'lumber', 50) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 50", (str(p['id']),))
    cur.execute("INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES (%s, 'flour',  50) ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = 50", (str(p['id']),))

    # Run a tick so the school gets staffed.
    cur.execute("SELECT public.process_production()")

    # Read the tile under test.
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id = %s AND x = %s AND y = %s""",
                (str(p['id']), hx + 1, hy + 2))
    desirability = cur.fetchone()[0]
    # The +5 school credit + tile city_base puts it well above the
    # Manhattan-only floor; assert at least the +5 came through.
    # (No other staffed services exist in the test layout.)
    assert desirability >= 50, (
        f"desirability {desirability} too low — school at Chebyshev=4 "
        "should have contributed +5; if 45 or less, the desirability calc "
        "is still using Manhattan and excluding the school."
    )


# ── Tax-office desirability penalty is uncapped (2026-05-20) ────
# Each tax office costs -3 desirability; past the old cap of -15 at
# five offices the additional offices were free, which made spamming
# them cost-neutral. Penalty now scales linearly with no cap.

def test_tax_office_penalty_scales_past_five(make_player, place, cur, clear_resources):
    """Six tax offices should drop city_base by 18 (6×3), not 15 (the
    old cap). With no services on a fresh parcel, desirability ≈
    city_base − pollution; placing six tax offices should knock the
    tile readout below where five offices would have left it."""
    _enable_gate(cur)
    p = make_player(industry='timber')
    clear_resources(p['id'])
    _set_money(cur, p['id'], 200000)
    hx, hy = p['home_x'], p['home_y']

    # Tax offices are 2×2, so space them by 2 tiles to avoid footprint
    # overlap. Skip the column on the vertical road cross.
    OFFSETS = [-7, -5, -3, 1, 3, 5]   # six x-offsets avoiding x=hx (road)
    for dx in OFFSETS[:5]:
        place('tax_man', hx + dx, hy + 3)
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id = %s AND x = %s AND y = %s""",
                (str(p['id']), hx + 1, hy + 7))
    des_5 = cur.fetchone()[0]

    # Add a sixth tax office — under the old capped formula this would
    # have been free. Under the new uncapped formula, -3 more.
    place('tax_man', hx + OFFSETS[5], hy + 3)
    cur.execute("SELECT public._pp_update_desirability(%s)", (str(p['id']),))
    cur.execute("""SELECT desirability FROM public.map_tiles
                   WHERE owner_player_id = %s AND x = %s AND y = %s""",
                (str(p['id']), hx + 5, hy + 5))
    des_6 = cur.fetchone()[0]

    assert des_6 == des_5 - 3, (
        f"6th tax office should cost -3 desirability (was {des_5}, now {des_6}); "
        "if equal, the -15 cap is still in place"
    )
