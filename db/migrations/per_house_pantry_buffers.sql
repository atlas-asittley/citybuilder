-- ─────────────────────────────────────────────────────────────────────
-- Per-house pantry buffers (2026-05-09).
--
-- Atlas's design call: "you would think that a house would devolve
-- after its supply of that resource runs out [...] not as soon as
-- there's not enough of a particular resource for them to stay at
-- the evolution at the rate."
--
-- Old model: each tick, every house draws from the city's shared
-- inventory pool. The moment the pool empties, *every* house at the
-- gated tier simultaneously fails its consumption check and starts
-- the devolve countdown — a thundering herd. Drew lost ~96 worker
-- capacity in one go when his Townhouses cascaded back to Cottages.
--
-- New model: every house has its own pantry per gated resource.
-- Consumption is from the pantry. Refill happens once per tick from
-- the city pool, allocated proportionally to the per-house deficit.
-- When the city stock empties, pantries gradually drain — devolves
-- trickle out one-by-one over ~30 minutes instead of all at once.
--
-- Capacity rule: each pantry holds 30 minutes of consumption at the
-- current tier rate. Devolve grace stays at 30s on top, so the total
-- buffer between "city stock empties" and "first house starts to
-- devolve" is ~30 minutes — enough to react with a trade or a new
-- producer.
-- ─────────────────────────────────────────────────────────────────────

-- ── Schema ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.building_resource_buffers (
  building_id  uuid    NOT NULL REFERENCES public.buildings(id) ON DELETE CASCADE,
  resource_key text    NOT NULL,
  quantity     numeric NOT NULL DEFAULT 0,
  capacity     numeric NOT NULL DEFAULT 0,
  PRIMARY KEY (building_id, resource_key)
);

ALTER TABLE public.building_resource_buffers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "select_own_pantry" ON public.building_resource_buffers;
CREATE POLICY "select_own_pantry" ON public.building_resource_buffers
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM public.buildings b
      WHERE b.id = building_id AND b.player_id = auth.uid()
    )
  );


-- ── Capacity rule ───────────────────────────────────────────────────
-- 30 minutes of consumption at the given rate.
CREATE OR REPLACE FUNCTION public._pantry_capacity(p_rate numeric)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$ SELECT GREATEST(0, p_rate * 30) $$;


