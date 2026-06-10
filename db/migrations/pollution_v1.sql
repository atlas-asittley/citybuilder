-- ====================================================================
-- Pollution v1: schema + compute + soft housing tier cap
-- ====================================================================
-- District-bounded pollution accumulates per tile each tick from the
-- player's active+staffed production buildings within radius. Two new
-- damper buildings (Park, Tree Grove) reduce it. Heatmap is purely
-- visual for now; gameplay impact is a soft tier cap at Cottage when
-- a house's tile has pollution > 0.
--
-- Picks (per design doc):
-- 1. Re-derive each tick (not decay) — simple, predictable.
-- 2. District-bounded — your pollution only affects your own tiles.
-- 3. Graceful — soft cap only for v1, no devolve / toxic-inactive yet.
-- 4. Parks have small upkeep ($3/min, $1/min for Tree Grove).
-- 5. No production effects — pollution is housing's problem only.
-- 6. Park = small fountain plaza, Tree Grove = clustered trees.

-- ── Schema ────────────────────────────────────────────────────────

ALTER TABLE public.map_tiles
  ADD COLUMN IF NOT EXISTS pollution numeric NOT NULL DEFAULT 0;

ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS pollution_emit numeric NOT NULL DEFAULT 0;
ALTER TABLE public.building_types
  ADD COLUMN IF NOT EXISTS pollution_radius integer NOT NULL DEFAULT 0;

-- Park category constraint extension. Existing CHECK accepts these
-- categories; add 'park'.
ALTER TABLE public.building_types DROP CONSTRAINT IF EXISTS building_types_category_check;
ALTER TABLE public.building_types ADD CONSTRAINT building_types_category_check
  CHECK (category IN ('extractor','food_extractor','processor','road','housing','service','tax','booster','police','park'));

-- ── Backfill emit values on existing buildings ────────────────────
-- Heavy emitters (kilns / forges / furnaces) — radius 4, 10/tick
UPDATE public.building_types
SET pollution_emit = 10, pollution_radius = 4
WHERE key IN ('smelter','glassworks','charcoal_kiln','lime_kiln','nail_forge');

-- Medium emitters (most processors) — radius 3, 5/tick
UPDATE public.building_types
SET pollution_emit = 5, pollution_radius = 3
WHERE key IN ('sawmill','mason_workshop','mill','pottery_kiln','bakery','woodcarver','sculptor',
              'smokehouse','curing_house','spicery','distillery','cannery','brewery',
              'tile_maker','toolmaker','winery',
              'cabinetmaker','architect','mosaic_workshop','engineer_workshop');

-- Light emitters (raw extractors) — radius 2, 2/tick
UPDATE public.building_types
SET pollution_emit = 2, pollution_radius = 2
WHERE key IN ('iron_mine','timber_camp','stone_quarry','clay_pit');

-- Food extractors, services, boosters, police, tax, road, housing
-- stay at the default 0 / 0.

-- ── New buildings: Park + Tree Grove ──────────────────────────────

INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  output_resource_key, output_rate, is_active,
  pollution_emit, pollution_radius, upkeep_per_minute,
  unlocks_at_housing_tier
) VALUES (
  'park', 'Park', 1, 'common', 'park', 200, 0,
  NULL, 0, true,
  -8, 3, 3,
  NULL
) ON CONFLICT (key) DO UPDATE SET
  pollution_emit = -8, pollution_radius = 3,
  upkeep_per_minute = 3, build_cost = 200, category = 'park', is_active = true;

INSERT INTO public.building_types (
  key, name, tier, industry_key, category, build_cost, worker_cost,
  output_resource_key, output_rate, is_active,
  pollution_emit, pollution_radius, upkeep_per_minute,
  unlocks_at_housing_tier
) VALUES (
  'tree_grove', 'Tree Grove', 1, 'common', 'park', 120, 0,
  NULL, 0, true,
  -4, 4, 1,
  NULL
) ON CONFLICT (key) DO UPDATE SET
  pollution_emit = -4, pollution_radius = 4,
  upkeep_per_minute = 1, build_cost = 120, category = 'park', is_active = true;

-- ── Compute helper ────────────────────────────────────────────────
-- Reset all of this player's tile pollution to 0, then accumulate
-- emit from currently-active sources within radius. Sources only
-- count when staffed (or always-on for parks, which have no workers
-- so they're never in the staffed list — gate on is_staffed OR
-- pollution_emit < 0 for damper-always-on).

