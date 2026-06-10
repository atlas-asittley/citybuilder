"""Tests for the per-house auto-upgrade toggle (2026-05-11).

Atlas: "have it default to auto upgrade. However for the houses
that currently exist, have it toggled off. But if I build a new
house, it should initially be set to auto upgrade."

Test coverage:
  - New house placement defaults auto_upgrade = TRUE.
  - _pp_evolve_housing bumps tier immediately for auto_upgrade=TRUE
    when conditions are met.
  - _pp_evolve_housing falls through to the existing manual flow
    (stamp evolution_eligible_at) when auto_upgrade=FALSE.
  - set_house_auto_upgrade RPC flips the flag.
  - Cross-player guard: another player can't toggle your house.
"""


def _place_house_with_well(cur, place, clear_resources, p):
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 1, hy + 1)
    return place('house', hx + 1, hy + 2)['building_id']


def _set_tier(cur, bid, tier):
    cur.execute(
        "UPDATE public.buildings SET housing_tier = %s, last_processed_at = now() WHERE id = %s",
        (tier, str(bid))
    )


def test_new_house_defaults_to_auto_upgrade(make_player, place, cur, clear_resources):
    """A freshly-placed house should have auto_upgrade=TRUE."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)
    cur.execute("SELECT auto_upgrade FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] is True


def test_auto_upgrade_bumps_tier_immediately(make_player, place, cur, clear_resources):
    """When auto_upgrade is TRUE and conditions for the next tier
    are met, _pp_evolve_housing should bump the tier in place
    rather than stamping evolution_eligible_at."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)
    _set_tier(cur, bid, 2)
    # auto_upgrade defaults to true for new houses. Verify.
    cur.execute("SELECT auto_upgrade FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] is True

    # Stock everything tier-3 needs.
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES "
        "(%s, 'grain', 100), (%s, 'bread', 100), (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(p['id']), str(p['id']), str(p['id']))
    )
    # Run the tick — auto-upgrade path should bump tier.
    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    cur.execute("SELECT housing_tier, evolution_eligible_at FROM public.buildings WHERE id = %s", (str(bid),))
    tier, elig_at = cur.fetchone()
    assert tier == 3, f"auto-upgrade should bump tier 2 → 3, got {tier}"
    assert elig_at is None, "auto-upgrade skips evolution_eligible_at"

    # An auto_upgrade event should be in evolution_events.
    evs = result.get('evolution_events', [])
    auto_evs = [e for e in evs if e.get('event') == 'auto_upgrade']
    assert len(auto_evs) == 1, f"expected one auto_upgrade event, got {evs}"
    assert auto_evs[0]['to_tier'] == 3

    # Watermark must advance to match the new tier. Without this,
    # tier-gated buildings (school ≥3, temple ≥4, mosaic_workshop ≥6)
    # stay locked for players relying on auto-upgrade. Max hit this
    # 2026-05-22 (bug bedcdc47): 8 townhouses but watermark stuck at 0.
    cur.execute("SELECT highest_housing_tier_ever FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    assert cur.fetchone()[0] >= 3, 'auto-upgrade did not bump highest_housing_tier_ever'


def test_manual_path_when_auto_upgrade_false(make_player, place, cur, clear_resources):
    """When auto_upgrade is FALSE, the existing manual flow stays —
    server stamps evolution_eligible_at + counts as newly_eligible,
    no tier bump until the player calls upgrade_house RPC."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)
    _set_tier(cur, bid, 2)
    cur.execute(
        "UPDATE public.buildings SET auto_upgrade = FALSE WHERE id = %s",
        (str(bid),)
    )
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES "
        "(%s, 'grain', 100), (%s, 'bread', 100), (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(p['id']), str(p['id']), str(p['id']))
    )

    cur.execute("SELECT public.process_production()")
    result = cur.fetchone()[0]
    cur.execute("SELECT housing_tier, evolution_eligible_at FROM public.buildings WHERE id = %s", (str(bid),))
    tier, elig_at = cur.fetchone()
    assert tier == 2, f"manual flow should leave tier at 2 pending tap, got {tier}"
    assert elig_at is not None, "manual flow should set evolution_eligible_at"

    evs = result.get('evolution_events', [])
    ready_ev = [e for e in evs if e.get('event') == 'housing_ready_to_upgrade']
    assert len(ready_ev) == 1, f"expected housing_ready_to_upgrade event, got {evs}"
    assert ready_ev[0]['count'] == 1


def test_set_house_auto_upgrade_toggles_flag(make_player, place, cur, clear_resources):
    """The set_house_auto_upgrade RPC flips the column."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)

    cur.execute("SELECT public.set_house_auto_upgrade(%s, false)", (str(bid),))
    cur.execute("SELECT auto_upgrade FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] is False

    cur.execute("SELECT public.set_house_auto_upgrade(%s, true)", (str(bid),))
    cur.execute("SELECT auto_upgrade FROM public.buildings WHERE id = %s", (str(bid),))
    assert cur.fetchone()[0] is True


def test_cannot_toggle_anothers_house(make_player, place, cur, clear_resources, as_user):
    """A player can't call set_house_auto_upgrade on another player's
    building."""
    import pytest
    p1 = make_player()
    p2 = make_player()
    as_user(p1['id'])
    bid = _place_house_with_well(cur, place, clear_resources, p1)

    as_user(p2['id'])
    with pytest.raises(Exception) as exc:
        cur.execute("SELECT public.set_house_auto_upgrade(%s, true)", (str(bid),))
    assert 'Not your building' in str(exc.value), f"unexpected error: {exc.value}"
