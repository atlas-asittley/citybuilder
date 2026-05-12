// First-time setup: pick a starting industry + screen name + district.
// Same RPC contract as v1's choose_industry — the server handles
// player_profiles row creation, starting buildings, parcel
// allocation, etc.
import { sb } from '../api/supabase.js';

const INDUSTRIES = [
  { key: 'timber', name: 'Timber', icon: '▲', color: '#5ec49e', desc: 'Harvest timber, produce lumber. Paired food: berries from an orchard.' },
  { key: 'stone',  name: 'Stone',  icon: '◆', color: '#8888aa', desc: 'Quarry stone, craft bricks. Paired food: fish from a fishing pier.' },
  { key: 'clay',   name: 'Clay',   icon: '●', color: '#c08858', desc: 'Dig clay, fire pottery. Paired food: vegetables from a garden.' },
  { key: 'iron',   name: 'Iron',   icon: '■', color: '#a0a0b0', desc: 'Mine iron, the foundation of tools. Paired food: grain from a farm.' }
];

export function mountIndustrySelectScreen(onComplete) {
  const root = document.getElementById('ui-root');

  // Probe whether any city exists yet — first-player flow asks for
  // the city name; later players join an existing city.
  sb.from('cities').select('id').limit(1).then(({ data }) => {
    const isFirstPlayer = !data || data.length === 0;
    render(isFirstPlayer);
  });

  function render(isFirstPlayer) {
    // v1 ordering: title + sub, FORM FIRST (name, district, city),
    // THEN industry cards, then confirm. Mirror that here.
    root.innerHTML = `
      <div class="ui-screen ui-screen-center">
        <div class="ui-card ui-card-wide">
          <h1 class="ui-title">Choose Your Industry</h1>
          <p class="ui-subtitle">Pick your specialization. This decides your buildings and resources.</p>

          <form class="ui-form" id="industry-form">
            <label class="ui-field">
              <span class="ui-field-label">Screen Name</span>
              <input type="text" id="industry-name" placeholder="Pick a name other players will see" minlength="2" maxlength="24" required />
              <span class="ui-field-hint">2–24 characters. Players see this; your email stays private.</span>
            </label>
            <label class="ui-field">
              <span class="ui-field-label">District Name</span>
              <input type="text" id="industry-district" placeholder="e.g. Riverside, Old Town" minlength="2" maxlength="40" required />
              <span class="ui-field-hint">Your slice of the city. 2–40 characters.</span>
            </label>
            ${isFirstPlayer ? `
              <label class="ui-field">
                <span class="ui-field-label">City Name</span>
                <input type="text" id="industry-city" placeholder="What should the new city be called?" minlength="2" maxlength="40" required />
                <span class="ui-field-hint">You're the first founder here — you name the city.</span>
              </label>
            ` : ''}

            <div class="industry-grid">
              ${INDUSTRIES.map((ind) => `
                <button type="button" class="industry-card" data-industry="${ind.key}">
                  <div class="ic-icon" style="color:${ind.color};">${ind.icon}</div>
                  <div class="ic-name">${ind.name}</div>
                  <div class="ic-desc">${ind.desc}</div>
                </button>
              `).join('')}
            </div>

            <p class="ui-error" id="industry-error"></p>
            <button type="submit" class="ui-btn-primary" id="industry-confirm" disabled>Choose an industry first</button>
          </form>
        </div>
      </div>
    `;

    let selectedIndustry = null;
    const cards = root.querySelectorAll('.industry-card');
    const confirmBtn = document.getElementById('industry-confirm');
    const errorEl = document.getElementById('industry-error');

    cards.forEach((card) => {
      card.addEventListener('click', () => {
        cards.forEach((c) => c.classList.remove('selected'));
        card.classList.add('selected');
        selectedIndustry = card.dataset.industry;
        confirmBtn.disabled = false;
        confirmBtn.textContent = 'Set up my district';
      });
    });

    document.getElementById('industry-form').addEventListener('submit', async (e) => {
      e.preventDefault();
      errorEl.textContent = '';

      if (!selectedIndustry) {
        errorEl.textContent = 'Choose an industry first.';
        return;
      }

      const name = document.getElementById('industry-name').value.trim();
      const district = document.getElementById('industry-district').value.trim();
      const cityInput = document.getElementById('industry-city');
      const cityName = cityInput ? cityInput.value.trim() : null;

      confirmBtn.disabled = true;
      confirmBtn.textContent = 'Setting up…';

      try {
        const args = {
          p_display_name: name,
          p_industry_key: selectedIndustry,
          p_district_name: district
        };
        if (isFirstPlayer && cityName) args.p_city_name = cityName;

        const { error } = await sb.rpc('choose_industry', args);
        if (error) throw error;
        onComplete();
      } catch (err) {
        errorEl.textContent = err.message || 'Setup failed.';
        confirmBtn.disabled = false;
        confirmBtn.textContent = 'Set up my district';
      }
    });
  }
}

export function unmountIndustrySelectScreen() {
  document.getElementById('ui-root').innerHTML = '';
}
