import { useCallback, useEffect, useRef, useState } from 'react';
import { NativeModules, Platform, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect, useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { supabase } from '../lib/supabase';
import { useSession } from '../lib/session';
import { useIncomingHandoffs } from '../hooks/useIncomingHandoffs';
import { useOperatorBusy } from '../hooks/useOperatorBusy';
import { claimHandoff, rejectHandoff } from '../lib/edgeFunctions';
import { handleIncomingCallPayload, dismissIncomingByRequestId } from '../lib/pushRegistration';
import { IncomingCallCard } from '../components/IncomingCallCard';
import type { HandoffRequest } from '../types';
import type { RootStackParamList } from '../navigation/RootNavigator';

type Nav = NativeStackNavigationProp<RootStackParamList, 'Waiting'>;
type ScreenState = { kind: 'idle' } | { kind: 'incoming'; request: HandoffRequest };

export function WaitingScreen() {
  const session = useSession();
  const navigation = useNavigation<Nav>();
  const { isBusy, setIsBusy, refetch: refetchBusy } = useOperatorBusy(session.user.id);
  const { incoming, clearIncoming, refetch: refetchIncoming } = useIncomingHandoffs();

  const [state, setState] = useState<ScreenState>({ kind: 'idle' });
  const [toast, setToast] = useState<string | null>(null);
  const [signingOut, setSigningOut] = useState(false);

  useEffect(() => {
    if (state.kind === 'idle' && !isBusy && incoming) {
      setState({ kind: 'incoming', request: incoming });
      return;
    }
    if (state.kind === 'incoming' && (!incoming || incoming.id !== state.request.id)) {
      setState({ kind: 'idle' });
    }
  }, [incoming, state, isBusy]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(null), 3000);
    return () => clearTimeout(t);
  }, [toast]);

  // Android: drive the ringtone/notification from WaitingScreen state so there
  // is a single owner in-process. FCM background handler covers the killed-app
  // case; show() cancels any previous notification so there is no double-ring.
  const notifUuidRef = useRef<string | null>(null);
  useEffect(() => {
    if (Platform.OS !== 'android') return;
    const ui = NativeModules.IncomingCallUI as
      | { show: (uuid: string, name: string, handle: string | null, id: number) => void; hideAll: () => void }
      | undefined;
    if (!ui) return;

    if (state.kind === 'incoming') {
      const uuid = crypto.randomUUID();
      notifUuidRef.current = uuid;
      ui.show(uuid, state.request.caller_number ?? 'Sconosciuto', null, state.request.id);
    } else {
      if (notifUuidRef.current) {
        ui.hideAll();
        notifUuidRef.current = null;
      }
    }
    return () => {
      ui.hideAll();
      notifUuidRef.current = null;
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state.kind]);

  useFocusEffect(
    useCallback(() => {
      refetchBusy();
      refetchIncoming();
    }, [refetchBusy, refetchIncoming]),
  );

  async function handleAccept() {
    if (state.kind !== 'incoming') return;
    const request = state.request;
    setIsBusy(true);
    // Dismiss Android notification before awaiting the edge function so the
    // ringtone stops immediately on tap, not after the network round-trip.
    dismissIncomingByRequestId(request.id);
    const res = await claimHandoff(request.id, session);
    if (!res.ok) {
      setIsBusy(false);
      setToast(humanizeError(res.error.error));
      clearIncoming(request.id);
      return;
    }
    clearIncoming(request.id);
    navigation.navigate('InCall', { request, claim: res.data });
  }

  async function handleReject() {
    if (state.kind !== 'incoming') return;
    const request = state.request;
    // Dismiss notification immediately so the ringtone stops.
    dismissIncomingByRequestId(request.id);
    const res = await rejectHandoff(request.id, session);
    if (!res.ok && __DEV__) {
      console.warn('reject_handoff non-OK (probably already taken/expired)', res.error);
    }
    clearIncoming(request.id);
  }

  async function handleSignOut() {
    setSigningOut(true);
    await supabase.auth.signOut();
  }

  async function handleTestPush() {
    const nowIso = new Date().toISOString();
    const { data, error } = await supabase
      .from('handoff_requests')
      .select('id, caller_number, pizzeria_id, partial_order_id, expires_at')
      .eq('status', 'pending')
      .gt('expires_at', nowIso)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) { setToast(`Errore: ${error.message}`); return; }
    if (!data) { setToast('Nessuna richiesta pending da testare'); return; }

    const digits = String(data.caller_number ?? '').replace(/\D+/g, '');
    const masked = digits.length <= 4 ? '***' : `***${digits.slice(-4)}`;
    handleIncomingCallPayload({
      request_id: data.id,
      caller_number_masked: masked,
      pizzeria_id: data.pizzeria_id,
      partial_order_id: data.partial_order_id,
      expires_at: data.expires_at,
    });
  }

  return (
    <SafeAreaView style={styles.safe} edges={['bottom']}>
      <ScrollView contentContainerStyle={styles.container}>
        <View style={styles.headerRow}>
          <View style={[styles.statusBadge, isBusy ? styles.statusBusy : styles.statusIdle]}>
            <Text style={[styles.statusText, isBusy ? styles.statusTextBusy : styles.statusTextIdle]}>
              {isBusy ? 'occupato' : 'libero'}
            </Text>
          </View>
          <Text style={styles.email} numberOfLines={1}>
            {session.user.email ?? ''}
          </Text>
        </View>

        {toast && (
          <Pressable style={styles.toast} onPress={() => setToast(null)}>
            <Text style={styles.toastText}>{toast}</Text>
            <Text style={styles.toastDismiss}>tocca per chiudere</Text>
          </Pressable>
        )}

        {state.kind === 'idle' && (
          <View style={styles.idleCard}>
            <View style={styles.dot} />
            <Text style={styles.idleTitle}>In attesa di chiamate...</Text>
            <Text style={styles.idleHint}>
              Le nuove richieste compariranno qui automaticamente. Quando sei in chiamata,
              le nuove richieste vengono ignorate finché non riagganci.
            </Text>
          </View>
        )}

        {state.kind === 'incoming' && (
          <IncomingCallCard
            request={state.request}
            onAccept={handleAccept}
            onReject={handleReject}
            busy={isBusy}
          />
        )}

        <View style={styles.footer}>
          {__DEV__ && (
            <Pressable
              style={({ pressed }) => [styles.debugButton, pressed && styles.debugPressed]}
              onPress={handleTestPush}
            >
              <Text style={styles.debugText}>Debug · Simula push</Text>
            </Pressable>
          )}
          <Pressable
            style={({ pressed }) => [
              styles.signOut,
              (pressed || signingOut) && styles.signOutPressed,
            ]}
            onPress={handleSignOut}
            disabled={signingOut}
          >
            <Text style={styles.signOutText}>Esci</Text>
          </Pressable>
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

function humanizeError(code: string): string {
  switch (code) {
    case 'operator_busy': return "Sei già in un'altra chiamata";
    case 'expired_or_taken': return 'Chiamata già presa o scaduta';
    case 'Unauthorized': return 'Non autorizzato';
    case 'Forbidden': return 'Non sei admin di questa pizzeria';
    default: return 'Errore di connessione';
  }
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#f5f5f7' },
  container: { paddingHorizontal: 16, paddingVertical: 16, gap: 16, flexGrow: 1 },
  headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  statusBadge: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: 999 },
  statusIdle: { backgroundColor: '#dcfce7' },
  statusBusy: { backgroundColor: '#fef3c7' },
  statusText: { fontSize: 13, fontWeight: '600' },
  statusTextIdle: { color: '#166534' },
  statusTextBusy: { color: '#854d0e' },
  email: { color: '#6b7280', fontSize: 13, flexShrink: 1, marginLeft: 12 },
  toast: { backgroundColor: '#fde68a', borderRadius: 10, padding: 12 },
  toastText: { color: '#7c2d12', fontSize: 14, fontWeight: '500' },
  toastDismiss: { color: '#7c2d12', fontSize: 12, marginTop: 4, opacity: 0.7 },
  idleCard: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 20,
    alignItems: 'center',
    shadowColor: '#000',
    shadowOpacity: 0.05,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
    elevation: 1,
  },
  dot: { width: 10, height: 10, borderRadius: 5, backgroundColor: '#22c55e', marginBottom: 12 },
  idleTitle: { fontSize: 17, color: '#111', fontWeight: '500', marginBottom: 8 },
  idleHint: { fontSize: 13, color: '#6b7280', textAlign: 'center', lineHeight: 18 },
  footer: { marginTop: 'auto', alignItems: 'center', paddingTop: 16, gap: 12 },
  debugButton: {
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#a78bfa',
    backgroundColor: '#f5f3ff',
    borderStyle: 'dashed',
  },
  debugPressed: { opacity: 0.7 },
  debugText: { color: '#5b21b6', fontSize: 13, fontWeight: '600' },
  signOut: {
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#d1d1d6',
    backgroundColor: '#fff',
  },
  signOutPressed: { opacity: 0.7 },
  signOutText: { color: '#111', fontSize: 15, fontWeight: '500' },
});
