// Central in-memory game state. Single source of truth that scenes
// and UI screens read from. Mutated through small named functions
// below — never reach in and reassign fields elsewhere.
//
// The shape mirrors v1's state.js but stripped of DOM-render flags
// that don't apply to Phaser. As the v2 game grows we add fields
// here as they're needed; nothing speculative.

export const state = {
  // Auth
  currentUser: null,        // Supabase auth user
  profile: null,            // row from player_profiles
  cityName: null,           // current city display name

  // World data — populated by api/loader.js after auth
  allBuildings: [],
  tileMap: {},              // keyed by "x,y" — { x, y, terrain_type, ... }
  buildingTypes: {},        // keyed by building_type_key
  housingTierConfig: {},
  resourceNodes: {},
  inventory: {},            // keyed by resource_key → numeric quantity
  notifications: [],        // recent notifications, newest first

  // Trade — populated by loader, driven by partner panel + auto-trader.
  traders: {},              // keyed by trader.key — { key, name, mode, ... }
  allTraderPrices: {},      // [trader_key][resource_key] → { buy_price, sell_price, daily_buy_cap, daily_sell_cap }
  tradePolicies: {},        // [resource_key] → { mode, reserve_target, min_sell_price, max_buy_price }

  // Labor allocation — kept in sync with process_production response
  // so the topbar workers stat can show used/needed + shortage badge.
  laborInfo: {
    workersUsed: 0,
    workersNeeded: 0,
    workerCapacity: 0,
    laborShortage: false,
    housingCapacity: 0
  },
  resources: {},            // alias of resourceNodes — v1 used both names

  // Camera / UI hints — only what the renderer needs
  gridMinX: 0,
  gridMinY: 0,
  gridCols: 0,
  gridRows: 0,
};

export function setUser(user) {
  state.currentUser = user;
}

export function setProfile(profile) {
  state.profile = profile;
}

export function setCityName(name) {
  state.cityName = name;
}

export function clearState() {
  state.currentUser = null;
  state.profile = null;
  state.cityName = null;
  state.allBuildings = [];
  state.tileMap = {};
  state.buildingTypes = {};
  state.housingTierConfig = {};
  state.resourceNodes = {};
}
