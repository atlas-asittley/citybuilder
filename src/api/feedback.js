// Thin wrappers around the feedback_prompts RPCs. The server-side
// design + per-RPC contract live in
// city-builder-mvp/migration_patches/feedback_prompts.sql.
import { sb } from './supabase.js';

export async function fetchPendingFeedbackPrompt() {
  const { data, error } = await sb.rpc('get_pending_feedback_prompt');
  if (error) {
    console.warn('fetchPendingFeedbackPrompt error:', error.message);
    return null;
  }
  return data || null;
}

export async function submitFeedbackResponse(id, response) {
  const { error } = await sb.rpc('submit_feedback_response', {
    p_id: id, p_response: response
  });
  if (error) throw error;
}

export async function dismissFeedbackPrompt(id) {
  const { error } = await sb.rpc('dismiss_feedback_prompt', { p_id: id });
  if (error) throw error;
}
