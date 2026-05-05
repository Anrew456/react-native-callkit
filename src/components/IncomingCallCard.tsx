import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import type { HandoffRequest } from '../types';

interface Props {
  request: HandoffRequest;
  onAccept: () => void;
  onReject: () => void;
  busy: boolean;
}

function secondsUntil(iso: string): number {
  return Math.max(0, Math.ceil((new Date(iso).getTime() - Date.now()) / 1000));
}

export function IncomingCallCard({ request, onAccept, onReject, busy }: Props) {
  const [secondsLeft, setSecondsLeft] = useState(() => secondsUntil(request.expires_at));

  useEffect(() => {
    const id = setInterval(() => setSecondsLeft(secondsUntil(request.expires_at)), 500);
    return () => clearInterval(id);
  }, [request.expires_at]);

  const expired = secondsLeft <= 0;
  const acceptDisabled = busy || expired;
  const rejectDisabled = expired;

  return (
    <View style={styles.card}>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Chiamata in arrivo</Text>
        <View style={[styles.badge, expired && styles.badgeExpired]}>
          <Text style={[styles.badgeText, expired && styles.badgeTextExpired]}>
            {expired ? 'scaduta' : `${secondsLeft}s`}
          </Text>
        </View>
      </View>

      <Text style={styles.muted}>Pizzeria #{request.pizzeria_id}</Text>

      <Text style={styles.row}>
        <Text style={styles.rowLabel}>Numero: </Text>
        <Text style={styles.rowValue}>{request.caller_number}</Text>
      </Text>

      {request.partial_order_id != null && (
        <Text style={styles.muted}>Ordine parziale n. {request.partial_order_id}</Text>
      )}

      <View style={styles.buttonRow}>
        <Pressable
          style={({ pressed }) => [
            styles.button,
            styles.accept,
            acceptDisabled && styles.buttonDisabled,
            pressed && !acceptDisabled && styles.pressed,
          ]}
          onPress={onAccept}
          disabled={acceptDisabled}
        >
          <Text style={styles.buttonText}>Accetta</Text>
        </Pressable>
        <Pressable
          style={({ pressed }) => [
            styles.button,
            styles.reject,
            rejectDisabled && styles.buttonDisabled,
            pressed && !rejectDisabled && styles.pressed,
          ]}
          onPress={onReject}
          disabled={rejectDisabled}
        >
          <Text style={styles.buttonText}>Rifiuta</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    padding: 20,
    shadowColor: '#000',
    shadowOpacity: 0.08,
    shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 },
    elevation: 2,
  },
  headerRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 8,
  },
  title: { fontSize: 18, fontWeight: '600', color: '#111' },
  badge: {
    backgroundColor: '#e5f1ff',
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  badgeExpired: { backgroundColor: '#fde8e8' },
  badgeText: { color: '#0a7ea4', fontSize: 13, fontWeight: '600' },
  badgeTextExpired: { color: '#9b1c1c' },
  muted: { color: '#6b7280', fontSize: 14, marginTop: 4 },
  row: { marginTop: 12, fontSize: 16, color: '#111' },
  rowLabel: { fontWeight: '600' },
  rowValue: { fontWeight: '400' },
  buttonRow: { flexDirection: 'row', gap: 12, marginTop: 20 },
  button: { flex: 1, paddingVertical: 14, borderRadius: 10, alignItems: 'center' },
  accept: { backgroundColor: '#0a7ea4' },
  reject: { backgroundColor: '#b91c1c' },
  buttonDisabled: { opacity: 0.5 },
  pressed: { opacity: 0.85 },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: '600' },
});
