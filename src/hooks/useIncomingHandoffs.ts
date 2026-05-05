import { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import type { HandoffRequest } from '../types';

function isAlive(row: HandoffRequest, nowMs: number): boolean {
  return row.status === 'pending' && new Date(row.expires_at).getTime() > nowMs;
}

function sortByCreatedAt(rows: HandoffRequest[]): HandoffRequest[] {
  return [...rows].sort(
    (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
  );
}

export function useIncomingHandoffs() {
  const [queue, setQueue] = useState<HandoffRequest[]>([]);

  const refetch = useCallback(async () => {
    const nowIso = new Date().toISOString();
    const { data, error } = await supabase
      .from('handoff_requests')
      .select('*')
      .eq('status', 'pending')
      .gt('expires_at', nowIso)
      .order('created_at', { ascending: true });
    if (error) {
      if (__DEV__) console.error('handoff_requests fetch failed', error);
      return;
    }
    const rows = (data ?? []) as HandoffRequest[];
    setQueue((current) => {
      const byId = new Map<number, HandoffRequest>();
      for (const r of current) byId.set(r.id, r);
      for (const r of rows) byId.set(r.id, r);
      const nowMs = Date.now();
      return sortByCreatedAt(
        Array.from(byId.values()).filter((r) => isAlive(r, nowMs)),
      );
    });
  }, []);

  useEffect(() => {
    refetch();

    const channel = supabase
      .channel('handoff-requests')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'handoff_requests' },
        (payload) => {
          const row = payload.new as HandoffRequest;
          if (!isAlive(row, Date.now())) return;
          setQueue((current) => {
            if (current.some((r) => r.id === row.id)) return current;
            return sortByCreatedAt([...current, row]);
          });
        },
      )
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'handoff_requests' },
        (payload) => {
          const row = payload.new as HandoffRequest;
          setQueue((current) => {
            if (row.status !== 'pending') {
              return current.filter((r) => r.id !== row.id);
            }
            const idx = current.findIndex((r) => r.id === row.id);
            if (idx === -1) {
              return isAlive(row, Date.now())
                ? sortByCreatedAt([...current, row])
                : current;
            }
            const next = current.slice();
            next[idx] = row;
            return next;
          });
        },
      )
      .subscribe();

    const prune = setInterval(() => {
      const nowMs = Date.now();
      setQueue((current) => {
        const kept = current.filter((r) => isAlive(r, nowMs));
        return kept.length === current.length ? current : kept;
      });
    }, 500);

    return () => {
      supabase.removeChannel(channel);
      clearInterval(prune);
    };
  }, [refetch]);

  const clearIncoming = useCallback((id: number) => {
    setQueue((current) => current.filter((r) => r.id !== id));
  }, []);

  const incoming = useMemo<HandoffRequest | null>(
    () => queue[0] ?? null,
    [queue],
  );

  return { incoming, clearIncoming, refetch };
}
