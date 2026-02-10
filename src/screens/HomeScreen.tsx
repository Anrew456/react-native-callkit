import React, {
  useCallback,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Alert,
  Clipboard,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { ConnectionState } from 'livekit-client';
import CallManager from '../CallManager';
import type { CallState } from '../types';

type Snapshot = {
  callState: CallState;
  voipToken: string | null;
  activeCallUUID: string | null;
  callerName: string | null;
  callerHandle: string | null;
  url: string;
  token: string;
  hasActiveCall: boolean;
  roomConnectionState: ConnectionState;
};

function useCallManager() {
  const manager = CallManager.shared;
  const subscribe = useCallback(
    (cb: () => void) => manager.subscribe(cb),
    [manager],
  );
  const cachedRef = useRef<Snapshot | null>(null);
  const getSnapshot = useCallback((): Snapshot => {
    const prev = cachedRef.current;
    if (
      prev !== null &&
      prev.callState === manager.callState &&
      prev.voipToken === manager.voipToken &&
      prev.activeCallUUID === manager.activeCallUUID &&
      prev.callerName === manager.callerName &&
      prev.callerHandle === manager.callerHandle &&
      prev.url === manager.url &&
      prev.token === manager.token &&
      prev.hasActiveCall === manager.hasActiveCall &&
      prev.roomConnectionState === manager.roomConnectionState
    ) {
      return prev;
    }
    const next: Snapshot = {
      callState: manager.callState,
      voipToken: manager.voipToken,
      activeCallUUID: manager.activeCallUUID,
      callerName: manager.callerName,
      callerHandle: manager.callerHandle,
      url: manager.url,
      token: manager.token,
      hasActiveCall: manager.hasActiveCall,
      roomConnectionState: manager.roomConnectionState,
    };
    cachedRef.current = next;
    return next;
  }, [manager]);
  return useSyncExternalStore(subscribe, getSnapshot);
}

export default function HomeScreen() {
  const state = useCallManager();
  const manager = CallManager.shared;
  const [showToast, setShowToast] = useState(false);

  const copyToken = useCallback(() => {
    if (state.voipToken) {
      Clipboard.setString(state.voipToken);
      setShowToast(true);
    }
  }, [state.voipToken]);

  useEffect(() => {
    if (showToast) {
      const timer = setTimeout(() => setShowToast(false), 2000);
      return () => clearTimeout(timer);
    }
  }, [showToast]);

  return (
    <View style={styles.container}>
      <ScrollView
        style={styles.scrollView}
        contentContainerStyle={styles.content}
      >
        <Text style={styles.title}>CallKit Example</Text>

        {/* Section 1: States */}
        <SectionHeader title="States" />
        <View style={styles.section}>
          <StateRow
            color={roomStateColor(state.roomConnectionState)}
            label="Room state"
            value={roomStateLabel(state.roomConnectionState)}
          />
          <Separator />
          <StateRow
            color={callStateColor(state.callState)}
            label="Call state"
            value={state.callState}
          />
          <Separator />
          <StateRow
            color="#007AFF"
            label="Call ID"
            value={state.activeCallUUID ?? 'Not in a call'}
            monospaced
          />
          <Separator />
          <StateRow
            color={state.callerName ? '#5856D6' : '#8E8E93'}
            label="Caller"
            value={state.callerName ?? 'No caller'}
          />
        </View>

        {/* Section 2: Room for Testing */}
        <SectionHeader title="1. Room for testing" />
        <View style={styles.section}>
          <TextInput
            style={styles.textInput}
            placeholder="URL"
            value={state.url}
            onChangeText={text => manager.setUrl(text)}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            editable={
              state.roomConnectionState === ConnectionState.Disconnected
            }
          />
          <Separator />
          <TextInput
            style={styles.textInput}
            placeholder="Token"
            value={state.token}
            onChangeText={text => manager.setToken(text)}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            editable={
              state.roomConnectionState === ConnectionState.Disconnected
            }
          />
        </View>

        {/* Section 3: VoIP Push Token */}
        <SectionHeader title="3. VoIP Push Token" />
        <View style={styles.section}>
          {state.voipToken ? (
            <TouchableOpacity onPress={copyToken} style={styles.tokenRow}>
              <Text style={styles.tokenText} numberOfLines={2}>
                {state.voipToken}
              </Text>
              <Text style={styles.copyIcon}>{'Copy'}</Text>
            </TouchableOpacity>
          ) : (
            <View style={styles.row}>
              <Text style={styles.grayText}>No VoIP token available</Text>
            </View>
          )}
        </View>

        {/* Section 4: Call Controls */}
        <SectionHeader title="4. Call" />
        <View style={styles.section}>
          {state.hasActiveCall ? (
            <TouchableOpacity
              style={styles.buttonRow}
              onPress={() => manager.endCall()}
            >
              <Text style={styles.destructiveText}>End call</Text>
            </TouchableOpacity>
          ) : (
            <>
              <TouchableOpacity
                style={styles.buttonRow}
                onPress={() => manager.startCall('user1')}
              >
                <Text style={styles.linkText}>Start call</Text>
              </TouchableOpacity>
              <Separator />
              <TouchableOpacity
                style={styles.buttonRow}
                onPress={() => manager.simulateIncomingCall('Tommie Sunshine')}
              >
                <Text style={styles.linkText}>Simulate incoming call</Text>
              </TouchableOpacity>
            </>
          )}
        </View>
      </ScrollView>

      {/* Toast */}
      {showToast && (
        <View style={styles.toast}>
          <Text style={styles.toastIcon}>{'✓'}</Text>
          <Text style={styles.toastText}>Token copied to clipboard</Text>
        </View>
      )}
    </View>
  );
}

// --- Sub-components ---

function SectionHeader({ title }: { title: string }) {
  return <Text style={styles.sectionHeader}>{title}</Text>;
}

function Separator() {
  return <View style={styles.separator} />;
}

function StateRow({
  color,
  label,
  value,
  monospaced,
}: {
  color: string;
  label: string;
  value: string;
  monospaced?: boolean;
}) {
  return (
    <View style={styles.stateRow}>
      <View style={styles.stateRowLeft}>
        <View style={[styles.statusDot, { backgroundColor: color }]} />
        <Text style={styles.stateLabel}>{label}</Text>
      </View>
      <Text
        style={[styles.stateValue, monospaced && styles.monospaced]}
        numberOfLines={1}
      >
        {value}
      </Text>
    </View>
  );
}

// --- Helpers ---

function roomStateColor(state: ConnectionState): string {
  switch (state) {
    case ConnectionState.Disconnected:
      return '#FF3B30';
    case ConnectionState.Connecting:
      return '#FF9500';
    case ConnectionState.Connected:
      return '#34C759';
    case ConnectionState.Reconnecting:
      return '#007AFF';
    default:
      return '#8E8E93';
  }
}

function roomStateLabel(state: ConnectionState): string {
  switch (state) {
    case ConnectionState.Disconnected:
      return 'disconnected';
    case ConnectionState.Connecting:
      return 'connecting';
    case ConnectionState.Connected:
      return 'connected';
    case ConnectionState.Reconnecting:
      return 'reconnecting';
    default:
      return state;
  }
}

function callStateColor(state: CallState): string {
  switch (state) {
    case 'idle':
      return '#8E8E93';
    case 'errored':
      return '#FF3B30';
    case 'activeIncoming':
      return '#007AFF';
    case 'activeOutgoing':
      return '#FF9500';
    case 'connected':
      return '#34C759';
    default:
      return '#8E8E93';
  }
}

// --- Styles ---

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F2F2F7',
  },
  scrollView: {
    flex: 1,
  },
  content: {
    paddingTop: 16,
    paddingBottom: 40,
  },
  title: {
    fontSize: 28,
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 16,
    color: '#000',
  },
  sectionHeader: {
    fontSize: 13,
    fontWeight: '400',
    color: '#6D6D72',
    textTransform: 'uppercase',
    marginTop: 24,
    marginBottom: 8,
    marginLeft: 16,
  },
  section: {
    backgroundColor: '#FFFFFF',
    borderTopWidth: StyleSheet.hairlineWidth,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderColor: '#C6C6C8',
  },
  separator: {
    height: StyleSheet.hairlineWidth,
    backgroundColor: '#C6C6C8',
    marginLeft: 16,
  },
  stateRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 16,
    paddingVertical: 12,
    minHeight: 44,
  },
  stateRowLeft: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  statusDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
  },
  stateLabel: {
    fontSize: 17,
    fontWeight: '500',
    color: '#000',
  },
  stateValue: {
    fontSize: 13,
    color: '#8E8E93',
    flexShrink: 1,
    marginLeft: 8,
  },
  monospaced: {
    fontFamily: 'Menlo',
  },
  textInput: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    fontSize: 17,
    color: '#000',
    minHeight: 44,
  },
  row: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    minHeight: 44,
    justifyContent: 'center',
  },
  tokenRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 12,
    minHeight: 44,
  },
  tokenText: {
    flex: 1,
    fontSize: 13,
    fontFamily: 'Menlo',
    color: '#000',
  },
  copyIcon: {
    fontSize: 15,
    color: '#007AFF',
    marginLeft: 8,
  },
  grayText: {
    fontSize: 17,
    color: '#8E8E93',
  },
  buttonRow: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    minHeight: 44,
    justifyContent: 'center',
  },
  linkText: {
    fontSize: 17,
    color: '#007AFF',
  },
  destructiveText: {
    fontSize: 17,
    color: '#FF3B30',
  },
  toast: {
    position: 'absolute',
    bottom: 50,
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.15,
    shadowRadius: 4,
    elevation: 4,
    gap: 8,
  },
  toastIcon: {
    fontSize: 16,
    color: '#34C759',
  },
  toastText: {
    fontSize: 15,
    color: '#000',
  },
});
