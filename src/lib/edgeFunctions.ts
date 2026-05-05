import type { Session } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config';
import type { ClaimResponse } from '../types';

export type EdgeError = { error: string; status: number };
export type EdgeResult<T> = { ok: true; data: T } | { ok: false; error: EdgeError };

async function postJson<T>(
  path: string,
  body: unknown,
  session: Session,
): Promise<EdgeResult<T>> {
  const res = await fetch(`${SUPABASE_URL}/functions/v1/${path}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${session.access_token}`,
      'Content-Type': 'application/json',
      apikey: SUPABASE_ANON_KEY,
    },
    body: JSON.stringify(body),
  });
  let payload: unknown = null;
  try {
    payload = await res.json();
  } catch {
    // empty body is acceptable
  }
  if (!res.ok) {
    const err =
      payload && typeof payload === 'object' && 'error' in payload
        ? String((payload as { error: unknown }).error)
        : `http_${res.status}`;
    return { ok: false, error: { error: err, status: res.status } };
  }
  return { ok: true, data: payload as T };
}

export function claimHandoff(requestId: number, session: Session) {
  return postJson<ClaimResponse>('claim_handoff', { request_id: requestId }, session);
}

export function rejectHandoff(requestId: number, session: Session) {
  return postJson<{ ok: boolean }>('reject_handoff', { request_id: requestId }, session);
}

export function completeHandoff(requestId: number, session: Session) {
  return postJson<{ ok: boolean }>('complete_handoff', { request_id: requestId }, session);
}
