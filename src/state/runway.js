// City runway estimate — how long current reserves can support the
// city before something runs out.
//
// v1's full computeCityRunway considers food, lifestyle goods, per-house
// pantries, and money. This is the v2 first-cut: money runway only.
//
// Computation:
//   upkeep_total = sum(active.upkeep_per_minute) across the player's
//                  active buildings
//   tax_revenue  = (tax_output_rate × pop / 100) per minute
//   net          = tax_revenue - upkeep_total
//   if net >= 0  → Infinity (sustainable)
//   else         → money / -net minutes
//
// Food/lifestyle is the more common bottleneck on a real city; that
// piece needs housing_lifestyle_demands loaded into state — defer
// until that's wired in (matches v1 contract).
import { state } from './store.js';

export function computeCityRunway() {
  if (!state.currentUser || !state.profile) {
    return { minutes: Infinity, bottleneck: null };
  }
  const myActive = state.allBuildings.filter((b) =>
    b.player_id === state.currentUser.id && b.status === 'active'
  );

  let bottleneck = null;
  let bottleneckMin = Infinity;

  // ── 1) Money runway ──
  let upkeep = 0;
  let taxRevenue = 0;
  const pop = Math.floor(state.profile.population || 0);
  for (const b of myActive) {
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt) continue;
    if (bt.upkeep_per_minute && b.is_staffed && !b.paused) {
      upkeep += Number(bt.upkeep_per_minute);
    }
    if (bt.category === 'tax' && b.is_staffed && !b.paused && bt.output_rate > 0) {
      taxRevenue += Number(bt.output_rate) * (pop / 100);
    }
  }
  const moneyNet = taxRevenue - upkeep;
  if (moneyNet < 0 && upkeep > 0) {
    const moneyMin = (Number(state.profile.money || 0)) / -moneyNet;
    if (moneyMin < bottleneckMin) {
      bottleneckMin = moneyMin;
      bottleneck = 'money';
    }
  }

  // ── 2) Lifestyle goods runway ──
  // For each lifestyle resource consumed by housing at any tier the
  // player has, compute total drain (sum over each house's per-min
  // demand) and check against current inventory + any per-minute
  // production from staffed processors. Pick the worst.
  const houseTiers = {};
  for (const b of myActive) {
    if (!b.housing_tier || b.player_id !== state.currentUser.id) continue;
    houseTiers[b.housing_tier] = (houseTiers[b.housing_tier] || 0) + 1;
  }
  const drainPer = {};       // resource → demand/min from houses
  for (const tier in houseTiers) {
    const demands = state.housingLifestyleDemands?.[tier] || [];
    for (const d of demands) {
      drainPer[d.resource_key] = (drainPer[d.resource_key] || 0) + d.qty_per_minute * houseTiers[tier];
    }
  }
  // Subtract production from this player's active staffed processors.
  for (const b of myActive) {
    const bt = state.buildingTypes[b.building_type_key];
    if (!bt || !b.is_staffed || b.paused) continue;
    if (bt.output_resource_key && bt.output_rate > 0 && drainPer[bt.output_resource_key]) {
      drainPer[bt.output_resource_key] -= Number(bt.output_rate);
    }
  }
  for (const rk in drainPer) {
    const net = drainPer[rk];   // positive = consuming faster than producing
    if (net <= 0) continue;
    const stock = Number(state.inventory[rk] || 0);
    const min = stock / net;
    if (min < bottleneckMin) {
      bottleneckMin = min;
      bottleneck = rk;
    }
  }

  return { minutes: bottleneckMin, bottleneck };
}

// "12m", "3h 5m", "2d 4h" etc.
export function formatRunway(minutes) {
  if (!isFinite(minutes)) return '∞';
  if (minutes < 1) return '<1m';
  if (minutes < 60) return Math.floor(minutes) + 'm';
  if (minutes < 24 * 60) {
    const h = Math.floor(minutes / 60);
    const m = Math.floor(minutes % 60);
    return m === 0 ? h + 'h' : h + 'h ' + m + 'm';
  }
  const d = Math.floor(minutes / (24 * 60));
  const h = Math.floor((minutes % (24 * 60)) / 60);
  return h === 0 ? d + 'd' : d + 'd ' + h + 'h';
}
