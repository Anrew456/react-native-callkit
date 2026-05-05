import { useCallback, useEffect, useState } from 'react';
import { AppState } from 'react-native';
import { supabase } from '../lib/supabase';

export function useOperatorBusy(userId: string | null) {
  const [isBusy, setIsBusy] = useState(false);

  const refetch = useCallback(async () => {
    if (!userId) {
      setIsBusy(false);
      return;
    }
    const { data, error } = await supabase.rpc('is_operator_busy', { p_user_id: userId });
    if (error) {
      if (__DEV__) console.error('is_operator_busy failed', error);
      return;
    }
    setIsBusy(Boolean(data));
  }, [userId]);

  useEffect(() => {
    refetch();
    if (!userId) return;

    const channel = supabase
      .channel(`operator-busy-${userId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'handoff_requests',
          filter: `claimed_by=eq.${userId}`,
        },
        () => {
          refetch();
        },
      )
      .subscribe();

    const sub = AppState.addEventListener('change', (state) => {
      if (state === 'active') refetch();
    });

    return () => {
      supabase.removeChannel(channel);
      sub.remove();
    };
  }, [refetch, userId]);

  return { isBusy, setIsBusy, refetch };
}
