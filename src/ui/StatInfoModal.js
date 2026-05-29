// Stat info modal — tap any topbar stat to open a what / why / how
// explainer. Copy is lifted from v1's help.js STAT_INFO so it
// teaches the same concepts.
import { state } from '../state/store.js';
import { computeCityRunway, formatRunway } from '../state/runway.js';
import { openExpansionPanel } from './ExpansionPanel.js';

const STAT_INFO = {
  workers: {
    icon: '👷',
    title: 'Workers Employed',
    what: 'Citizens currently <b>working</b> at a building. Format: <b>employed / jobs available</b>.',
    why: 'When employed equals available, every job is staffed and your city runs at full capacity. A red <b>!</b> badge means a labor shortage — more jobs than workers, so production stalls.',
    how: 'Want more workers? Grow population — bigger / higher-tier houses raise the pool, and citizens move in when happiness is above 50.'
  },
  population: {
    icon: '👥',
    title: 'Population',
    what: '<b>citizens / housing capacity</b>. Capacity = a 15-citizen floor + each active house\'s worker capacity.',
    why: 'Population is your worker pool — every staffed building draws from it. The 15 floor prevents a death spiral.',
    how: 'Citizens move in when <b>happiness ≥ 50</b> and there\'s open capacity. Raise capacity by building more houses or letting them evolve to higher tiers.'
  },
  parcels: {
    icon: '🗺',
    title: 'Parcels',
    what: 'Each parcel is ~225 buildable tiles + a few resource patches. Multiple parcels stitched together make your district.',
    why: 'More parcels = more room to grow. The cost scales steeply: <b>$10,000 × parcels²</b> for the next claim.',
    how: 'Tap <b>Expand parcel</b> from the More menu. Highlighted candidate chunks appear on the map; tap one to claim.'
  },
  happiness: {
    icon: '🙂',
    title: 'Happiness',
    what: 'How content your citizens are. The icon at the topbar swaps ☹/😐/🙂/😊 as conditions improve.',
    why: 'Happy city grows; unhappy city shrinks. Watch the migration arrow — happiness slip → migration goes negative.',
    how: 'Build the five service buildings (well, tavern, bathhouse, school, temple). Stock <b>variety of foods</b>. Don\'t over-tax. Reduce crime with police.'
  },
  crime: {
    icon: '🚨',
    title: 'Crime',
    what: '0–100, lower is better. Pushed up by housing outside police coverage and by total housing count.',
    why: 'High crime drags down happiness and citizens start leaving — can undo your service buildouts.',
    how: 'Place police buildings (Watch House r4 / Police Station r6 / Constabulary r8) so they cover housing. They need staffing to work — unstaffed police don\'t reduce crime.'
  },
  power: {
    icon: '⚡',
    title: 'Power',
    what: 'Your city\'s electricity balance: <b>demand / capacity</b>. Processors and transport hubs draw power; <b>power plants</b> generate it. Extractors, farms, housing and services don\'t draw any.',
    why: 'A utility, like water. Today the number is informational — running short does nothing yet. The plan is for a shortage to throttle production (a "brownout"), so it pays to get ahead of it.',
    how: 'Build power: <b>Watermill / Windmill</b> (fuel-free, +20 each) or a <b>Powerhouse</b> (+80, burns Charcoal, needs Machinery to build). They must be staffed to generate.'
  },
  health: {
    icon: '❤️',
    title: 'Public Health',
    what: '0–100, higher is better. Starts at 50; rises with <b>Clinic / Hospital</b> coverage of your housing, and falls with high <b>waste</b>.',
    why: 'A healthy city (above 70) gets a small <b>productivity</b> boost. There\'s no penalty for low health — it\'s pure upside, so it\'s always worth improving.',
    how: 'Build <b>Clinics</b> within 5 tiles of housing (they consume lumber + glass while staffed), and keep waste down with sanitation.'
  },
  education: {
    icon: '🎓',
    title: 'Education',
    what: '0–100, higher is better. The share of your housing within 5 tiles of a staffed <b>School</b> or <b>Library</b>.',
    why: 'Educated cities are more productive — coverage feeds directly into your productivity multiplier.',
    how: 'Place <b>Schools</b> and <b>Libraries</b> so their range blankets your housing (Libraries consume lumber + glass while staffed).'
  },
  congestion: {
    icon: '🚗',
    title: 'Congestion',
    what: '0–100, lower is better. Rises with <b>traffic</b> — population, staffed processors, and transport hubs — measured against your <b>road capacity</b> (every road tile counts, and fancier/wider roads count for more).',
    why: 'Above 40, clogged streets throttle <b>productivity</b> (bounded, recoverable). It\'s the payoff for letting your road network lag behind a booming city.',
    how: 'Lay more roads, and upgrade key arteries to <b>Tiled Avenue</b> / <b>Grand Boulevard</b> — higher road tiers carry more traffic and relieve congestion.'
  },
  waste: {
    icon: '🗑',
    title: 'Waste',
    what: '0–100, lower is better. Housing generates garbage; a house is "covered" when a <b>staffed sanitation building</b> sits within its coverage radius. Uncovered housing piles up. Production adds a smaller industrial floor.',
    why: 'High waste drags down <b>desirability</b> (bounded, so it won\'t collapse your city), which gates how far housing can upgrade. Dirty districts stop climbing tiers.',
    how: 'Build sanitation near housing: <b>Refuse Dump</b> (r5, cheap), <b>Recycling Center</b> (r7), <b>Incinerator</b> (r9, needs Machinery to build). They must be staffed to count.'
  },
  migration: {
    icon: '↕',
    title: 'Migration',
    what: 'Citizens moving in (↑ green) / leaving (↓ red) / steady (→). The number is the rate per minute.',
    why: 'Tells you at a glance whether your city is growing or shrinking. Going red is the first sign happiness has slipped too far.',
    how: 'Improve happiness (services + food variety + low crime) AND keep open housing capacity — without empty rooms, new arrivals can\'t move in.'
  },
  productivity: {
    icon: '⚒',
    title: 'Productivity',
    what: 'A multiplier on every production building\'s output. 100% = baseline.',
    why: 'Compounds across every extractor / processor / food building. 110% beats 90% in a meaningful way over time.',
    how: '<b>+</b>: staffed Tavern (+5%), Tools stockpile (+5% / +10%), housing near a staffed School (up to +10%). <b>−</b>: crime above 50 (−10%), no idle worker buffer (−5%).'
  },
  runway: {
    icon: '⏳',
    title: 'City Runway',
    what: 'How long current reserves can sustain the city before something runs out. Bottleneck = the resource (or money) that depletes first.',
    why: 'Tells you whether your city is sustainable. <b>∞</b> = nothing draining. Finite = countdown to act.',
    how: 'Build more of whatever\'s the bottleneck. For lifestyle goods: the relevant processor (Pottery Kiln, Bakery, etc.). For money: lower upkeep or raise tax revenue.'
  },
  money: {
    icon: '💰',
    title: 'Treasury',
    what: 'Your current cash. Replenished by tax offices, drained by upkeep + building costs.',
    why: 'You need cash on hand to build anything new and to keep services running. A negative-net-flow situation means the runway is ticking down.',
    how: 'Build a Tax Office (revenue scales with population × $/min) when you can afford the workers. Avoid stacking police you don\'t need — their upkeep adds up.'
  }
};

