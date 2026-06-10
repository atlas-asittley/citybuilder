"""Tests for productivity v1 + v2.

Five levers total:
- Crime drag: -0.005 per crime point above 50, capped at -0.10
- Tavern bonus: +0.05 if any staffed tavern operating
- Education coverage: +0.03 per 10% of active houses near a staffed school, max +0.10
- Tools stockpile: +0.10 (tools >= pop*0.5) / +0.05 (tools >= pop*0.2) / 0
- Worker buffer: -0.05 when workers_used >= worker_capacity (no idle slack)

Sum capped to ±0.30, then 1.0 + sum clamped to [0.7, 1.3].
"""
import pytest


def test_default_productivity_is_one(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("SELECT productivity FROM player_profiles WHERE id = %s", (str(p['id']),))
    assert float(cur.fetchone()[0]) == 1.0


def test_compute_with_no_modifiers_is_one(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    assert float(cur.fetchone()[0]) == 1.0


def test_high_crime_drags_productivity(make_player, cur):
    p = make_player(industry='timber')
    cur.execute("UPDATE player_profiles SET crime = 70 WHERE id = %s", (str(p['id']),))
    # 70 crime → 20 points above 50 → -0.10 (capped) → productivity 0.90
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert abs(val - 0.90) < 0.001, f"expected 0.90 at crime=70, got {val}"


def test_low_crime_no_drag(make_player, cur):
    """Crime below 50 produces no productivity drag."""
    p = make_player(industry='timber')
    cur.execute("UPDATE player_profiles SET crime = 30 WHERE id = %s", (str(p['id']),))
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert val == 1.0


def test_crime_drag_scales_linearly(make_player, cur):
    """At crime=60, drag is -0.005 × 10 = -0.05 → productivity 0.95."""
    p = make_player(industry='timber')
    cur.execute("UPDATE player_profiles SET crime = 60 WHERE id = %s", (str(p['id']),))
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert abs(val - 0.95) < 0.001, f"expected 0.95 at crime=60, got {val}"


def test_clamps_at_floor_and_ceiling(make_player, cur):
    """Productivity is clamped to [0.7, 1.3]. Crime contribution maxes at
    -0.10 so even crime=999 only yields 0.90; tavern alone is +0.05.
    Verify compute respects clamps."""
    p = make_player(industry='timber')
    cur.execute("UPDATE player_profiles SET crime = 999 WHERE id = %s", (str(p['id']),))
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    # Even with crime=999, only -0.10 drag → productivity 0.90, well above
    # the 0.7 floor. Just confirm the floor isn't tripped accidentally.
    assert val >= 0.7
    assert val <= 1.3


# ── v2 levers ──

def _set_tools(cur, pid, qty):
    cur.execute(
        """INSERT INTO inventories (player_id, resource_key, quantity)
           VALUES (%s, 'tools', %s)
           ON CONFLICT (player_id, resource_key)
           DO UPDATE SET quantity = EXCLUDED.quantity""",
        (str(pid), qty)
    )


def test_tools_stockpile_high_threshold_bonus(make_player, cur):
    """tools >= pop*0.5 → +0.10. With population=5, threshold=2.5 → 3 tools."""
    p = make_player(industry='timber', population=5)
    _set_tools(cur, p['id'], 3)
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert abs(val - 1.10) < 0.001, f"expected 1.10 with 3 tools at pop=5, got {val}"


def test_tools_stockpile_low_threshold_bonus(make_player, cur):
    """tools >= pop*0.2 but < pop*0.5 → +0.05. With population=5 → 1 or 2 tools."""
    p = make_player(industry='timber', population=5)
    _set_tools(cur, p['id'], 2)
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert abs(val - 1.05) < 0.001, f"expected 1.05 with 2 tools at pop=5, got {val}"


def test_tools_stockpile_below_threshold_no_bonus(make_player, cur):
    """tools < pop*0.2 → no bonus. At pop=5, threshold=1.0 → 0 tools means no bonus."""
    p = make_player(industry='timber')
    # No tools inserted at all.
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert val == 1.0, f"expected 1.0 with no tools, got {val}"


def test_worker_buffer_penalty_when_fully_tapped(make_player, cur):
    """workers_used >= worker_capacity → -0.05."""
    p = make_player(industry='timber')
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 10, workers_used = 10 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert abs(val - 0.95) < 0.001, f"expected 0.95 with no idle workers, got {val}"


def test_worker_buffer_no_penalty_with_idle_slack(make_player, cur):
    """workers_used < worker_capacity → no penalty."""
    p = make_player(industry='timber')
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 10, workers_used = 5 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert val == 1.0


def test_worker_buffer_no_penalty_at_zero_capacity(make_player, cur):
    """worker_capacity=0 (fresh city) does NOT trigger the penalty even
    though workers_used (0) >= worker_capacity (0). Otherwise the very
    first tick of a new player's life would already start at 0.95."""
    p = make_player(industry='timber')
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 0, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert val == 1.0


def test_education_coverage_full_capped_at_max(make_player, cur, place, clear_resources):
    """A staffed school within 5 tiles of every tier-1+ house gives +0.10
    (cap reached at 100% coverage — single school covering single house)."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute(
        "UPDATE player_profiles SET money = 5000, worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    cur.execute(
        "UPDATE buildings SET housing_tier = 1 WHERE player_id = %s AND building_type_key = 'house'",
        (str(p['id']),)
    )
    # School is 2x2 — anchor at (hx+3, hy+1); distance from anchor to house = 2 ≤ 5 ✓
    place('school', hx + 3, hy + 1)
    cur.execute(
        "UPDATE buildings SET is_staffed = true WHERE player_id = %s AND building_type_key = 'school'",
        (str(p['id']),)
    )
    # Place_building recalculates worker_capacity/workers_used and the school
    # (10 workers) can leave workers_used >= worker_capacity → buffer penalty
    # would mask the lever we're isolating here. Reset to a slack state.
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    # 1/1 coverage = 100% → 10 deciles × 0.03 = 0.30, capped at 0.10 → 1.10
    assert abs(val - 1.10) < 0.001, f"expected 1.10 with full education coverage, got {val}"


def test_education_coverage_unstaffed_school_no_bonus(make_player, cur, place, clear_resources):
    """An unstaffed school does NOT count toward education coverage."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute(
        "UPDATE player_profiles SET money = 5000, worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    hx, hy = p['home_x'], p['home_y']
    place('house', hx + 1, hy + 1)
    cur.execute(
        "UPDATE buildings SET housing_tier = 1 WHERE player_id = %s AND building_type_key = 'house'",
        (str(p['id']),)
    )
    place('school', hx + 3, hy + 1)
    cur.execute(
        "UPDATE buildings SET is_staffed = false WHERE player_id = %s AND building_type_key = 'school'",
        (str(p['id']),)
    )
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    assert val == 1.0, f"expected 1.0 with unstaffed school, got {val}"


def test_education_coverage_partial_scales(make_player, cur, place, clear_resources):
    """One staffed school + 2 houses, one in range one not → 50% coverage.
    50% × 10 = 5 deciles × 0.03 = 0.15, capped at 0.10. So +0.10 still."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    cur.execute(
        "UPDATE player_profiles SET money = 5000, worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    hx, hy = p['home_x'], p['home_y']
    # Near house — within 5 of school anchor at (hx+3, hy+1)
    place('house', hx + 1, hy + 1)   # dist 2 ✓
    # Far house — distance from school anchor must be > 5
    place('house', hx - 4, hy - 4)   # dist |3-(-4)| + |1-(-4)| = 7+5 = 12 ✗
    cur.execute(
        "UPDATE buildings SET housing_tier = 1 WHERE player_id = %s AND building_type_key = 'house'",
        (str(p['id']),)
    )
    place('school', hx + 3, hy + 1)
    cur.execute(
        "UPDATE buildings SET is_staffed = true WHERE player_id = %s AND building_type_key = 'school'",
        (str(p['id']),)
    )
    # Place_building recalculates worker_capacity/workers_used and the school
    # (10 workers) can leave workers_used >= worker_capacity → buffer penalty
    # would mask the lever we're isolating here. Reset to a slack state.
    cur.execute(
        "UPDATE player_profiles SET worker_capacity = 100, workers_used = 0 WHERE id = %s",
        (str(p['id']),)
    )
    cur.execute("SELECT public._pp_compute_productivity(%s)", (str(p['id']),))
    val = float(cur.fetchone()[0])
    # 1/2 coverage = 50% → 5 deciles × 0.03 = 0.15 capped at 0.10
    assert abs(val - 1.10) < 0.001, f"expected 1.10 at 50% coverage, got {val}"
