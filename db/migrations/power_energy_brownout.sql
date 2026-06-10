-- ============================================================================
-- power_energy_brownout.sql  (Civic Metrics Expansion — Phase 2b)
-- ----------------------------------------------------------------------------
-- Gives POWER teeth: an undersupplied grid throttles productivity (brownout).
-- See citybuilder-game/docs/CIVIC_METRICS_EXPANSION.md §7.
--
-- !! APPLY ORDER: after power_energy.sql (reads power_capacity/power_demand).
--    Independent of waste/roads. Migrations apply chronologically.
--
-- SAFE-FOR-LIVE design: the penalty is "electrified-only" — it applies ONLY
-- when the city has built power (power_capacity > 0) AND demand exceeds it.
-- A pre-electrification city (capacity = 0, like every existing city at
-- rollout) is NOT penalised, so going live changes nothing for them. Once you
-- build your first plant you're "on the grid" and must keep capacity ≥ demand.
-- Floor 0.75 keeps even a badly-undersupplied grid from collapsing.
--
-- Reads the power_capacity/power_demand written by _pp_update_power on the
-- PREVIOUS tick (productivity is computed early in _pp_for_uid, power late) —
-- a one-tick lag, immaterial.
--
-- Rebuilt from the live _pp_compute_productivity + the power factor at the end.
-- Idempotent. ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._pp_compute_productivity(p_uid uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_crime numeric;
  v_tavern boolean;
  v_score numeric := 0;
  v_total_houses integer;
  v_covered_houses integer;
  v_coverage numeric;
  v_edu_bonus numeric;
  v_population numeric;
  v_pop_floor integer;
  v_tools numeric;
  v_workers_used integer;
  v_worker_capacity integer;
  v_productivity numeric;
  v_pcap numeric;
  v_pdem numeric;
BEGIN
  SELECT COALESCE(crime, 0), COALESCE(population, 0),
         COALESCE(workers_used, 0), COALESCE(worker_capacity, 0),
         COALESCE(power_capacity, 0), COALESCE(power_demand, 0)
  INTO v_crime, v_population, v_workers_used, v_worker_capacity,
       v_pcap, v_pdem
  FROM public.player_profiles WHERE id = p_uid;

  IF v_crime > 50 THEN
    v_score := v_score - LEAST(0.10, (v_crime - 50) * 0.005);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.buildings b
    WHERE b.player_id = p_uid AND b.status = 'active' AND b.is_staffed
      AND b.building_type_key = 'tavern'
  ) INTO v_tavern;
  IF v_tavern THEN v_score := v_score + 0.05; END IF;

  SELECT COUNT(*) INTO v_total_houses
  FROM public.buildings b
  JOIN public.building_types bt ON bt.key = b.building_type_key
  WHERE b.player_id = p_uid AND b.status = 'active'
    AND bt.category = 'housing' AND COALESCE(b.housing_tier, 0) >= 1;

  IF v_total_houses > 0 THEN
    SELECT COUNT(*) INTO v_covered_houses
    FROM public.buildings h
    JOIN public.building_types bt ON bt.key = h.building_type_key
    WHERE h.player_id = p_uid AND h.status = 'active'
      AND bt.category = 'housing' AND COALESCE(h.housing_tier, 0) >= 1
      AND EXISTS (
        SELECT 1 FROM public.buildings s
        WHERE s.player_id = p_uid AND s.status = 'active' AND s.is_staffed
          AND s.building_type_key = 'school'
          AND GREATEST(ABS(s.x - h.x), ABS(s.y - h.y)) <= 5
      );
    v_coverage := v_covered_houses::numeric / v_total_houses::numeric;
    v_edu_bonus := LEAST(0.10, FLOOR(v_coverage * 10) * 0.03);
    v_score := v_score + v_edu_bonus;
  END IF;

  v_pop_floor := FLOOR(v_population)::integer;
  IF v_pop_floor > 0 THEN
    SELECT COALESCE(quantity, 0) INTO v_tools
    FROM public.inventories
    WHERE player_id = p_uid AND resource_key = 'tools';
    v_tools := COALESCE(v_tools, 0);
    IF v_tools >= v_pop_floor * 0.5 THEN
      v_score := v_score + 0.10;
    ELSIF v_tools >= v_pop_floor * 0.2 THEN
      v_score := v_score + 0.05;
    END IF;
  END IF;

  IF v_worker_capacity > 0 AND v_workers_used >= v_worker_capacity THEN
    v_score := v_score - 0.05;
  END IF;

  v_score := GREATEST(-0.30, LEAST(0.30, v_score));
  v_productivity := GREATEST(0.7, LEAST(1.3, 1.0 + v_score));

  -- Brownout: electrified-only. A grid that exists (capacity > 0) but can't
  -- meet demand throttles output toward a 0.75 floor. No power built → no
  -- penalty (pre-electrification cities are untouched).
  IF v_pcap > 0 AND v_pdem > v_pcap THEN
    v_productivity := ROUND(v_productivity * GREATEST(0.75, v_pcap / v_pdem), 6);
  END IF;

  UPDATE public.player_profiles SET productivity = v_productivity WHERE id = p_uid;
  RETURN v_productivity;
END;
$function$;

COMMIT;
