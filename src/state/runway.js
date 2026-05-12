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
  const net = taxRevenue - upkeep;
  if (net >= 0 || upkeep <= 0) {
    return { minutes: Infinity, bottleneck: null };
  }
  const money = Number(state.profile.money || 0);
  return { minutes: money / -net, bottleneck: 'money' };
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
