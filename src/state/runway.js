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
// Now covers money, food (across all is_food resources + per-house
// pantries), and per-tier lifestyle goods (pottery / bread / furniture
// / statuary etc.) — matches v1's contract.
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
    // Paused buildings (status='paused') are filtered out by the
    // myActive guard above (status='active' only), so no separate
    // !b.paused check needed here.
    if (bt.upkeep_per_minute && b.is_staffed) {
      upkeep += Number(bt.upkeep_per_minute);
    }
    if (bt.category === 'tax' && b.is_staffed && bt.output_rate > 0) {
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
  // player has, compute net drain (demand minus production) and the
  // effective stock that backs it. Effective stock for pantried goods
  // is the sum of every house's pantry buffer for that resource — NOT
  // city inventory, because the server drains from pantries first.
  // City inventory only contributes via refill (modeled as production
  // here for simplicity — it's the upper bound on sustained drain).
  const houseTiers = {};
  for (const b of myActive) {
    if (!b.housing_tier || b.player_id !== state.currentUser.id) continue;
    houseTiers[b.housing_tier] = (houseTiers[b.housing_tier] || 0) + 1;
  }
  const drainPer = {};
  for (const tier in houseTiers) {
    const demands = state.housingLifestyleDemands?.[tier] || [];
    for (const d of demands) {
      drainPer[d.resource_key] = (drainPer[d.resource_key] || 0) + d.qty_per_minute * houseTiers[tier];
    }
  }
  for (const b of myActive) {
    const bt = state.buildingTypes[b.building_type_key];
    // myActive (above) restricts to status='active' so paused is
    // already excluded; only need to filter unstaffed here.
    if (!bt || !b.is_staffed) continue;
    if (bt.output_resource_key && bt.output_rate > 0 && drainPer[bt.output_resource_key]) {
      drainPer[bt.output_resource_key] -= Number(bt.output_rate);
    }
  }

  // Sum pantry buffers across own housing. If pantries aren't loaded
  // (older sessions / sandbox), fall back to city inventory.
  const pantryStock = {};
  if (state.buildingBuffers && Object.keys(state.buildingBuffers).length > 0) {
    for (const b of myActive) {
      if (!b.housing_tier || b.player_id !== state.currentUser.id) continue;
      const buf = state.buildingBuffers[b.id];
      if (!buf) continue;
      for (const rk in buf) {
        pantryStock[rk] = (pantryStock[rk] || 0) + Number(buf[rk].quantity || 0);
      }
    }
  }

  // ── 3) Food runway ──
  // Per-tier housing_tier_config.food_per_minute × house count gives
  // total food drain across the city. Food is pooled across every
  // is_food resource (the server drains proportionally — see
  // _pp_drain_housing_food), so the runway is total_food_stock /
  // total_drain. Per-house pantry's 'food' bucket counts first; city
  // inventory of every is_food resource is the refill upper bound.
  // Without this step the runway pill stayed at "∞" or money-only even
  // when grain hit zero — known undercount per the v2-first-cut TODO.
  let foodDrain = 0;
  for (const tier in houseTiers) {
    const cfg = state.housingTierConfig?.[tier];
    if (cfg?.food_per_minute) foodDrain += Number(cfg.food_per_minute) * houseTiers[tier];
  }
  if (foodDrain > 0) {
    let foodStock = 0;
    // Per-house pantry 'food' buckets.
    if (state.buildingBuffers && Object.keys(state.buildingBuffers).length > 0) {
      for (const b of myActive) {
        if (!b.housing_tier || b.player_id !== state.currentUser.id) continue;
        const buf = state.buildingBuffers[b.id];
        if (buf?.food) foodStock += Number(buf.food.quantity || 0);
      }
    }
    // Every is_food resource in city inventory tops it up (the server
    // refills the 'food' pantry from any is_food resource).
    const resources = state.resourceNodes || {};
    for (const rk in state.inventory) {
      if (resources[rk]?.is_food) foodStock += Number(state.inventory[rk] || 0);
    }
    const min = foodStock / foodDrain;
    if (min < bottleneckMin) {
      bottleneckMin = min;
      bottleneck = 'food';
    }
  }

  const subsMap = state.lifestyleSubstitutes || {};
  for (const rk in drainPer) {
    const net = drainPer[rk];
    if (net <= 0) continue;
    // Pantry-first when available, city stock as fallback. The server
    // drains the pantry; once it hits zero a missing-refill is what
    // triggers devolve, not the city stock. When the demand has
    // substitutes (bread accepts spices/caviar/spirits), include those
    // in the city-stock fallback — refill pools across them.
    let stock;
    if (rk in pantryStock) {
      stock = pantryStock[rk];
    } else {
      stock = Number(state.inventory[rk] || 0);
      for (const s of subsMap[rk] || []) {
        stock += Number(state.inventory[s] || 0);
      }
    }
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
