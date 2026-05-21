// Feedback-prompt modal. Shown on game load when the server has a
// pending feedback_prompts row for this player. Players can type a
// reply (→ submit_feedback_response) or skip (→ dismiss_feedback_prompt).
//
// Atlas seeds rows by direct DB INSERT; the player sees them next
// time they open the game. See
// city-builder-mvp/migration_patches/feedback_prompts.sql.
import { submitFeedbackResponse, dismissFeedbackPrompt, fetchPendingFeedbackPrompt } from '../api/feedback.js';

let mounted = false;

// Called once on game load. Fetches; if there's a pending prompt,
// opens the modal. Idempotent — safe to call multiple times.
export async function maybeShowPendingFeedbackPrompt() {
  if (mounted) return;
  const prompt = await fetchPendingFeedbackPrompt();
  if (!prompt) return;
  openFeedbackPromptModal(prompt);
}

function openFeedbackPromptModal(prompt) {
  if (mounted) return;
  mounted = true;

  const root = document.getElementById('ui-root');
  const overlay = document.createElement('div');
  overlay.id = 'feedback-overlay';
  overlay.innerHTML = `
    <div class="bug-card">
      <div class="bug-header">
        <h2>💬 Quick question</h2>
        <button class="bug-close" aria-label="Skip">×</button>
      </div>
      <p class="bug-hint" id="feedback-text"></p>
      <textarea id="feedback-reply" rows="6" placeholder="Type your reply here…"></textarea>
      <div class="bug-actions">
        <button class="ip-btn" id="feedback-skip">Skip</button>
        <button class="ip-btn ip-btn-primary" id="feedback-submit">Send reply</button>
      </div>
      <p class="bug-status" id="feedback-status"></p>
    </div>
  `;
  root.appendChild(overlay);

  // prompt_text could contain newlines; preserve them and escape
  // anything HTML-active.
  const textEl = document.getElementById('feedback-text');
  textEl.style.whiteSpace = 'pre-wrap';
  textEl.textContent = prompt.prompt_text;

  const close = () => { overlay.remove(); mounted = false; };

  const skip = async () => {
    const skipBtn = document.getElementById('feedback-skip');
    if (skipBtn) { skipBtn.disabled = true; skipBtn.textContent = 'Skipping…'; }
    try {
      await dismissFeedbackPrompt(prompt.id);
    } catch (err) {
      console.warn('dismissFeedbackPrompt error:', err.message);
    }
    close();
  };

  overlay.querySelector('.bug-close').addEventListener('click', skip);
  overlay.querySelector('#feedback-skip').addEventListener('click', skip);
  // Clicking the dim backdrop counts as Skip (matches the bug-report
  // modal's behavior of treating outside-click as cancel).
  overlay.addEventListener('click', (e) => { if (e.target === overlay) skip(); });

  document.getElementById('feedback-submit').addEventListener('click', async () => {
    const reply = document.getElementById('feedback-reply').value.trim();
    const statusEl = document.getElementById('feedback-status');
    if (reply.length < 1) {
      statusEl.textContent = 'Write at least a few words, or use Skip.';
      return;
    }
    const submitBtn = document.getElementById('feedback-submit');
    submitBtn.disabled = true;
    submitBtn.textContent = 'Sending…';
    try {
      await submitFeedbackResponse(prompt.id, reply);
      statusEl.textContent = '✓ Thanks! Sent.';
      setTimeout(close, 1100);
    } catch (err) {
      statusEl.textContent = 'Send failed: ' + (err.message || err);
      submitBtn.disabled = false;
      submitBtn.textContent = 'Send reply';
    }
  });
}
