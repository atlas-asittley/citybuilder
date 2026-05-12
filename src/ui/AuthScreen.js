// Auth flow — three sequential screens matching v1:
//
//   Welcome  → [Sign In]  [Create Account]
//   Sign In  → email + password + "No account? Create one" link
//   Register → email + password + confirm + "Already have an account?" link
//
// Each screen replaces the previous in #ui-root. On success the
// caller's onAuthSuccess(user) fires.
import { sb } from '../api/supabase.js';

let onAuthSuccessCallback = null;

export function mountAuthScreen(onAuthSuccess) {
  onAuthSuccessCallback = onAuthSuccess;
  mountWelcome();
}

export function unmountAuthScreen() {
  document.getElementById('ui-root').innerHTML = '';
}

function mountWelcome() {
  const root = document.getElementById('ui-root');
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">City Builder</h1>
        <p class="ui-subtitle">Build, produce, trade. A shared city awaits.</p>
        <div class="ui-form" style="margin-top:8px;">
          <button class="ui-btn-primary" id="auth-go-login">Sign In</button>
          <button class="ui-btn-secondary" id="auth-go-register">Create Account</button>
        </div>
      </div>
    </div>
  `;
  document.getElementById('auth-go-login').addEventListener('click', mountLogin);
  document.getElementById('auth-go-register').addEventListener('click', mountRegister);
}

function mountLogin() {
  const root = document.getElementById('ui-root');
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">Sign In</h1>
        <p class="ui-subtitle">Welcome back, builder.</p>
        <form class="ui-form" id="login-form">
          <input type="email" id="login-email" placeholder="Email" autocomplete="email" required />
          <input type="password" id="login-password" placeholder="Password" autocomplete="current-password" required />
          <button type="submit" class="ui-btn-primary" id="login-submit">Sign In</button>
          <p class="ui-error" id="login-error"></p>
        </form>
        <div class="ui-link" id="login-to-register">No account? Create one</div>
      </div>
    </div>
  `;
  document.getElementById('login-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = document.getElementById('login-email').value.trim();
    const password = document.getElementById('login-password').value;
    const btn = document.getElementById('login-submit');
    const err = document.getElementById('login-error');
    err.textContent = '';
    btn.disabled = true; btn.textContent = 'Signing in…';
    try {
      const { data, error } = await sb.auth.signInWithPassword({ email, password });
      if (error) throw error;
      if (!data.session) {
        err.textContent = 'Check your email to confirm your account, then sign in.';
        btn.disabled = false; btn.textContent = 'Sign In';
        return;
      }
      onAuthSuccessCallback?.(data.session.user);
    } catch (e2) {
      err.textContent = e2.message || 'Something went wrong.';
      btn.disabled = false; btn.textContent = 'Sign In';
    }
  });
  document.getElementById('login-to-register').addEventListener('click', mountRegister);
  document.getElementById('login-email').focus();
}

function mountRegister() {
  const root = document.getElementById('ui-root');
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">Create Account</h1>
        <p class="ui-subtitle">Join the city.</p>
        <form class="ui-form" id="reg-form">
          <input type="email" id="reg-email" placeholder="Email" autocomplete="email" required />
          <input type="password" id="reg-password" placeholder="Password (≥ 6 chars)" autocomplete="new-password" minlength="6" required />
          <input type="password" id="reg-confirm" placeholder="Confirm password" autocomplete="new-password" required />
          <button type="submit" class="ui-btn-primary" id="reg-submit">Create Account</button>
          <p class="ui-error" id="reg-error"></p>
        </form>
        <div class="ui-link" id="reg-to-login">Already have an account? Sign in</div>
      </div>
    </div>
  `;
  document.getElementById('reg-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = document.getElementById('reg-email').value.trim();
    const password = document.getElementById('reg-password').value;
    const confirm = document.getElementById('reg-confirm').value;
    const btn = document.getElementById('reg-submit');
    const err = document.getElementById('reg-error');
    err.textContent = '';
    if (password !== confirm) {
      err.textContent = 'Passwords do not match.';
      return;
    }
    btn.disabled = true; btn.textContent = 'Creating…';
    try {
      const { data, error } = await sb.auth.signUp({ email, password });
      if (error) throw error;
      if (!data.session) {
        err.textContent = 'Check your email to confirm your account, then sign in.';
        btn.disabled = false; btn.textContent = 'Create Account';
        return;
      }
      onAuthSuccessCallback?.(data.session.user);
    } catch (e2) {
      err.textContent = e2.message || 'Something went wrong.';
      btn.disabled = false; btn.textContent = 'Create Account';
    }
  });
  document.getElementById('reg-to-login').addEventListener('click', mountLogin);
  document.getElementById('reg-email').focus();
}