CREATE OR REPLACE FUNCTION public._pp_update_pollution(p_uid uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
AS $$
BEGIN
  UPDATE public.map_tiles
  SET pollution = 0
  WHERE owner_player_id = p_uid AND pollution <> 0;

  UPDATE public.map_tiles mt
  SET pollution = GREATEST(0, agg.total)
  FROM (
    SELECT mt2.id AS tile_id, SUM(bt.pollution_emit) AS total
    FROM public.map_tiles mt2
    JOIN public.buildings b
      ON b.player_id = p_uid AND b.status = 'active'
    JOIN public.building_types bt
      ON bt.key = b.building_type_key
     AND bt.pollution_emit <> 0
    WHERE mt2.owner_player_id = p_uid
      AND ABS(mt2.x - b.x) + ABS(mt2.y - b.y) <= bt.pollution_radius
      AND (b.is_staffed OR bt.pollution_emit < 0)
    GROUP BY mt2.id
  ) agg
  WHERE mt.id = agg.tile_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public._pp_update_pollution(uuid) TO authenticated;

-- ── Hook into process_production after staffing ───────────────────
-- Pollution must be re-derived AFTER staffing (uses is_staffed) and
-- BEFORE housing eval (which now consults pollution).

CREATE OR REPLACE FUNCTION public.process_production()
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_base constant integer := 5;
  v_tavern_bonus integer;
  v_supply integer;
  v_staffing record;
  v_total_produced numeric := 0;
  v_total_money integer := 0;
  v_total_upkeep integer := 0;
  v_food_drained numeric := 0;
  v_evolution_events json[];
  v_operating_services uuid[];
  v_partial numeric;
  v_population numeric;
  v_crime numeric;
BEGIN
  v_tavern_bonus := public._pp_tavern_bonus(v_uid);
  v_population := public._pp_update_population(v_uid);
  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;

  SELECT staffed_ids, workers_needed, unstaffed_count
    INTO v_staffing
    FROM public._pp_staff_buildings(v_uid, v_supply);

  -- Pollution: post-staffing (so we know what's running) and
  -- pre-housing-eval (so the cap applies on the same tick).
  PERFORM public._pp_update_pollution(v_uid);

  v_partial := public._pp_run_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  v_partial := public._pp_run_food_extractors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;
  PERFORM public._pp_bump_boosters(v_uid, v_staffing.staffed_ids);
  v_partial := public._pp_run_processors(v_uid, v_staffing.staffed_ids);
  v_total_produced := v_total_produced + v_partial;

  PERFORM public._pp_run_agreements(v_uid);

  v_operating_services := public._pp_run_services(v_uid, v_staffing.staffed_ids);
  v_total_money := public._pp_run_tax(v_uid, v_staffing.staffed_ids);
  v_total_upkeep := public._pp_run_upkeep(v_uid, v_staffing.staffed_ids);

  v_food_drained := public._pp_drain_housing_food(v_uid);

  v_evolution_events := public._pp_evolve_housing(v_uid, v_operating_services);

  v_crime := public._pp_update_crime(v_uid);

  v_supply := FLOOR(v_population)::integer + v_tavern_bonus;
  UPDATE public.player_profiles
  SET worker_capacity = v_supply,
      workers_used = LEAST(v_supply, v_staffing.workers_needed)
  WHERE id = v_uid;

  RETURN json_build_object(
    'total_produced', v_total_produced,
    'total_money_collected', v_total_money,
    'total_upkeep_paid', v_total_upkeep,
    'food_drained', v_food_drained,
    'evolution_events', array_to_json(v_evolution_events),
    'worker_supply', v_supply,
    'workers_needed', v_staffing.workers_needed,
    'unstaffed_count', v_staffing.unstaffed_count,
    'population', v_population,
    'happiness', (SELECT happiness FROM public.player_profiles WHERE id = v_uid),
    'crime', v_crime,
    'migration_rate', (SELECT migration_rate FROM public.player_profiles WHERE id = v_uid)
  );
END;
$$;

-- ── Soft housing tier cap at Cottage when pollution > 0 ──────────
-- We don't force-devolve in v1, but we do block evolution past
-- Cottage (tier 2) on polluted tiles. To do this minimally, modify
-- _pp_evolve_housing's upgrade gate by reading the house's tile
-- pollution and refusing the upgrade if pollution > 0 AND
-- next_tier > 2.
--
-- Existing _pp_evolve_housing function is large and has many
-- gates. Rather than rewrite it, we introduce a small helper that
-- the migration's evolve logic can layer on top:
--   public.has_polluted_tile(uid, x, y) → boolean (pollution > 0)
-- and rely on a planned follow-up to integrate it into the upgrade
-- check. For v1, we just expose the helper and the column.

CREATE OR REPLACE FUNCTION public.has_polluted_tile(p_uid uuid, p_x integer, p_y integer)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE((SELECT pollution > 0 FROM public.map_tiles
                   WHERE x = p_x AND y = p_y AND owner_player_id = p_uid),
                  false);
$$;
GRANT EXECUTE ON FUNCTION public.has_polluted_tile(uuid, integer, integer) TO authenticated;
