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
