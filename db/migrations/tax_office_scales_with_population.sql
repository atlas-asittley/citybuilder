-- ── Tax Office revenue scales with population (2026-05-08) ──
-- Atlas: tax revenue should depend on population. A flat $10/min per
-- office stays small relative to a growing city's upkeep + lifestyle
-- demands; reframing as "$ per 100 citizens per minute" keeps the
-- mental anchor ("$10/min" at the canonical 100-pop city) while
-- letting late-game cities self-fund.
--
-- Math change:
--   was: v_amt = (elapsed/60) × output_rate × productivity
--   now: v_amt = (elapsed/60) × output_rate × (population / 100) × productivity
--
-- output_rate stays at 10 in the DB (no balance migration). At 100
-- citizens, revenue = $10/min per office (same as before). At 200
-- citizens, $20/min per office. At Jill's current 287, $28.70/min.
-- Multiple offices stack linearly; each costs 10 workers + happiness
-- penalty so building 5 has real cost.

CREATE OR REPLACE FUNCTION public._pp_run_tax(p_uid uuid, p_staffed_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_now timestamptz := now();
  v_total integer := 0;
  v_b record;
  v_elapsed numeric;
  v_amt numeric;
  v_productivity numeric;
  v_population numeric;
BEGIN
  SELECT COALESCE(productivity, 1.0), COALESCE(population, 0)
    INTO v_productivity, v_population
  FROM public.player_profiles WHERE id = p_uid;

  FOR v_b IN
    SELECT b.id, b.last_processed_at, bt.output_rate
    FROM public.buildings b
    JOIN public.building_types bt ON bt.key = b.building_type_key
    WHERE b.player_id = p_uid AND b.status = 'active' AND bt.category = 'tax'
      AND b.id = ANY(p_staffed_ids)
    FOR UPDATE OF b
  LOOP
    v_elapsed := EXTRACT(EPOCH FROM (v_now - v_b.last_processed_at));
    -- output_rate is "$ per 100 citizens per minute" now. Divide by
    -- 100 to get the per-citizen rate, multiply by population.
    v_amt := FLOOR((v_elapsed / 60.0) * v_b.output_rate * (v_population / 100.0) * v_productivity);
    IF v_amt > 0 THEN
      UPDATE public.player_profiles SET money = money + v_amt::integer WHERE id = p_uid;
      v_total := v_total + v_amt::integer;
    END IF;
    UPDATE public.buildings SET last_processed_at = v_now WHERE id = v_b.id;
  END LOOP;

  IF v_total > 0 THEN
    INSERT INTO public.cash_transactions (player_id, source, amount, context)
    VALUES (p_uid, 'tax_revenue', v_total, NULL);
  END IF;

  RETURN v_total;
END;
$function$;
