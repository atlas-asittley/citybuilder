// Auth flow — sequential screens matching v1:
//
//   Welcome  → [Sign In]  [Create Account]
//   Sign In  → email + password + "Forgot password?" + "No account?" links
//   Register → email + password + confirm + "Already have an account?" link
//   Forgot   → email → sends a Supabase recovery email
//   Reset    → new password + confirm (entered after clicking that email)
//
// Each screen replaces the previous in #ui-root. On success the
// caller's onAuthSuccess(user) fires.
//
// The Reset screen is NOT reached by navigation — main.js mounts it
// directly when the app loads from a recovery link. See api/authHash.js.
import { sb } from '../api/supabase.js';
import { describeAuthError } from '../api/authHash.js';

// Where Supabase should send the user after they click the emailed
// link. BASE_URL is '/citybuilder/' in a production build and '/' under
// `npm run dev`, so this resolves correctly in both. NOTE: this exact
// URL must be present in the Supabase dashboard's Redirect Allow List
// (Authentication → URL Configuration) or Supabase silently falls back
// to the project's Site URL.
function recoveryRedirectUrl() {
  return window.location.origin + (import.meta.env?.BASE_URL || '/');
}

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
        <div class="ui-link" id="login-to-forgot">Forgot password?</div>
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
  document.getElementById('login-to-forgot').addEventListener('click', () => {
    // Carry whatever they already typed over, so they don't retype it.
    mountForgot(document.getElementById('login-email').value.trim());
  });
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

function mountForgot(prefillEmail = '') {
  const root = document.getElementById('ui-root');
  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">Reset Password</h1>
        <p class="ui-subtitle">We'll email you a link to set a new one.</p>
        <form class="ui-form" id="forgot-form">
          <input type="email" id="forgot-email" placeholder="Email" autocomplete="email" required />
          <button type="submit" class="ui-btn-primary" id="forgot-submit">Send Reset Link</button>
          <p class="ui-error" id="forgot-error"></p>
        </form>
        <div class="ui-link" id="forgot-to-login">Back to sign in</div>
      </div>
    </div>
  `;
  const emailInput = document.getElementById('forgot-email');
  emailInput.value = prefillEmail;

  document.getElementById('forgot-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = emailInput.value.trim();
    const btn = document.getElementById('forgot-submit');
    const err = document.getElementById('forgot-error');
    err.textContent = '';
    btn.disabled = true; btn.textContent = 'Sending…';
    try {
      const { error } = await sb.auth.resetPasswordForEmail(email, {
        redirectTo: recoveryRedirectUrl(),
      });
      if (error) throw error;
      // Deliberately not distinguishing "sent" from "no such account" —
      // that difference would let anyone probe which emails are
      // registered. Supabase's API is silent about it for the same
      // reason; the UI shouldn't leak what the API withholds.
      root.querySelector('.ui-card').innerHTML = `
        <h1 class="ui-title">Check Your Email</h1>
        <p class="ui-subtitle">
          If an account exists for <strong></strong>, a reset link is on its
          way. It expires in an hour and can only be used once.
        </p>
        <p class="ui-subtitle" style="opacity:0.7;">
          Nothing arrived? Check spam, then try again in a few minutes —
          reset emails are rate-limited.
        </p>
        <div class="ui-form" style="margin-top:8px;">
          <button class="ui-btn-secondary" id="sent-to-login">Back to sign in</button>
        </div>
      `;
      // textContent, not template interpolation — the address is user
      // input and must never be parsed as HTML.
      root.querySelector('.ui-subtitle strong').textContent = email;
      document.getElementById('sent-to-login').addEventListener('click', mountLogin);
    } catch (e2) {
      err.textContent = e2.message || 'Could not send the reset email.';
      btn.disabled = false; btn.textContent = 'Send Reset Link';
    }
  });
  document.getElementById('forgot-to-login').addEventListener('click', mountLogin);
  emailInput.focus();
}

/**
 * Shown when the app is opened from a recovery link. By this point
 * supabase-js has already traded the fragment for a live (recovery)
 * session, so updateUser() is authenticated — but we must not let the
 * player into the game until they've actually set a password, or the
 * next sign-in fails exactly as before.
 *
 * @param {object|null} linkError parsed error fragment, if the link was bad
 */
export function mountResetPassword(onAuthSuccess, linkError = null) {
  onAuthSuccessCallback = onAuthSuccess;
  const root = document.getElementById('ui-root');

  if (linkError) {
    root.innerHTML = `
      <div class="ui-screen ui-screen-center">
        <div class="ui-card">
          <h1 class="ui-title">Link Expired</h1>
          <p class="ui-subtitle" id="link-error-msg"></p>
          <div class="ui-form" style="margin-top:8px;">
            <button class="ui-btn-primary" id="expired-to-forgot">Send a New Link</button>
            <button class="ui-btn-secondary" id="expired-to-login">Back to sign in</button>
          </div>
        </div>
      </div>
    `;
    document.getElementById('link-error-msg').textContent = describeAuthError(linkError);
    document.getElementById('expired-to-forgot').addEventListener('click', () => mountForgot());
    document.getElementById('expired-to-login').addEventListener('click', mountLogin);
    return;
  }

  root.innerHTML = `
    <div class="ui-screen ui-screen-center">
      <div class="ui-card">
        <h1 class="ui-title">Set a New Password</h1>
        <p class="ui-subtitle">Almost there — pick something you'll remember.</p>
        <form class="ui-form" id="reset-form">
          <input type="password" id="reset-password" placeholder="New password (≥ 6 chars)" autocomplete="new-password" minlength="6" required />
          <input type="password" id="reset-confirm" placeholder="Confirm new password" autocomplete="new-password" required />
          <button type="submit" class="ui-btn-primary" id="reset-submit">Save Password</button>
          <p class="ui-error" id="reset-error"></p>
        </form>
      </div>
    </div>
  `;

  document.getElementById('reset-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const password = document.getElementById('reset-password').value;
    const confirm = document.getElementById('reset-confirm').value;
    const btn = document.getElementById('reset-submit');
    const err = document.getElementById('reset-error');
    err.textContent = '';
    if (password !== confirm) {
      err.textContent = 'Passwords do not match.';
      return;
    }
    btn.disabled = true; btn.textContent = 'Saving…';
    try {
      const { data, error } = await sb.auth.updateUser({ password });
      if (error) throw error;
      const { data: sessionData } = await sb.auth.getSession();
      const user = data?.user || sessionData?.session?.user;
      if (!user) {
        // Recovery session lapsed between load and submit.
        err.textContent = 'Your reset link expired. Request a new one from the sign-in screen.';
        btn.disabled = false; btn.textContent = 'Save Password';
        return;
      }
      onAuthSuccessCallback?.(user);
    } catch (e2) {
      err.textContent = e2.message || 'Could not update your password.';
      btn.disabled = false; btn.textContent = 'Save Password';
    }
  });
  document.getElementById('reset-password').focus();
}
