"""Tests for staffing priority + pause.

Priority tiers (smallint on `buildings.staffing_priority`):
  0 = low
  1 = normal (default)
  2 = high

Server staffing loop sorts by priority DESC, created_at ASC. RPCs:
  set_building_priority(p_building_id, p_priority)
  set_building_paused(p_building_id, p_paused)
"""


def _backdate(cur, player_id, secs):
    cur.execute("""
        UPDATE public.buildings SET last_processed_at = now() - make_interval(secs => %s)
        WHERE player_id = %s
    """, (secs, str(player_id)))


def _set_workers(cur, player_id, capacity):
    cur.execute("UPDATE public.player_profiles SET worker_capacity = %s WHERE id = %s",
                (capacity, str(player_id)))


def _stock(cur, player_id, **kv):
    for resource_key, qty in kv.items():
        cur.execute("""INSERT INTO public.inventories (player_id, resource_key, quantity)
                       VALUES (%s, %s, %s)
                       ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity""",
                    (str(player_id), resource_key, qty))


def _starve_to_under_capacity(cur, player_id, n_extractors_needed, hx, hy, place):
    """Drop a chain of extractors so total worker_cost = 10 * n.
    Used to set up scenarios where worker capacity < worker need."""
    pass  # not used; kept for clarity


# ── priority sort ───────────────────────────────────────────────

def _make_workers_tight_for_two_extractors(cur):
    """Reduce timber_camp worker_cost so base capacity (5) is enough for
    exactly one extractor (cost 4 each). Two extractors → 8 needed > 5
    capacity → only one staffs. Rollback restores worker_cost = 10."""
    cur.execute("UPDATE public.building_types SET worker_cost = 4 WHERE key = 'timber_camp'")


def test_high_priority_staffs_before_older_normal(make_player, place, cur, clear_resources):
    """An extractor placed second but with priority=high should staff
    before an older extractor at priority=normal when capacity is tight.

    We expect the high-priority extractor to produce timber while the
    normal one stays unstaffed.
    """
    # population=5 so the worker pool is exactly enough for one extractor
    # at the cost-4 override below, not two.
    p = make_player(industry='timber', population=5)
    clear_resources(p['id'])
    _make_workers_tight_for_two_extractors(cur)
    hx, hy = p['home_x'], p['home_y']
    older = place('timber_camp', hx + 1, hy + 1)['building_id']
    newer = place('timber_camp', hx + 2, hy + 1)['building_id']
    cur.execute("UPDATE public.buildings SET staffing_priority = 2 WHERE id = %s", (newer,))

    _backdate(cur, p['id'], 60)
    cur.execute("SELECT public.process_production()")

    # The staffed building's last_processed_at advances to ~now;
    # the unstaffed one keeps the backdated timestamp.
    cur.execute("SELECT id, last_processed_at FROM public.buildings WHERE id IN (%s, %s)", (older, newer))
    rows = {r[0]: r[1] for r in cur.fetchall()}
    assert rows[newer] > rows[older], \
        f"high-priority newer extractor should have staffed before older normal; got newer_lp={rows[newer]} older_lp={rows[older]}"


def test_low_priority_staffs_last(make_player, place, cur, clear_resources):
    """Low-priority older buildings should yield workers to newer normal buildings."""
    p = make_player(industry='timber', population=5)
    clear_resources(p['id'])
    _make_workers_tight_for_two_extractors(cur)
    hx, hy = p['home_x'], p['home_y']
    older = place('timber_camp', hx + 1, hy + 1)['building_id']
    newer = place('timber_camp', hx + 2, hy + 1)['building_id']
    cur.execute("UPDATE public.buildings SET staffing_priority = 0 WHERE id = %s", (older,))

    _backdate(cur, p['id'], 60)
    cur.execute("SELECT public.process_production()")

    cur.execute("SELECT id, last_processed_at FROM public.buildings WHERE id IN (%s, %s)", (older, newer))
    rows = {r[0]: r[1] for r in cur.fetchall()}
    assert rows[newer] > rows[older], \
        f"newer (normal) should have staffed before older (low); got newer_lp={rows[newer]} older_lp={rows[older]}"


