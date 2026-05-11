// Email/password sign-in + sign-up. Pure DOM (no Phaser) — UI screens
// sit on top of the Phaser canvas via the #ui-root container.
//
// On success, calls onAuthSuccess(user). The router decides whether
// to send the user to industry-select or straight into the game
// based on whether a profile exists.
import { sb } from '../api/supabase.js';

export function mountAuthScreen(onAuthSuccess) {
  const root = document.getElementById('ui-root');
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">City Builder</h1>
        <p class="ui-subtitle">Sign in to enter the shared world</p>

        <div class="ui-tabs">
          <button class="ui-tab active" data-tab="login">Log in</button>
          <button class="ui-tab" data-tab="signup">Sign up</button>
        </div>

        <form class="ui-form" id="auth-form">
          <input type="email" id="auth-email" placeholder="Email" autocomplete="email" required />
          <input type="password" id="auth-password" placeholder="Password" autocomplete="current-password" minlength="6" required />
          <button type="submit" class="ui-btn-primary" id="auth-submit">Log in</button>
          <p class="ui-error" id="auth-error"></p>
        </form>
      </div>
    </div>
  `;

  const form = document.getElementById('auth-form');
  const emailInput = document.getElementById('auth-email');
  const pwInput = document.getElementById('auth-password');
  const submitBtn = document.getElementById('auth-submit');
  const errorEl = document.getElementById('auth-error');
  const tabs = root.querySelectorAll('.ui-tab');

  let mode = 'login';

  tabs.forEach((tab) => {
    tab.addEventListener('click', () => {
      mode = tab.dataset.tab;
      tabs.forEach((t) => t.classList.toggle('active', t === tab));
      submitBtn.textContent = mode === 'login' ? 'Log in' : 'Sign up';
      pwInput.autocomplete = mode === 'login' ? 'current-password' : 'new-password';
      errorEl.textContent = '';
    });
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    errorEl.textContent = '';
    submitBtn.disabled = true;
    submitBtn.textContent = mode === 'login' ? 'Logging in…' : 'Signing up…';

    const email = emailInput.value.trim();
    const password = pwInput.value;

    try {
      const fn = mode === 'login' ? 'signInWithPassword' : 'signUp';
      const { data, error } = await sb.auth[fn]({ email, password });
      if (error) throw error;

      // signUp may return a session immediately (auto-confirm) or
      // null (email-confirmation required). Treat both: if no
      // session, surface a friendly message and bail. We can switch
      // the Supabase project to auto-confirm later if needed.
      if (!data.session) {
        errorEl.textContent = 'Check your email to confirm your account, then log in.';
        submitBtn.disabled = false;
        submitBtn.textContent = mode === 'login' ? 'Log in' : 'Sign up';
        return;
      }
      onAuthSuccess(data.session.user);
    } catch (err) {
      errorEl.textContent = err.message || 'Something went wrong.';
      submitBtn.disabled = false;
      submitBtn.textContent = mode === 'login' ? 'Log in' : 'Sign up';
    }
  });

  emailInput.focus();
}

export function unmountAuthScreen() {
  const root = document.getElementById('ui-root');
  root.innerHTML = '';
}