-- ── Sync function ───────────────────────────────────────────────────
-- Ensures buffer rows exist for every gated resource at this house's
-- current tier, with capacities matching the tier's consumption rate.
-- New rows start full (so a freshly-placed or freshly-upgraded house
-- doesn't devolve on the next tick before refill).
--
-- Called by triggers on INSERT / housing_tier UPDATE, and by the
-- migration seed below.
CREATE OR REPLACE FUNCTION public._sync_house_buffers(p_building_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tier int;
  v_cat text;
BEGIN
  SELECT b.housing_tier, bt.category
  INTO v_tier, v_cat
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.id = p_building_id;

  IF v_cat IS DISTINCT FROM 'housing' THEN
    DELETE FROM public.building_resource_buffers WHERE building_id = p_building_id;
    RETURN;
  END IF;

  -- Add / update rows for this tier's gated resources. New rows arrive
  -- at full capacity; existing rows keep their quantity (clamped to
  -- new capacity in case the rate dropped from a devolve).
  WITH demand AS (
    SELECT 'food'::text AS rk, public._pantry_capacity(htc.food_per_minute) AS cap
    FROM public.housing_tier_config htc
    WHERE htc.tier = v_tier AND htc.food_per_minute > 0
    UNION ALL
    SELECT hld.resource_key, public._pantry_capacity(hld.qty_per_minute)
    FROM public.housing_lifestyle_demands hld
    WHERE hld.tier = v_tier
  )
  INSERT INTO public.building_resource_buffers (building_id, resource_key, quantity, capacity)
  SELECT p_building_id, d.rk, d.cap, d.cap
  FROM demand d
  ON CONFLICT (building_id, resource_key) DO UPDATE SET
    capacity = EXCLUDED.capacity,
    quantity = LEAST(public.building_resource_buffers.quantity, EXCLUDED.capacity);

  -- Remove buffers no longer demanded at the (possibly lower) current tier.
  DELETE FROM public.building_resource_buffers brb
  WHERE brb.building_id = p_building_id
    AND brb.resource_key NOT IN (
      SELECT 'food' WHERE EXISTS (
        SELECT 1 FROM public.housing_tier_config htc
        WHERE htc.tier = v_tier AND htc.food_per_minute > 0
      )
      UNION
      SELECT hld.resource_key FROM public.housing_lifestyle_demands hld
      WHERE hld.tier = v_tier
    );
END;
$$;


-- ── Triggers: keep buffers in sync with building lifecycle ──────────
CREATE OR REPLACE FUNCTION public._trg_house_buffers_insert()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public._sync_house_buffers(NEW.id);
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_house_buffers_tier_change()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.housing_tier IS DISTINCT FROM OLD.housing_tier THEN
    PERFORM public._sync_house_buffers(NEW.id);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_house_buffers_insert ON public.buildings;
CREATE TRIGGER trg_house_buffers_insert
  AFTER INSERT ON public.buildings
  FOR EACH ROW EXECUTE FUNCTION public._trg_house_buffers_insert();

DROP TRIGGER IF EXISTS trg_house_buffers_tier_change ON public.buildings;
CREATE TRIGGER trg_house_buffers_tier_change
  AFTER UPDATE OF housing_tier ON public.buildings
  FOR EACH ROW EXECUTE FUNCTION public._trg_house_buffers_tier_change();


-- ── Refill phase ────────────────────────────────────────────────────
-- For each gated resource, top up every house's buffer toward capacity
-- by drawing from the city's inventory pool. When supply is shorter
-- than total deficit, allocate proportionally to each house's deficit
-- share (so a house that's nearly empty gets the same fraction of its
-- deficit filled as a house that's only slightly low).
--
-- Food is the special case: a single 'food' buffer per house, refilled
-- from the *aggregate* of all is_food resources in inventory using the
-- existing proportional-drain pattern.
CREATE OR REPLACE FUNCTION public._pp_refill_pantries(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_resource record;
  v_avail numeric;
  v_taken numeric;
  v_factor numeric;
BEGIN
  FOR v_resource IN
    SELECT brb.resource_key,
           SUM(GREATEST(0, brb.capacity - brb.quantity)) AS need
    FROM public.building_resource_buffers brb
    JOIN public.buildings b ON b.id = brb.building_id
    WHERE b.player_id = p_uid AND b.status = 'active'
    GROUP BY brb.resource_key
    HAVING SUM(GREATEST(0, brb.capacity - brb.quantity)) > 0
  LOOP
    -- Reset per iteration. SELECT INTO leaves v_avail unchanged when
    -- the underlying row doesn't exist (the bug: prior iteration's
    -- value or NULL would leak through, and LEAST(need, NULL) returns
    -- need — refill would then "find" supply that wasn't there).
    v_avail := 0;
    v_taken := 0;

    IF v_resource.resource_key = 'food' THEN
      SELECT COALESCE(SUM(i.quantity), 0) INTO v_avail
      FROM public.inventories i
      JOIN public.resources r ON r.key = i.resource_key
      WHERE i.player_id = p_uid AND r.is_food;

      v_taken := LEAST(v_resource.need, COALESCE(v_avail, 0));
      IF v_taken > 0 AND v_avail > 0 THEN
        v_factor := 1.0 - (v_taken / v_avail);
        UPDATE public.inventories i
        SET quantity = ROUND(i.quantity * v_factor, 6)
        FROM public.resources r
        WHERE i.resource_key = r.key AND r.is_food
          AND i.player_id = p_uid;
      END IF;
    ELSE
      SELECT COALESCE(quantity, 0) INTO v_avail
      FROM public.inventories
      WHERE player_id = p_uid AND resource_key = v_resource.resource_key;

      v_taken := LEAST(v_resource.need, COALESCE(v_avail, 0));
      IF v_taken > 0 THEN
        UPDATE public.inventories
        SET quantity = ROUND(GREATEST(0, quantity - v_taken), 6),
            updated_at = now()
        WHERE player_id = p_uid AND resource_key = v_resource.resource_key;
      END IF;
    END IF;

    -- Distribute v_taken across each house's deficit proportionally.
    IF v_taken > 0 THEN
      UPDATE public.building_resource_buffers brb
      SET quantity = LEAST(
        brb.capacity,
        brb.quantity + (brb.capacity - brb.quantity) * (v_taken / v_resource.need)
      )
      FROM public.buildings b
      WHERE brb.building_id = b.id
        AND b.player_id = p_uid AND b.status = 'active'
        AND brb.resource_key = v_resource.resource_key
        AND brb.quantity < brb.capacity;
    END IF;
  END LOOP;
END;
$$;


-- ── Consume phase ───────────────────────────────────────────────────
-- Subtract per-house consumption (rate * elapsed minutes) from each
-- buffer. Clamps at 0 — empty pantries don't go negative.
CREATE OR REPLACE FUNCTION public._pp_consume_pantries(p_uid uuid, p_minutes numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  IF p_minutes <= 0 THEN RETURN; END IF;

  -- Compute per-(building, resource) consumption rate first, then
  -- apply the decrement. Avoids correlated subqueries / LATERAL-on-
  -- target-table issues with UPDATE ... FROM.
  WITH rates AS (
    SELECT brb.building_id,
           brb.resource_key,
           CASE
             WHEN brb.resource_key = 'food' THEN COALESCE(htc.food_per_minute, 0)
             ELSE COALESCE(hld.qty_per_minute, 0)
           END AS rate
    FROM public.building_resource_buffers brb
    JOIN public.buildings b ON b.id = brb.building_id
    JOIN public.building_types bt ON bt.key = b.building_type_key
    JOIN public.housing_tier_config htc ON htc.tier = b.housing_tier
    LEFT JOIN public.housing_lifestyle_demands hld
      ON hld.tier = b.housing_tier AND hld.resource_key = brb.resource_key
    WHERE b.player_id = p_uid AND b.status = 'active'
      AND bt.category = 'housing'
  )
  UPDATE public.building_resource_buffers brb
  SET quantity = ROUND(GREATEST(0, brb.quantity - rates.rate * p_minutes), 6)
  FROM rates
  WHERE rates.building_id = brb.building_id
    AND rates.resource_key = brb.resource_key;
END;
$$;


-- ── Replace _pp_drain_housing_food ──────────────────────────────────
-- Same external contract (called by process_production at line 60,
-- returns numeric for the food-drained metric), but internally now
-- routes through refill → consume on the per-house buffers.
--
-- Returns the amount of food drawn from city inventory this tick
-- (for the existing v_food_drained accounting downstream).
CREATE OR REPLACE FUNCTION public._pp_drain_housing_food(p_uid uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_elapsed numeric;
  v_minutes numeric;
  v_food_before numeric;
  v_food_after numeric;
BEGIN
  SELECT EXTRACT(EPOCH FROM (v_now - last_food_tick_at)) INTO v_elapsed
  FROM public.player_profiles WHERE id = p_uid;
  IF v_elapsed IS NULL OR v_elapsed < 0 THEN v_elapsed := 0; END IF;
  v_minutes := v_elapsed / 60.0;

  -- Snapshot food inventory pre-refill so we can return how much was drawn.
  SELECT COALESCE(SUM(i.quantity), 0) INTO v_food_before
  FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food;

  -- Consume FIRST, refill SECOND. If we refilled first, a fresh-from-
  -- seed pantry would already be at capacity → refill would compute
  -- deficit=0 → no city stock drawn → consume would then dip the pantry
  -- → next tick would have 1 minute of consumption to refill instead
  -- of the elapsed amount. Net: city stock would lag by one tick of
  -- demand, breaking tests that expect city grain to drop by 0.24 in
  -- 60s. Consume-then-refill matches the existing rate semantics.
  IF v_minutes > 0 THEN
    PERFORM public._pp_consume_pantries(p_uid, v_minutes);
  END IF;
  PERFORM public._pp_refill_pantries(p_uid);

  SELECT COALESCE(SUM(i.quantity), 0) INTO v_food_after
  FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
  WHERE i.player_id = p_uid AND r.is_food;

  UPDATE public.player_profiles SET last_food_tick_at = v_now WHERE id = p_uid;
  RETURN GREATEST(0, v_food_before - v_food_after);
END;
$$;


-- ── Update _pp_evolve_housing to use per-house buffer state ─────────
-- Devolve gate now reads each house's own buffer for food + lifestyle.
-- Upgrade gate keeps reading global inventory (next tier's buffers
-- don't exist yet; the city stock is the right indicator that a new
-- tier is sustainable).
CREATE OR REPLACE FUNCTION public._pp_evolve_housing(p_uid uuid, p_operating_services uuid[])
RETURNS json[]
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_now timestamptz := now();
  v_events json[] := ARRAY[]::json[];
  v_house record;
  v_cur_tier record;
  v_next_tier record;
  v_prev_tier record;
  v_elapsed numeric;
  v_has_road boolean;
  v_has_well boolean;
  v_has_any_well boolean;
  v_well_for_next boolean;
  v_well_for_cur boolean;
  v_has_school boolean;
  v_has_temple boolean;
  v_has_bathhouse boolean;
  v_has_food_global boolean;
  v_has_luxury_food boolean;
  v_has_industrial_luxury boolean;
  v_has_all_industrial_luxuries boolean;
  v_il_count integer;
  v_il_total integer;
  v_should_upgrade boolean;
  v_should_devolve boolean;
  v_desirability integer;
  v_skip_des boolean;
  v_in_tutorial boolean;
  v_lifestyle_for_cur_ok boolean;
  v_lifestyle_for_next_ok boolean;
  v_house_food_ok boolean;
  v_newly_eligible integer := 0;
BEGIN
  v_skip_des := COALESCE(current_setting('city.skip_desirability_gate', true), 'false') = 'true';

  SELECT (tutorial_step < 4) INTO v_in_tutorial
  FROM public.player_profiles WHERE id = p_uid;
  v_in_tutorial := COALESCE(v_in_tutorial, false);

  v_has_any_well := public.has_any_well(p_uid);

  -- Global food/luxury checks for the upgrade gate.
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_food AND i.quantity > 0) INTO v_has_food_global;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_luxury_food AND i.quantity > 0) INTO v_has_luxury_food;
  SELECT EXISTS (SELECT 1 FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
                 WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0) INTO v_has_industrial_luxury;
  SELECT COUNT(*) INTO v_il_count FROM public.inventories i JOIN public.resources r ON r.key = i.resource_key
   WHERE i.player_id = p_uid AND r.is_industrial_luxury AND i.quantity > 0;
  SELECT COUNT(*) INTO v_il_total FROM public.resources WHERE is_industrial_luxury;
  v_has_all_industrial_luxuries := (v_il_total > 0 AND v_il_count >= v_il_total);

  FOR v_house IN
    SELECT b.id, b.x, b.y, b.housing_tier, b.last_processed_at, b.evolution_eligible_at
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'housing'
    FOR UPDATE OF b
  LOOP
    SELECT * INTO v_cur_tier  FROM public.housing_tier_config WHERE tier = v_house.housing_tier;
    SELECT * INTO v_next_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier + 1;
    SELECT * INTO v_prev_tier FROM public.housing_tier_config WHERE tier = v_house.housing_tier - 1;
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_house.last_processed_at));
    v_has_road := public.has_road_access(p_uid, v_house.x, v_house.y);
    v_has_well := public.has_well_access(p_uid, v_house.x, v_house.y);
    v_has_school := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'school'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 5);
    v_has_temple := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'temple'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 6);
    v_has_bathhouse := EXISTS (SELECT 1 FROM public.buildings b2
      WHERE b2.player_id = p_uid AND b2.building_type_key = 'bathhouse'
        AND b2.id = ANY(p_operating_services)
        AND ABS(b2.x - v_house.x) + ABS(b2.y - v_house.y) <= 4);

    SELECT COALESCE(desirability, 50) INTO v_desirability
    FROM public.map_tiles
    WHERE x = v_house.x AND y = v_house.y AND owner_player_id = p_uid;

    v_well_for_next := CASE
      WHEN v_next_tier IS NULL THEN false
      WHEN v_next_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;
    v_well_for_cur := CASE
      WHEN v_cur_tier.tier = 1 THEN v_has_any_well
      ELSE v_has_well
    END;

    -- ── Per-house pantry checks for cur-tier devolve gate ──
    -- Food: this house's own 'food' buffer must have something left.
    SELECT COALESCE(brb.quantity, 0) > 0 INTO v_house_food_ok
    FROM public.building_resource_buffers brb
    WHERE brb.building_id = v_house.id AND brb.resource_key = 'food';
    -- If there's no buffer row at all, it means this tier doesn't gate on
    -- food. Treat as OK.
    IF NOT FOUND THEN v_house_food_ok := true; END IF;

    -- Lifestyle: every demanded resource at cur tier must have a non-zero
    -- buffer on THIS house.
    SELECT NOT EXISTS (
      SELECT 1 FROM public.housing_lifestyle_demands hld
      WHERE hld.tier = v_house.housing_tier
        AND COALESCE(
          (SELECT brb.quantity FROM public.building_resource_buffers brb
           WHERE brb.building_id = v_house.id AND brb.resource_key = hld.resource_key),
          0
        ) <= 0
    ) INTO v_lifestyle_for_cur_ok;

    -- ── Upgrade gate (next tier) still uses global inventory ──
    IF v_next_tier IS NOT NULL THEN
      SELECT NOT EXISTS (
        SELECT 1 FROM public.housing_lifestyle_demands hld
        WHERE hld.tier = v_next_tier.tier
          AND COALESCE((SELECT quantity FROM public.inventories i
                         WHERE i.player_id = p_uid AND i.resource_key = hld.resource_key), 0) <= 0
      ) INTO v_lifestyle_for_next_ok;
    ELSE
      v_lifestyle_for_next_ok := false;
    END IF;

    v_should_upgrade := v_next_tier IS NOT NULL
      AND (NOT v_next_tier.needs_road OR v_has_road)
      AND (NOT v_next_tier.needs_well OR v_well_for_next)
      AND (NOT v_next_tier.needs_food OR v_has_food_global)
      AND (NOT v_next_tier.needs_school OR v_has_school)
      AND (NOT v_next_tier.needs_temple OR v_has_temple)
      AND (NOT v_next_tier.needs_luxury_food OR v_has_luxury_food)
      AND (NOT v_next_tier.needs_industrial_luxury OR v_has_industrial_luxury)
      AND (NOT v_next_tier.needs_all_industrial_luxuries OR v_has_all_industrial_luxuries)
      AND v_lifestyle_for_next_ok
      AND (v_skip_des OR v_desirability >= COALESCE(v_next_tier.min_desirability, 0));

    -- Devolve gate now reads per-house buffers for food + lifestyle.
    v_should_devolve := NOT v_in_tutorial
      AND v_prev_tier IS NOT NULL
      AND ((v_cur_tier.needs_road AND NOT v_has_road)
           OR (v_cur_tier.needs_well AND NOT v_well_for_cur)
           OR (v_cur_tier.needs_food AND NOT v_house_food_ok)
           OR (v_cur_tier.needs_school AND NOT v_has_school)
           OR (v_cur_tier.needs_temple AND NOT v_has_temple)
           OR (v_cur_tier.needs_luxury_food AND NOT v_has_luxury_food)
           OR (v_cur_tier.needs_industrial_luxury AND NOT v_has_industrial_luxury)
           OR (v_cur_tier.needs_all_industrial_luxuries AND NOT v_has_all_industrial_luxuries)
           OR NOT v_lifestyle_for_cur_ok
           OR (NOT v_skip_des AND v_desirability < COALESCE(v_cur_tier.min_desirability, 0) - 30))
      AND NOT v_has_bathhouse
      AND v_elapsed >= COALESCE(v_cur_tier.devolve_secs, 30);

    IF v_should_upgrade THEN
      IF v_house.evolution_eligible_at IS NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = v_now WHERE id = v_house.id;
        v_newly_eligible := v_newly_eligible + 1;
      END IF;
    ELSE
      IF v_house.evolution_eligible_at IS NOT NULL THEN
        UPDATE public.buildings SET evolution_eligible_at = NULL WHERE id = v_house.id;
      END IF;
    END IF;

    IF v_should_devolve THEN
      UPDATE public.buildings
         SET housing_tier = housing_tier - 1,
             last_processed_at = v_now,
             evolution_eligible_at = NULL
       WHERE id = v_house.id;
      v_events := v_events || jsonb_build_object(
        'building_id', v_house.id, 'event', 'devolve',
        'from_tier', v_house.housing_tier, 'to_tier', v_house.housing_tier - 1
      )::json;
    END IF;
  END LOOP;

  IF v_newly_eligible > 0 THEN
    v_events := v_events || jsonb_build_object(
      'event', 'housing_ready_to_upgrade',
      'count', v_newly_eligible
    )::json;
  END IF;

  RETURN v_events;
END;
$$;


-- ── Backfill: seed buffers for every existing house at full capacity.
-- One-time on migration apply. Subsequent INSERTs go through the
-- trigger. Use DO block so the migration is idempotent (re-running
-- just hits ON CONFLICT DO NOTHING).
DO $$
DECLARE
  v_h record;
BEGIN
  FOR v_h IN
    SELECT b.id FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE bt.category = 'housing'
  LOOP
    PERFORM public._sync_house_buffers(v_h.id);
  END LOOP;
END;
$$;
