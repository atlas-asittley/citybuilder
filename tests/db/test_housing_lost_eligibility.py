"""Test the housing_lost_eligibility event from _pp_evolve_housing.

Bug 2026-05-09 (Jill): client kept showing the Upgrade button after
the server had cleared evolution_eligible_at because no event was
emitted on the clearing transition — game.js refetches buildings
only when evolution_events is non-empty. The fix mirrors the
'housing_ready_to_upgrade' count with a 'housing_lost_eligibility'
count for the lose-direction so any transition triggers a refetch.
"""
import json
import datetime


def _set_house_tier(cur, building_id, tier):
    cur.execute(
        "UPDATE public.buildings SET housing_tier = %s, last_processed_at = now() WHERE id = %s",
        (tier, str(building_id))
    )


def _place_house_with_well(cur, place, clear_resources, player):
    clear_resources(player['id'])
    hx, hy = player['home_x'], player['home_y']
    place('well', hx + 1, hy + 1)
    return place('house', hx + 1, hy + 2)['building_id']


def _run_pp_get_events(cur):
    cur.execute("SELECT public.process_production()")
    return cur.fetchone()[0].get('evolution_events', [])


def test_lost_eligibility_event_fires_when_flag_cleared(cur, make_player, place, clear_resources):
    """Walk a tier-2 cottage from eligible-for-tier-3 → not-eligible
    and confirm the housing_lost_eligibility event fires with count 1."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 2)
    # Force manual upgrade mode — lost-eligibility is a manual-flow
    # concept (auto-upgrade skips the eligible_at stamp and goes
    # straight to tier bump, so there's no "lost" state to fire).
    cur.execute("UPDATE public.buildings SET auto_upgrade = FALSE WHERE id = %s", (bid,))
    # Stock everything tier 3 needs (food + bread for lifestyle gate +
    # pottery already there from default tier 2 buffer).
    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES "
        "(%s, 'grain', 100), (%s, 'bread', 100), (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(p['id']), str(p['id']), str(p['id']))
    )
    # Run a tick so the eligible-for-tier-3 flag gets set.
    events = _run_pp_get_events(cur)
    cur.execute("SELECT evolution_eligible_at FROM public.buildings WHERE id = %s", (bid,))
    eligible_now = cur.fetchone()[0]
    assert eligible_now is not None, f"house should be eligible after tick; events={events}"

    # Now break tier-3 conditions: drain bread to 0 (tier 3 needs bread
    # as a lifestyle good — see housing_lifestyle_demands).
    cur.execute(
        "UPDATE public.inventories SET quantity = 0 "
        "WHERE player_id = %s AND resource_key = 'bread'",
        (str(p['id']),)
    )
    # Re-run process_production. This should clear the flag AND emit
    # housing_lost_eligibility.
    events2 = _run_pp_get_events(cur)
    cur.execute("SELECT evolution_eligible_at FROM public.buildings WHERE id = %s", (bid,))
    eligible_after = cur.fetchone()[0]
    assert eligible_after is None, "flag should have been cleared"

    # The events array should contain a housing_lost_eligibility entry
    # with count == 1.
    lost_events = [e for e in events2 if e.get('event') == 'housing_lost_eligibility']
    assert len(lost_events) == 1, f"expected one lost_eligibility event, got {events2}"
    assert lost_events[0].get('count') == 1, f"count should be 1, got {lost_events[0]}"


def test_lost_eligibility_count_matches_house_count(cur, make_player, place, clear_resources):
    """Multiple houses transitioning at once should produce a single
    event with count = N."""
    p = make_player()
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    place('well', hx + 1, hy + 1)
    house_ids = [
        place('house', hx + 1, hy + 2)['building_id'],
        place('house', hx + 2, hy + 2)['building_id'],
        place('house', hx + 3, hy + 2)['building_id'],
    ]
    for bid in house_ids:
        _set_house_tier(cur, bid, 2)

    cur.execute(
        "INSERT INTO public.inventories (player_id, resource_key, quantity) VALUES "
        "(%s, 'grain', 100), (%s, 'bread', 100), (%s, 'pottery', 100) "
        "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
        (str(p['id']), str(p['id']), str(p['id']))
    )
    _run_pp_get_events(cur)
    # Mark all eligible by hand (faster than waiting for full conditions).
    cur.execute(
        "UPDATE public.buildings SET evolution_eligible_at = now() WHERE id = ANY(%s::uuid[])",
        ([str(b) for b in house_ids],)
    )
    # Now break conditions for ALL of them at once.
    cur.execute(
        "UPDATE public.inventories SET quantity = 0 "
        "WHERE player_id = %s AND resource_key = 'bread'",
        (str(p['id']),)
    )
    events = _run_pp_get_events(cur)
    lost = [e for e in events if e.get('event') == 'housing_lost_eligibility']
    assert len(lost) == 1, f"one summary event expected, got {events}"
    assert lost[0].get('count') == 3, f"count should be 3 (all houses), got {lost[0]}"


def test_no_lost_event_when_nothing_changes(cur, make_player, place, clear_resources):
    """If no house's eligibility transitions (steady state), the
    housing_lost_eligibility event should NOT appear."""
    p = make_player()
    bid = _place_house_with_well(cur, place, clear_resources, p)
    _set_house_tier(cur, bid, 2)
    # No conditions met for tier 3 (no bread). Run a tick — no
    # transition (was already not-eligible, stays not-eligible).
    events = _run_pp_get_events(cur)
    lost = [e for e in events if e.get('event') == 'housing_lost_eligibility']
    assert lost == [], f"no transitions → no lost event, got {events}"
