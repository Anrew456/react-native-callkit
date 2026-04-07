import React, {
  useCallback,
  useEffect,
  useRef,
  useState,
  useSyncExternalStore,
} from 'react';
import {
  Clipboard,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  useColorScheme,
  View,
} from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
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

const colors = {
  light: {
    background: '#F2F2F7',
    section: '#FFFFFF',
    text: '#000000',
    secondaryText: '#8E8E93',
    sectionHeader: '#6D6D72',
    separator: '#C6C6C8',
    link: '#007AFF',
    destructive: '#FF3B30',
    toastBackground: '#FFFFFF',
    shadow: '#000000',
    caller: '#5856D6',
  },
  dark: {
    background: '#000000',
    section: '#1C1C1E',
    text: '#FFFFFF',
    secondaryText: '#8E8E93',
    sectionHeader: '#98989D',
    separator: '#38383A',
    link: '#0A84FF',
    destructive: '#FF453A',
    toastBackground: '#2C2C2E',
    shadow: '#000000',
    caller: '#BF5AF2',
  },
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
  const isDarkMode = useColorScheme() === 'dark';
  const theme = isDarkMode ? colors.dark : colors.light;

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
    <SafeAreaView
      style={[styles.container, { backgroundColor: theme.background }]}
      edges={['top', 'bottom']}
    >
      <ScrollView
        style={styles.scrollView}
        contentContainerStyle={styles.content}
      >
        <Text style={[styles.title, { color: theme.text }]}>
          CallKit Example
        </Text>

        {/* Section 1: States */}
        <SectionHeader title="States" color={theme.sectionHeader} />
        <View
          style={[
            styles.section,
            { backgroundColor: theme.section, borderColor: theme.separator },
          ]}
        >
          <StateRow
            color={roomStateColor(state.roomConnectionState)}
            label="Room state"
            value={roomStateLabel(state.roomConnectionState)}
            theme={theme}
          />
          <Separator color={theme.separator} />
          <StateRow
            color={callStateColor(state.callState)}
            label="Call state"
            value={state.callState}
            theme={theme}
          />
          <Separator color={theme.separator} />
          <StateRow
            color={theme.link}
            label="Call ID"
            value={state.activeCallUUID ?? 'Not in a call'}
            theme={theme}
            monospaced
          />
          <Separator color={theme.separator} />
          <StateRow
            color={state.callerName ? theme.caller : theme.secondaryText}
            label="Caller"
            value={state.callerName ?? 'No caller'}
            theme={theme}
          />
        </View>

        {/* Section 2: Room for Testing */}
        <SectionHeader
          title="1. Room for testing"
          color={theme.sectionHeader}
        />
        <View
          style={[
            styles.section,
            { backgroundColor: theme.section, borderColor: theme.separator },
          ]}
        >
          <TextInput
            style={[styles.textInput, { color: theme.text }]}
            placeholder="URL"
            placeholderTextColor={theme.secondaryText}
            value={state.url}
            onChangeText={text => manager.setUrl(text)}
            autoCapitalize="none"
            autoCorrect={false}
            keyboardType="url"
            editable={
              state.roomConnectionState === ConnectionState.Disconnected
            }
          />
          <Separator color={theme.separator} />
          <TextInput
            style={[styles.textInput, { color: theme.text }]}
            placeholder="Token"
            placeholderTextColor={theme.secondaryText}
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
        <SectionHeader title="3. VoIP Push Token" color={theme.sectionHeader} />
        <View
          style={[
            styles.section,
            { backgroundColor: theme.section, borderColor: theme.separator },
          ]}
        >
          {state.voipToken ? (
            <TouchableOpacity onPress={copyToken} style={styles.tokenRow}>
              <Text
                style={[styles.tokenText, { color: theme.text }]}
                numberOfLines={2}
              >
                {state.voipToken}
              </Text>
              <Text style={[styles.copyIcon, { color: theme.link }]}>
                {'Copy'}
              </Text>
            </TouchableOpacity>
          ) : (
            <View style={styles.row}>
              <Text style={[styles.grayText, { color: theme.secondaryText }]}>
                No VoIP token available
              </Text>
            </View>
          )}
        </View>

        {/* Section 4: Call Controls */}
        <SectionHeader title="4. Call" color={theme.sectionHeader} />
        <View
          style={[
            styles.section,
            { backgroundColor: theme.section, borderColor: theme.separator },
          ]}
        >
          {state.hasActiveCall ? (
            <TouchableOpacity
              style={styles.buttonRow}
              onPress={() => manager.endCall()}
            >
              <Text
                style={[styles.destructiveText, { color: theme.destructive }]}
              >
                End call
              </Text>
            </TouchableOpacity>
          ) : (
            <>
              <TouchableOpacity
                style={styles.buttonRow}
                onPress={() => manager.startCall('user1')}
              >
                <Text style={[styles.linkText, { color: theme.link }]}>
                  Start call
                </Text>
              </TouchableOpacity>
              <Separator color={theme.separator} />
              <TouchableOpacity
                style={styles.buttonRow}
                onPress={() => manager.simulateIncomingCall('Tommie Sunshine')}
              >
                <Text style={[styles.linkText, { color: theme.link }]}>
                  Simulate incoming call
                </Text>
              </TouchableOpacity>
            </>
          )}
        </View>
      </ScrollView>

      {/* Toast */}
      {showToast && (
        <View
          style={[
            styles.toast,
            {
              backgroundColor: theme.toastBackground,
              shadowColor: theme.shadow,
            },
          ]}
        >
          <Text style={styles.toastIcon}>{'✓'}</Text>
          <Text style={[styles.toastText, { color: theme.text }]}>
            Token copied to clipboard
          </Text>
        </View>
      )}
    </SafeAreaView>
  );
}

// --- Sub-components ---

function SectionHeader({ title, color }: { title: string; color: string }) {
  return <Text style={[styles.sectionHeader, { color }]}>{title}</Text>;
}

function Separator({ color }: { color: string }) {
  return <View style={[styles.separator, { backgroundColor: color }]} />;
}

function StateRow({
  color,
  label,
  value,
  monospaced,
  theme,
}: {
  color: string;
  label: string;
  value: string;
  monospaced?: boolean;
  theme: typeof colors.light;
}) {
  return (
    <View style={styles.stateRow}>
      <View style={styles.stateRowLeft}>
        <View style={[styles.statusDot, { backgroundColor: color }]} />
        <Text style={[styles.stateLabel, { color: theme.text }]}>{label}</Text>
      </View>
      <Text
        style={[
          styles.stateValue,
          { color: theme.secondaryText },
          monospaced && styles.monospaced,
        ]}
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
  },
  sectionHeader: {
    fontSize: 13,
    fontWeight: '400',
    textTransform: 'uppercase',
    marginTop: 24,
    marginBottom: 8,
    marginLeft: 16,
  },
  section: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  separator: {
    height: StyleSheet.hairlineWidth,
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
  },
  stateValue: {
    fontSize: 13,
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
  },
  copyIcon: {
    fontSize: 15,
    marginLeft: 8,
  },
  grayText: {
    fontSize: 17,
  },
  buttonRow: {
    paddingHorizontal: 16,
    paddingVertical: 12,
    minHeight: 44,
    justifyContent: 'center',
  },
  linkText: {
    fontSize: 17,
  },
  destructiveText: {
    fontSize: 17,
  },
  toast: {
    position: 'absolute',
    bottom: 50,
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 8,
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
  },
});