let mounted = false;

export function openStatInfo(key) {
  if (mounted) return;
  const info = STAT_INFO[key];
  if (!info) return;
  mounted = true;

  let extra = '';
  if (key === 'runway') {
    const r = computeCityRunway();
    extra = `<div class="si-current">
      <strong>Right now:</strong> ${isFinite(r.minutes) ? 'depletes in ' + formatRunway(r.minutes) + ' (bottleneck: ' + (state.resourceNodes[r.bottleneck]?.name || r.bottleneck || 'money') + ')' : 'sustainable — nothing draining net'}
    </div>`;
  }
  if (key === 'parcels') {
    extra = '<button class="ui-btn-primary" id="si-expand-btn">+ Expand parcel</button>';
  }

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'stat-info-overlay';
  overlay.innerHTML = `
    <div class="si-card">
      <div class="si-header">
        <h2><span class="si-icon">${info.icon}</span> ${info.title}</h2>
        <button class="si-close" aria-label="Close">×</button>
      </div>
      <div class="si-body">
        <p class="si-section"><span class="si-label">What</span> ${info.what}</p>
        <p class="si-section"><span class="si-label">Why</span> ${info.why}</p>
        <p class="si-section"><span class="si-label">How</span> ${info.how}</p>
        ${extra}
      </div>
    </div>
  `;
  root.appendChild(overlay);

  const close = () => { overlay.remove(); mounted = false; };
  overlay.querySelector('.si-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });

  if (key === 'parcels') {
    document.getElementById('si-expand-btn').addEventListener('click', () => {
      close();
      openExpansionPanel(() => {});
    });
  }
}
