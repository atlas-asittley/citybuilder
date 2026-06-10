"""Tests for the trade progression system.

Coverage:
- is_trade_unlocked false at game start, true once all three gates met
  (≥1 active extractor, ≥1 active food extractor, ≥1 active tier-1+ house).
- district_weight returns at least 1 (housing-floor avoids divide-by-zero).
"""
import pytest
import psycopg2


def _force_tier(cur, player_id, tier):
    """Force any house in the player's district to a given tier."""
    cur.execute("""
        UPDATE public.buildings SET housing_tier = %s
        WHERE player_id = %s AND building_type_key = 'house'
    """, (tier, str(player_id)))


def _stock(cur, player_id, resource_key, qty):
    cur.execute("""
        INSERT INTO public.inventories (player_id, resource_key, quantity)
        VALUES (%s, %s, %s)
        ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity
    """, (str(player_id), resource_key, qty))


def test_trade_locked_at_game_start(make_player, cur):
    # New tutorial flow: trade is locked until the player completes the
    # tutorial sequence (4 houses → well → food → extractor). Using
    # tutorial_done=False so make_player leaves the freshly-onboarded
    # player at step 0 / trade_unlocked=false (the column default).
    p = make_player(industry='timber', tutorial_done=False)
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is False


def test_trade_unlocks_after_tutorial_sequence(make_player, place, stamp_food_tile, cur, clear_resources):
    """Trade unlocks when the player places their first food extractor —
    that's the last tutorial step (after 4 houses → well). Sticky after
    that — demolishing buildings doesn't lock it back."""
    p = make_player(industry='timber', tutorial_done=False)
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']

    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is False, 'tutorial step 0 = locked'

    # Step 0: place 4 houses → step advances to 1. Avoid the chunk
    # centerline at x=7 / y=7 within each chunk; pre-placed roads
    # there block placement.
    for dy in range(4):
        place('house', hx - 1, hy + 1 + dy)
    cur.execute("SELECT tutorial_step FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    assert cur.fetchone()[0] == 1
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is False, 'still need well + food + extractor'

    # Step 1: well → step 2.
    place('well', hx + 1, hy + 1)
    cur.execute("SELECT tutorial_step FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    assert cur.fetchone()[0] == 2

    # Step 2: food extractor → step 3.
    stamp_food_tile('orchard_grove', hx + 2, hy + 1)
    place('orchard', hx + 2, hy + 1)
    cur.execute("SELECT tutorial_step FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    assert cur.fetchone()[0] == 3
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is False, 'extractor still pending'

    # Step 3: resource extractor → step 4 + trade_unlocked.
    place('timber_camp', hx - 2, hy + 1)
    cur.execute("SELECT tutorial_step, trade_unlocked FROM public.player_profiles WHERE id = %s",
                (str(p['id']),))
    step, unlocked = cur.fetchone()
    assert step == 4
    assert unlocked is True
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is True


def test_trade_stays_unlocked_after_demolition(make_player, place, stamp_food_tile, cur, clear_resources):
    """Once unlocked, trade is sticky — even if the player demolishes the
    extractor / food / housing that originally satisfied the gate."""
    p = make_player(industry='timber', tutorial_done=True)  # already past step 4
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is True

    # Whatever buildings exist, delete them all.
    cur.execute("DELETE FROM public.buildings WHERE player_id = %s", (str(p['id']),))
    cur.execute("SELECT public.is_trade_unlocked(%s)", (str(p['id']),))
    assert cur.fetchone()[0] is True, 'sticky — should not relock'


def test_district_weight_floor(make_player, cur):
    """A player with no housing still has weight >= 1 so they participate
    in the city-rep weighted average without divide-by-zero risk."""
    p = make_player(industry='timber')
    cur.execute("SELECT public.district_weight(%s)", (str(p['id']),))
    assert cur.fetchone()[0] >= 1


def test_truck_depot_unlocks_truck_trader(make_player, place, cur, clear_resources):
    """Building a road-connected truck_depot unlocks all city truck-
    mode traders for the player. Rewritten 2026-05-10 for procedural
    traders: instead of asserting against the retired regional_hauliers
    key, assert that ANY active truck-mode trader transitions from
    locked → unlocked when the player gains depot access. The
    truck_depot INSERT itself also spawns a new procedural truck
    trader via the AFTER INSERT trigger — verify that too."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute("UPDATE public.player_profiles SET money = 50000 WHERE id = %s", (str(p['id']),))
    hx, hy = p['home_x'], p['home_y']

    # Capture an active truck trader (from earlier procedural spawns)
    # to check unlock state. Could be empty in a brand-new test DB —
    # fall back to placing the depot and re-querying.
    cur.execute("SELECT key FROM public.traders WHERE transport_mode='truck' AND is_active=true LIMIT 1")
    row = cur.fetchone()

    if row:
        existing_tk = row[0]
        cur.execute("SELECT public._trader_is_unlocked(%s, %s)", (str(p['id']), existing_tk))
        assert cur.fetchone()[0] is False, 'should be locked without a truck_depot'

    # Capture trader count pre-place; the AFTER INSERT trigger spawns one more.
    cur.execute("SELECT count(*) FROM public.traders WHERE transport_mode='truck' AND is_active=true")
    pre_count = cur.fetchone()[0]

    place('truck_depot', hx + 1, hy + 1)

    cur.execute("SELECT count(*) FROM public.traders WHERE transport_mode='truck' AND is_active=true")
    post_count = cur.fetchone()[0]
    assert post_count == pre_count + 1, (
        f'depot insert should spawn one procedural truck trader; '
        f'pre={pre_count} post={post_count}'
    )

    # Any active truck trader should now be unlocked for this player.
    cur.execute("SELECT key FROM public.traders WHERE transport_mode='truck' AND is_active=true LIMIT 1")
    a_truck = cur.fetchone()[0]
    cur.execute("SELECT public._trader_is_unlocked(%s, %s)", (str(p['id']), a_truck))
    assert cur.fetchone()[0] is True, 'should unlock after road-connected truck_depot'

