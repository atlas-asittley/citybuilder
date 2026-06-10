"""DB-driven simulation: spin up a synthetic player, run real RPCs.

The pure-Python sandbox in `balance_sim.py` is fast but a model — when
it disagrees with production, the model is wrong, not the rules. This
version uses the actual server functions for full fidelity.

Each instance opens a fresh DB transaction and rolls back on close, so
nothing persists. Synthetic player gets a real `auth.users` row and a
real `player_profiles` row via `choose_industry`.

Time advancement: instead of waiting 30 real seconds per tick, we
backdate `last_population_tick_at`, `last_food_tick_at`, and each
building's `last_processed_at` so the next `process_production()`
call thinks 30 seconds have passed. That makes a 60-minute simulation
take ~120 RPC calls = a few seconds.

Usage:
    with DBSim(industry='clay') as sim:
        sim.set_tutorial_done()  # skip tutorial trigger noise
        sim.build('house', count=4, tier=2)  # tier-2 Cottages
        sim.build('well')
        sim.build('garden')
        sim.build('clay_pit')
        sim.set_policy('clay', 'sell_surplus', reserve=0)
        result = sim.run(minutes=30)
        print(result.summary())
"""
from __future__ import annotations
import os
import json
import uuid
from dataclasses import dataclass, field
from typing import Optional
import psycopg2
import psycopg2.extras


def _connect():
    url_path = os.path.expanduser('~/.citybuilder_db_url')
    with open(url_path) as f:
        url = f.read().strip()
    c = psycopg2.connect(url)
    c.autocommit = False
    return c


@dataclass
class Snapshot:
    """One row of telemetry — captured each tick."""
    tick: int
    sim_min: float
    money: int
    population: float
    happiness: float
    crime: float
    workers_used: int
    workers_needed: int
    inventory: dict
    avg_tier: float