def test_priority_default_is_normal(make_player, place, cur, clear_resources):
    """Newly-placed buildings should default to staffing_priority = 1."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    cur.execute("SELECT staffing_priority FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 1


# ── set_building_priority RPC ──────────────────────────────────

def test_set_building_priority_rpc(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    cur.execute("SELECT public.set_building_priority(%s, 2::smallint)", (bid,))
    cur.execute("SELECT staffing_priority FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 2
    cur.execute("SELECT public.set_building_priority(%s, 0::smallint)", (bid,))
    cur.execute("SELECT staffing_priority FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 0


def test_set_building_priority_rejects_invalid(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    import psycopg2
    try:
        cur.execute("SELECT public.set_building_priority(%s, 5::smallint)", (bid,))
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'Priority must be' in str(e)


def test_set_building_priority_rejects_non_owner(make_player, place, as_user, cur, clear_resources):
    owner = make_player(industry='timber', display_name='Owner')
    clear_resources(owner['id'])
    hx, hy = owner['home_x'], owner['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    intruder = make_player(industry='stone', display_name='Intruder')
    as_user(intruder['id'])  # switch auth context
    import psycopg2
    try:
        cur.execute("SELECT public.set_building_priority(%s, 2::smallint)", (bid,))
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'your own buildings' in str(e)


# ── pause + RPC ────────────────────────────────────────────────

def test_paused_building_consumes_no_workers(make_player, place, cur, clear_resources):
    """Paused extractor should not appear in v_staffed_ids, doesn't count
    against worker capacity, and produces nothing."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    cur.execute("SELECT public.set_building_paused(%s, true)", (bid,))
    cur.execute("SELECT status FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 'paused'
    _backdate(cur, p['id'], 60)
    cur.execute("SELECT public.process_production()")
    # No production from the paused extractor
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'",
                (str(p['id']),))
    row = cur.fetchone()
    timber = float(row[0]) if row else 0
    assert timber == 0, f"paused extractor produced timber: {timber}"
    # Workers needed should be 0 (paused excluded from staffing loop)
    cur.execute("SELECT (public.process_production()->>'workers_needed')::int")
    assert cur.fetchone()[0] == 0


def test_resume_building_via_rpc(make_player, place, cur, clear_resources):
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    cur.execute("SELECT public.set_building_paused(%s, true)", (bid,))
    cur.execute("SELECT public.set_building_paused(%s, false)", (bid,))
    cur.execute("SELECT status FROM public.buildings WHERE id = %s", (bid,))
    assert cur.fetchone()[0] == 'active'


def test_resume_does_not_dump_paused_time_into_production(make_player, place, cur, clear_resources):
    """If a building is paused for an hour and then resumed, it shouldn't
    immediately dump an hour's worth of production. The pause RPC resets
    last_processed_at = now() so production re-accrues from the resume moment."""
    p = make_player(industry='timber')
    clear_resources(p['id'])
    hx, hy = p['home_x'], p['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    # Backdate it to an hour ago, then pause+resume — should reset clock
    cur.execute("UPDATE public.buildings SET last_processed_at = now() - interval '1 hour' WHERE id = %s",
                (bid,))
    cur.execute("SELECT public.set_building_paused(%s, true)", (bid,))
    cur.execute("SELECT public.set_building_paused(%s, false)", (bid,))
    cur.execute("SELECT public.process_production()")
    cur.execute("SELECT quantity FROM public.inventories WHERE player_id = %s AND resource_key = 'timber'",
                (str(p['id']),))
    row = cur.fetchone()
    timber = float(row[0]) if row else 0
    # Should be ~0 since pause/resume just happened (sub-second elapsed)
    assert timber < 0.5, f"resume dumped backlog: {timber} timber from a sub-second window"


def test_set_building_paused_rejects_non_owner(make_player, place, as_user, cur, clear_resources):
    owner = make_player(industry='timber', display_name='Owner2')
    clear_resources(owner['id'])
    hx, hy = owner['home_x'], owner['home_y']
    bid = place('timber_camp', hx + 1, hy + 1)['building_id']
    intruder = make_player(industry='stone', display_name='Intruder2')
    as_user(intruder['id'])
    import psycopg2
    try:
        cur.execute("SELECT public.set_building_paused(%s, true)", (bid,))
        assert False, "should have raised"
    except psycopg2.errors.RaiseException as e:
        assert 'your own buildings' in str(e)
