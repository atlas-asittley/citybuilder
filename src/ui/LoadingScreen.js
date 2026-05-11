// Full-screen "loading…" while the initial world fetch is in flight.
// Tiny, intentionally — most of the wait is network + Postgres,
// not anything we can speed up client-side.
export function mountLoadingScreen(msg = 'Loading your city…') {
  document.getElementById('ui-root').innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-loading">
        <div class="ui-spinner"></div>
        <p>${msg}</p>
      </div>
    </div>
  `;
}

export function unmountLoadingScreen() {
  document.getElementById('ui-root').innerHTML = '';
}