@dataclass
class Result:
    snapshots: list[Snapshot]

    def summary(self) -> str:
        if not self.snapshots:
            return "(empty)"
        last = self.snapshots[-1]
        return (f"After {last.sim_min:.1f} min ({last.tick} ticks):\n"
                f"  money:        ${last.money:.0f}\n"
                f"  population:   {last.population:.1f}\n"
                f"  happiness:    {last.happiness:.1f}\n"
                f"  crime:        {last.crime:.1f}\n"
                f"  workers:      {last.workers_used}/{last.workers_needed}\n"
                f"  avg housing:  tier {last.avg_tier:.1f}\n"
                f"  inventory:    {dict((k, round(v,1)) for k,v in last.inventory.items() if v >= 1)}")

    def chart(self, fields=('money', 'population', 'happiness')) -> str:
        if not self.snapshots:
            return "(empty)"
        # Downsample for readability
        step = max(1, len(self.snapshots) // 25)
        rows = []
        rows.append(f"{'min':>6} | " + ' | '.join(f"{f:>10}" for f in fields))
        rows.append('-' * len(rows[0]))
        for i, snap in enumerate(self.snapshots):
            if i % step != 0 and i != len(self.snapshots) - 1:
                continue
            cells = []
            for f in fields:
                v = getattr(snap, f, None)
                if isinstance(v, (int, float)):
                    cells.append(f"{v:>10.1f}")
                else:
                    cells.append(f"{str(v):>10}")
            rows.append(f"{snap.sim_min:>6.1f} | " + ' | '.join(cells))
        return '\n'.join(rows)

    def time_to(self, predicate, default=None):
        for snap in self.snapshots:
            if predicate(snap):
                return snap.sim_min
        return default


class DBSim:
    """Synthetic-player simulation harness. Use as a context manager."""

    TICK_SECONDS = 30

    def __init__(self, industry='timber', display_name=None, conn=None):
        self.industry = industry
        self.display_name = display_name or f"Sim_{uuid.uuid4().hex[:6]}"
        self._owned_conn = conn is None
        self.conn = conn or _connect()
        self.cur = None
        self.player_id = None
        self.snapshots: list[Snapshot] = []
        self._tick_n = 0

    def __enter__(self):
        self.cur = self.conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
        # Skip the desirability gate so housing evolves predictably during
        # mid-tier sims (matches the test conftest behavior).
        self.cur.execute("SET \"city.skip_desirability_gate\" = 'true'")
        # Outer savepoint so the simulation rolls back at __exit__.
        self.cur.execute("SAVEPOINT db_sim")
        self._create_player()
        return self

    def __exit__(self, *args):
        try:
            self.cur.execute("ROLLBACK TO SAVEPOINT db_sim")
        except psycopg2.Error:
            self.conn.rollback()
        if self.cur:
            self.cur.close()
        if self._owned_conn:
            self.conn.close()

    # ── Setup ──
    def _create_player(self):
        uid = uuid.uuid4()
        email = f"sim-{uuid.uuid4().hex[:8]}@citybuilder.test"
        self.cur.execute("""
            INSERT INTO auth.users (
                id, instance_id, aud, role, email, encrypted_password,
                email_confirmed_at, created_at, updated_at,
                raw_app_meta_data, raw_user_meta_data,
                is_super_admin, is_anonymous
            ) VALUES (
                %s, '00000000-0000-0000-0000-000000000000',
                'authenticated', 'authenticated',
                %s, '$2a$10$dummy.hash.value.for.tests.only',
                now(), now(), now(),
                '{}'::jsonb, '{}'::jsonb,
                false, false
            )
        """, (str(uid), email))
        self._set_auth(uid)
        self.cur.execute("SELECT public.choose_industry(%s, %s)",
                         (self.display_name, self.industry))
        self.cur.execute("UPDATE public.player_profiles "
                         "SET highest_housing_tier_ever = 8 WHERE id = %s",
                         (str(uid),))
        self.player_id = uid

    def _set_auth(self, user_id):
        self.cur.execute(
            "SELECT set_config('request.jwt.claims', %s, true)",
            ('{"sub": "%s", "role": "authenticated"}' % str(user_id),)
        )

    def set_tutorial_done(self):
        """Skip the tutorial entirely — useful when measuring late-game balance."""
        self.cur.execute(
            "UPDATE public.player_profiles "
            "   SET tutorial_step = 4, trade_unlocked = true "
            " WHERE id = %s",
            (str(self.player_id),)
        )
        return self

    def set_money(self, amount):
        self.cur.execute("UPDATE public.player_profiles SET money=%s WHERE id=%s",
                         (amount, str(self.player_id)))
        return self

    def set_population(self, pop):
        self.cur.execute("UPDATE public.player_profiles SET population=%s, worker_capacity=%s "
                         "WHERE id=%s", (pop, int(pop), str(self.player_id)))
        return self

    def set_inventory(self, **resources):
        """e.g. set_inventory(vegetables=50, clay=10)."""
        for key, qty in resources.items():
            self.cur.execute(
                "INSERT INTO public.inventories (player_id, resource_key, quantity) "
                "VALUES (%s, %s, %s) "
                "ON CONFLICT (player_id, resource_key) DO UPDATE SET quantity = EXCLUDED.quantity",
                (str(self.player_id), key, qty))
        return self

    def clear_resources(self):
        """Clear resource_node_keys on all this player's tiles so we can
        place buildings anywhere. Mirrors the test fixture of the same name.
        Note: this also wipes food tiles (garden_plot / pond / etc.) — call
        `stamp_food_tile` afterward if you need to place a food extractor."""
        self.cur.execute(
            "UPDATE public.map_tiles SET resource_node_key = NULL "
            " WHERE owner_player_id = %s",
            (str(self.player_id),)
        )
        return self

    def stamp_food_tile(self, x, y, kind=None):
        """Force a tile at (x,y) to have the food node_key matching this
        player's industry (or pass `kind` explicitly). Lets you place a
        food extractor on a known coordinate after clear_resources."""
        if kind is None:
            kind = {
                'timber': 'orchard_grove',
                'stone':  'pond',
                'clay':   'garden_plot',
                'iron':   'farmland',
            }[self.industry]
        self.cur.execute(
            "UPDATE public.map_tiles SET resource_node_key = %s "
            " WHERE x = %s AND y = %s",
            (kind, x, y)
        )
        return self

    def stamp_resource_tile(self, x, y, kind=None):
        """Force a tile at (x,y) to have the raw-resource node_key matching
        this player's industry (or pass `kind` explicitly)."""
        if kind is None:
            kind = self.industry  # 'timber'/'stone'/'clay'/'iron' all double as node_key
        self.cur.execute(
            "UPDATE public.map_tiles SET resource_node_key = %s "
            " WHERE x = %s AND y = %s",
            (kind, x, y)
        )
        return self

    def pave_roads_around_home(self, radius=3):
        """Pave roads on every available tile within `radius` Manhattan
        of the home tile. Mirrors what a real player would do — most
        buildings need road access to staff. Skips tiles that are
        already occupied or have a resource node."""
        self.cur.execute("SELECT home_x, home_y FROM player_profiles WHERE id=%s",
                         (str(self.player_id),))
        hx, hy = self.cur.fetchone()
        for dx in range(-radius, radius + 1):
            for dy in range(-radius, radius + 1):
                if abs(dx) + abs(dy) > radius:
                    continue
                if dx == 0 and dy == 0:
                    continue  # home tile
                self.cur.execute(
                    "SELECT id, occupied_building_id, resource_node_key, buildable "
                    "  FROM public.map_tiles WHERE x=%s AND y=%s "
                    "    AND owner_player_id = %s",
                    (hx + dx, hy + dy, str(self.player_id)))
                row = self.cur.fetchone()
                if not row or row['occupied_building_id'] or row['resource_node_key'] or not row['buildable']:
                    continue
                self.cur.execute("SAVEPOINT pave")
                try:
                    self.cur.execute(
                        "SELECT public.place_building(%s, %s)",
                        (str(row['id']), 'road'))
                    self.cur.execute("RELEASE SAVEPOINT pave")
                except psycopg2.Error:
                    self.cur.execute("ROLLBACK TO SAVEPOINT pave")
        return self

    def build(self, key, count=1, tier=None, status=None, near_home=True):
        """Place `count` buildings on UNOCCUPIED tiles in the player's
        district. For housing, optionally force a tier post-placement."""
        placed_ids = []
        for _ in range(count):
            # Find an unoccupied owned tile, preferring close-to-home.
            self.cur.execute(
                "SELECT mt.id, mt.x, mt.y, ABS(mt.x - pp.home_x) + ABS(mt.y - pp.home_y) AS d "
                "  FROM public.map_tiles mt "
                "  JOIN public.player_profiles pp ON pp.id = mt.owner_player_id "
                " WHERE pp.id = %s "
                "   AND mt.occupied_building_id IS NULL "
                "   AND mt.resource_node_key IS NULL "
                "   AND mt.buildable = true "
                " ORDER BY d ASC "
                " LIMIT 100",
                (str(self.player_id),))
            candidates = self.cur.fetchall()
            placed = False
            for row in candidates:
                tile_id = row['id']
                self.cur.execute("SAVEPOINT place_attempt")
                try:
                    self.cur.execute(
                        "SELECT public.place_building(%s, %s)",
                        (str(tile_id), key))
                    result = self.cur.fetchone()[0]
                    placed_ids.append(result['building_id'])
                    self.cur.execute("RELEASE SAVEPOINT place_attempt")
                    placed = True
                    break
                except psycopg2.Error:
                    self.cur.execute("ROLLBACK TO SAVEPOINT place_attempt")
                    continue
            if not placed:
                raise RuntimeError(f"Could not place {key}: no buildable unoccupied tiles in district")
        # Apply tier override / status
        for bid in placed_ids:
            if tier is not None:
                self.cur.execute(
                    "UPDATE public.buildings SET housing_tier=%s WHERE id=%s",
                    (tier, bid))
            if status:
                self.cur.execute(
                    "UPDATE public.buildings SET status=%s WHERE id=%s",
                    (status, bid))
        return placed_ids

    def build_food(self, key, count=1):
        """Place `count` food extractors, stamping the matching food tile
        before each placement so it succeeds. Looks for unoccupied tiles
        near home."""
        kind = {
            'orchard':      'orchard_grove',
            'fishing_pier': 'pond',
            'garden':       'garden_plot',
            'grain_farm':   'farmland',
        }[key]
        placed_ids = []
        for _ in range(count):
            self.cur.execute(
                "SELECT mt.id, mt.x, mt.y "
                "  FROM public.map_tiles mt "
                "  JOIN public.player_profiles pp ON pp.id = mt.owner_player_id "
                " WHERE pp.id = %s "
                "   AND mt.occupied_building_id IS NULL "
                "   AND mt.resource_node_key IS NULL "
                "   AND mt.buildable = true "
                " ORDER BY ABS(mt.x - pp.home_x) + ABS(mt.y - pp.home_y) ASC "
                " LIMIT 1",
                (str(self.player_id),))
            row = self.cur.fetchone()
            if not row:
                raise RuntimeError(f"No buildable unoccupied tile for {key}")
            self.cur.execute(
                "UPDATE public.map_tiles SET resource_node_key = %s WHERE id = %s",
                (kind, row['id']))
            self.cur.execute(
                "SELECT public.place_building(%s, %s)",
                (str(row['id']), key))
            placed_ids.append(self.cur.fetchone()[0]['building_id'])
        return placed_ids

    def set_policy(self, resource, mode, reserve=0):
        self.cur.execute(
            "INSERT INTO public.trade_policies (player_id, resource_key, mode, reserve_target) "
            "VALUES (%s, %s, %s, %s) "
            "ON CONFLICT (player_id, resource_key) DO UPDATE "
            "  SET mode = EXCLUDED.mode, reserve_target = EXCLUDED.reserve_target",
            (str(self.player_id), resource, mode, reserve))
        return self

    # ── Tick ──
    def _backdate(self, seconds):
        """Move the player's per-tick anchors AND every building's
        last_processed_at back by `seconds`, so the next process_production
        call thinks that much time has passed."""
        delta = f"interval '{seconds} seconds'"
        self.cur.execute(
            f"UPDATE public.player_profiles "
            f"   SET last_population_tick_at = last_population_tick_at - {delta}, "
            f"       last_food_tick_at = last_food_tick_at - {delta} "
            f" WHERE id = %s",
            (str(self.player_id),)
        )
        self.cur.execute(
            f"UPDATE public.buildings "
            f"   SET last_processed_at = last_processed_at - {delta} "
            f" WHERE player_id = %s",
            (str(self.player_id),)
        )
        # Trader cooldowns also anchored on visited_at timestamps.
        self.cur.execute(
            f"UPDATE public.trader_visits "
            f"   SET visited_at = visited_at - {delta} "
            f" WHERE player_id = %s",
            (str(self.player_id),)
        )

    def tick(self):
        """One simulated 30-second tick."""
        self._backdate(self.TICK_SECONDS)
        self.cur.execute("SELECT public.process_production()")
        data = self.cur.fetchone()[0]
        self._tick_n += 1
        # Snapshot
        self.cur.execute(
            "SELECT money, population, happiness, crime, worker_capacity, workers_used "
            "  FROM public.player_profiles WHERE id = %s",
            (str(self.player_id),)
        )
        prof = self.cur.fetchone()
        self.cur.execute(
            "SELECT COALESCE(json_object_agg(resource_key, quantity) FILTER (WHERE quantity > 0), '{}') "
            "  FROM public.inventories WHERE player_id = %s",
            (str(self.player_id),)
        )
        inv_row = self.cur.fetchone()
        inv = inv_row[0] if inv_row else {}
        if isinstance(inv, str):
            inv = json.loads(inv)
        self.cur.execute(
            "SELECT COALESCE(AVG(housing_tier), 0) FROM public.buildings b "
            " JOIN public.building_types bt ON bt.key = b.building_type_key "
            "WHERE b.player_id = %s AND b.status='active' AND bt.category='housing'",
            (str(self.player_id),)
        )
        avg_tier = float(self.cur.fetchone()[0] or 0)
        # Derive workers_needed from process_production return data
        workers_needed = int(data.get('workers_needed', 0))
        snap = Snapshot(
            tick=self._tick_n,
            sim_min=self._tick_n * (self.TICK_SECONDS / 60),
            money=int(prof['money']),
            population=float(prof['population']),
            happiness=float(prof['happiness']),
            crime=float(prof['crime']),
            workers_used=int(prof['workers_used']),
            workers_needed=workers_needed,
            inventory={k: float(v) for k, v in inv.items()},
            avg_tier=avg_tier,
        )
        self.snapshots.append(snap)
        return snap

    def run(self, minutes: float) -> Result:
        n = int(minutes * 60 / self.TICK_SECONDS)
        for _ in range(n):
            self.tick()
        return Result(self.snapshots)
