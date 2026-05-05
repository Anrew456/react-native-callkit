import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useNavigation, type RouteProp, useRoute } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { RoomEvent } from 'livekit-client';
import { useSession } from '../lib/session';
import { supabase } from '../lib/supabase';
import { completeHandoff } from '../lib/edgeFunctions';
import { endCallKeepSession } from '../lib/pushRegistration';
import CallManager from '../CallManager';
import type { RootStackParamList } from '../navigation/RootNavigator';

type Nav = NativeStackNavigationProp<RootStackParamList, 'InCall'>;
type Route = RouteProp<RootStackParamList, 'InCall'>;

export function InCallScreen() {
  const navigation = useNavigation<Nav>();
  const { params } = useRoute<Route>();
  const session = useSession();
  const { request, claim, callUUID } = params;

  const completedRef = useRef(false);
  const [connected, setConnected] = useState(false);
  const [muted, setMuted] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [partialOrder, setPartialOrder] = useState<unknown>(null);

  const markCompleted = useCallback(() => {
    if (completedRef.current) return;
    completedRef.current = true;
    completeHandoff(request.id, session).then((res) => {
      if (!res.ok && __DEV__) console.warn('complete_handoff non-OK', res.error);
    });
  }, [request.id, session]);

  useEffect(() => {
    const room = CallManager.shared.room;

    const handleDisconnect = () => {
      setConnected(false);
      markCompleted();
      endCallKeepSession(callUUID);
      navigation.goBack();
    };
    room.on(RoomEvent.Disconnected, handleDisconnect);

    CallManager.shared.connectWithClaim(claim.livekit_url, claim.token)
      .then(() => setConnected(true))
      .catch((err: unknown) => {
        if (__DEV__) console.error('LiveKit connect failed', err);
        setError(err instanceof Error ? err.message : 'Connessione fallita');
      });

    return () => {
      room.off(RoomEvent.Disconnected, handleDisconnect);
      endCallKeepSession(callUUID);
      markCompleted();
    };
  }, [claim.livekit_url, claim.token, callUUID, navigation, markCompleted]);

  useEffect(() => {
    if (request.partial_order_id == null) return;
    let cancelled = false;
    (async () => {
      const { data, error: err } = await supabase
        .from('orders')
        .select('*')
        .eq('id', request.partial_order_id)
        .maybeSingle();
      if (cancelled) return;
      if (err) { if (__DEV__) console.warn('partial order fetch failed', err); return; }
      setPartialOrder(data);
    })();
    return () => { cancelled = true; };
  }, [request.partial_order_id]);

  async function toggleMute() {
    const next = !muted;
    await CallManager.shared.room.localParticipant.setMicrophoneEnabled(!next);
    setMuted(next);
  }

  async function hangup() {
    await CallManager.shared.endCall();
  }

  return (
    <SafeAreaView style={styles.safe} edges={['bottom']}>
      <ScrollView contentContainerStyle={styles.container}>
        <View style={styles.headerRow}>
          <Text style={styles.title}>In chiamata</Text>
          <View style={[styles.statusBadge, connected ? styles.statusOn : styles.statusOff]}>
            <Text style={[styles.statusText, connected ? styles.statusTextOn : styles.statusTextOff]}>
              {connected ? 'connesso' : 'in connessione...'}
            </Text>
          </View>
        </View>

        {error && (
          <View style={styles.errorBox}>
            <Text style={styles.errorText}>{error}</Text>
          </View>
        )}

        <View style={styles.infoCard}>
          <Text style={styles.label}>Chiamante</Text>
          <Text style={styles.callerNumber}>{request.caller_number}</Text>

          <Text style={styles.label}>Pizzeria</Text>
          <Text style={styles.value}>#{request.pizzeria_id}</Text>

          <Text style={styles.label}>Stanza</Text>
          <Text style={styles.valueMono}>{claim.room_name}</Text>
        </View>

        <View style={styles.buttonRow}>
          <Pressable
            style={({ pressed }) => [
              styles.muteButton,
              muted && styles.muteActive,
              !connected && styles.buttonDisabled,
              pressed && connected && styles.pressed,
            ]}
            onPress={toggleMute}
            disabled={!connected}
          >
            <Text style={[styles.muteText, muted && styles.muteTextActive]}>
              {muted ? 'Riattiva microfono' : 'Muta microfono'}
            </Text>
          </Pressable>
        </View>

        {request.partial_order_id != null && (
          <View style={styles.partialCard}>
            <Text style={styles.partialTitle}>Ordine parziale</Text>
            {partialOrder == null ? (
              <Text style={styles.muted}>Caricamento ordine n. {request.partial_order_id}...</Text>
            ) : (
              <ScrollView horizontal>
                <Text style={styles.json}>{JSON.stringify(partialOrder, null, 2)}</Text>
              </ScrollView>
            )}
          </View>
        )}

        <Pressable
          style={({ pressed }) => [styles.hangup, pressed && styles.pressed]}
          onPress={hangup}
        >
          <Text style={styles.hangupText}>Chiudi chiamata</Text>
        </Pressable>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#f5f5f7' },
  container: { paddingHorizontal: 16, paddingVertical: 16, gap: 16, flexGrow: 1 },
  headerRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  title: { fontSize: 22, fontWeight: '600', color: '#111' },
  statusBadge: { paddingHorizontal: 10, paddingVertical: 4, borderRadius: 999 },
  statusOn: { backgroundColor: '#dcfce7' },
  statusOff: { backgroundColor: '#fef3c7' },
  statusText: { fontSize: 13, fontWeight: '600' },
  statusTextOn: { color: '#166534' },
  statusTextOff: { color: '#854d0e' },
  errorBox: { backgroundColor: '#fde8e8', borderRadius: 10, padding: 12 },
  errorText: { color: '#9b1c1c', fontSize: 14 },
  infoCard: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    gap: 4,
    shadowColor: '#000',
    shadowOpacity: 0.05,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
    elevation: 1,
  },
  label: {
    fontSize: 12,
    color: '#6b7280',
    textTransform: 'uppercase',
    letterSpacing: 0.5,
    marginTop: 8,
  },
  callerNumber: { fontSize: 24, color: '#111', fontWeight: '600' },
  value: { fontSize: 16, color: '#111' },
  valueMono: { fontSize: 13, color: '#111', fontFamily: 'Menlo' },
  buttonRow: { flexDirection: 'row' },
  muteButton: {
    flex: 1,
    paddingVertical: 14,
    borderRadius: 10,
    alignItems: 'center',
    backgroundColor: '#e5e7eb',
  },
  muteActive: { backgroundColor: '#fde68a' },
  buttonDisabled: { opacity: 0.5 },
  pressed: { opacity: 0.85 },
  muteText: { color: '#111', fontSize: 16, fontWeight: '600' },
  muteTextActive: { color: '#7c2d12' },
  partialCard: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 16,
    shadowColor: '#000',
    shadowOpacity: 0.05,
    shadowRadius: 8,
    shadowOffset: { width: 0, height: 2 },
    elevation: 1,
  },
  partialTitle: { fontSize: 14, fontWeight: '600', color: '#111', marginBottom: 8 },
  muted: { color: '#6b7280', fontSize: 13 },
  json: { fontFamily: 'Menlo', fontSize: 12, color: '#111' },
  hangup: {
    marginTop: 'auto',
    backgroundColor: '#b91c1c',
    paddingVertical: 16,
    borderRadius: 12,
    alignItems: 'center',
  },
  hangupText: { color: '#fff', fontSize: 17, fontWeight: '700' },
});
