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
    root.innerHTML = `
      <div class="ui-screen ui-screen-center">
        <div class="ui-card ui-card-wide">
          <h1 class="ui-title">Welcome</h1>
          <p class="ui-subtitle">Pick your starting industry and set up your district.</p>

          <div class="industry-grid">
            ${INDUSTRIES.map((ind) => `
              <button class="industry-card" data-industry="${ind.key}">
                <div class="ic-icon" style="color:${ind.color};">${ind.icon}</div>
                <div class="ic-name">${ind.name}</div>
                <div class="ic-desc">${ind.desc}</div>
              </button>
            `).join('')}
          </div>

          <form class="ui-form" id="industry-form">
            <input type="text" id="industry-name" placeholder="Screen name" minlength="2" maxlength="24" required />
            <input type="text" id="industry-district" placeholder="District name" minlength="2" maxlength="40" required />
            ${isFirstPlayer ? '<input type="text" id="industry-city" placeholder="City name (you are the first founder)" minlength="2" maxlength="40" required />' : ''}
            <button type="submit" class="ui-btn-primary" id="industry-confirm" disabled>Choose an industry first</button>
            <p class="ui-error" id="industry-error"></p>
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
