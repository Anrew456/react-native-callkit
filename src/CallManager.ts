import { Room, ConnectionState } from 'livekit-client';
import {
  AudioDeviceModule,
  AudioEngineAvailability,
  AudioSession,
} from '@livekit/react-native';
import RNCallKeep, { CONSTANTS as CK_CONSTANTS } from '@livekit/react-native-callkeep';
import { NativeEventEmitter, NativeModules, PermissionsAndroid, Platform } from 'react-native';
import type { CallState } from './types';

const IncomingCallUI = NativeModules.IncomingCallUI as
  | { show: (uuid: string, name: string, handle: string | null) => void; hide: (uuid: string) => void }
  | undefined;

type CallManagerListener = () => void;

class CallManager {
  // State
  callState: CallState = 'idle';
  voipToken: string | null = null;
  activeCallUUID: string | null = null;
  callerName: string | null = null;
  callerHandle: string | null = null;

  // LiveKit
  readonly room = new Room();

  private listeners = new Set<CallManagerListener>();
  private static _instance: CallManager | null = null;

  static get shared(): CallManager {
    if (!CallManager._instance) {
      CallManager._instance = new CallManager();
    }
    return CallManager._instance;
  }

  private constructor() {
    this.initialize();
  }

  private async initialize() {
    if (Platform.OS === 'ios') {
      try {
        await AudioDeviceModule.setEngineAvailability(AudioEngineAvailability.none);
      } catch (e) {
        if (__DEV__) console.error('Failed to set engine availability:', e);
      }
    }

    await this.setupCallKeep();
    this.setupPushKit();

    this.room.on('connectionStateChanged', () => {
      this.notifyListeners();
    });
  }

  private async setupCallKeep() {
    await RNCallKeep.setup({
      ios: {
        appName: 'LiveKitCallKit',
        supportsVideo: false,
        maximumCallGroups: '1',
        maximumCallsPerCallGroup: '1',
        includesCallsInRecents: false,
        audioSession: {
          autoConfigure: false,
        },
      },
      android: {
        alertTitle: 'Permissions required',
        alertDescription:
          'This application needs to access your phone accounts',
        cancelButton: 'Cancel',
        okButton: 'Ok',
        additionalPermissions: [],
        selfManaged: true,
        foregroundService: {
          channelId: 'io.livekit.callkit',
          channelName: 'Foreground Service',
          notificationTitle: 'LiveKit CallKit Example is running',
          notificationIcon: 'ic_launcher',
        },
      },
    });
    if (Platform.OS === 'android') {
      RNCallKeep.registerAndroidEvents();
    }

    // Audio session coordination with the SDK's AudioEngine (iOS only)
    RNCallKeep.addEventListener('didActivateAudioSession', () => {
      if (__DEV__) console.log('[CallManager] Audio session activated');
      if (Platform.OS === 'ios') {
        AudioSession.setAppleAudioConfiguration({
          audioCategory: 'playAndRecord',
          audioCategoryOptions: [
            'allowBluetooth',
            'allowBluetoothA2DP',
            'allowAirPlay',
            'defaultToSpeaker',
          ],
          audioMode: 'voiceChat',
        })
          .then(() =>
            AudioDeviceModule.setEngineAvailability(AudioEngineAvailability.default),
          )
          .catch(e => { if (__DEV__) console.error('Failed to configure audio session:', e); });
      }
    });

    RNCallKeep.addEventListener('didDeactivateAudioSession', () => {
      if (__DEV__) console.log('[CallManager] Audio session deactivated');
      if (Platform.OS === 'ios') {
        AudioDeviceModule.setEngineAvailability(AudioEngineAvailability.none)
          .catch(e => { if (__DEV__) console.error('Failed to set engine availability:', e); });
      }
    });

    // iOS only: incoming call shown via CallKit (future VoIP push path)
    RNCallKeep.addEventListener('didDisplayIncomingCall', ({ error, callUUID, handle, localizedCallerName }) => {
      if (error) {
        if (__DEV__) console.error('[CallManager] Display incoming call error:', error);
        this.updateCallState('errored');
        return;
      }
      if (__DEV__) console.log('[CallManager] Incoming call displayed:', callUUID);
      this.activeCallUUID = callUUID;
      this.callerHandle = handle || null;
      this.callerName = localizedCallerName || null;
      this.updateCallState('activeIncoming');
    });

    // Android: incoming call UI events are handled in pushRegistration.ts

    // Mute action (from CallKit / ConnectionService)
    RNCallKeep.addEventListener('didPerformSetMutedCallAction', ({ muted, callUUID }) => {
      if (__DEV__) console.log('[CallManager] Mute:', muted, callUUID);
      this.room.localParticipant
        ?.setMicrophoneEnabled(!muted)
        .catch(e => { if (__DEV__) console.error('Failed to set microphone:', e); });
    });

    // Provider reset
    RNCallKeep.addEventListener('didResetProvider', () => {
      if (__DEV__) console.log('[CallManager] Provider reset');
      this.activeCallUUID = null;
      this.callerName = null;
      this.callerHandle = null;
      this.updateCallState('idle');
    });

    RNCallKeep.addEventListener('didChangeAudioRoute', () => { });
    RNCallKeep.addEventListener('didReceiveStartCallAction', ({ callUUID, handle }) => {
      if (__DEV__) console.log('[CallManager] Start call action:', callUUID, handle);
    });
  }

  private setupPushKit() {
    if (Platform.OS !== 'ios') return;

    const { PushKitManager } = NativeModules;
    if (!PushKitManager) {
      if (__DEV__) console.warn('[CallManager] PushKitManager native module not found');
      return;
    }

    const emitter = new NativeEventEmitter(PushKitManager);

    emitter.addListener('voipTokenUpdated', ({ token }: { token: string }) => {
      if (__DEV__) console.log('[CallManager] VoIP token updated:', token);
      this.voipToken = token;
      this.notifyListeners();
    });

    emitter.addListener('voipTokenInvalidated', () => {
      if (__DEV__) console.log('[CallManager] VoIP token invalidated');
      this.voipToken = null;
      this.notifyListeners();
    });
  }

  // --- Public API ---

  get hasActiveCall(): boolean {
    return (
      this.callState === 'activeIncoming' ||
      this.callState === 'activeOutgoing' ||
      this.callState === 'connected'
    );
  }

  get roomConnectionState(): ConnectionState {
    return this.room.state;
  }

  async requestOnboardingPermissions() {
    if (Platform.OS !== 'android') return;
    await PermissionsAndroid.requestMultiple([
      PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
      PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
    ]);
  }

  // Connect to a LiveKit room using a token from claim_handoff edge function.
  // Audio session is activated here for platforms that don't use CallKit
  // to manage the session automatically (Android always; iOS Realtime path).
  async connectWithClaim(url: string, token: string) {
    if (__DEV__) console.log('[CallManager] Connecting with claim to:', url);
    if (Platform.OS === 'ios') {
      // For the Realtime path (no CallKit involved), we must activate audio
      // manually. For the future VoIP-push/CallKit path didActivateAudioSession
      // already ran, so calling setEngineAvailability(default) again is a no-op.
      await AudioSession.setAppleAudioConfiguration({
        audioCategory: 'playAndRecord',
        audioCategoryOptions: [
          'allowBluetooth',
          'allowBluetoothA2DP',
          'allowAirPlay',
          'defaultToSpeaker',
        ],
        audioMode: 'voiceChat',
      }).catch(e => { if (__DEV__) console.error('Failed to configure audio session:', e); });
      await AudioDeviceModule.setEngineAvailability(AudioEngineAvailability.default)
        .catch(e => { if (__DEV__) console.error('Failed to set engine availability:', e); });
    } else {
      await AudioSession.startAudioSession();
    }
    await this.room.connect(url, token);
    await this.room.localParticipant.setMicrophoneEnabled(true);
    if (__DEV__) console.log('[CallManager] Connected with claim');
    this.notifyListeners();
  }

  // Outgoing call (iOS: via CallKit; Android: direct connect).
  // Primarily used for testing; production calls come from claim_handoff.
  async startCall(handle: string) {
    const uuid = crypto.randomUUID();
    this.activeCallUUID = uuid;
    this.updateCallState('activeOutgoing');

    if (Platform.OS === 'android') {
      try {
        await this.ensureAndroidCallPermissions();
        // Android outgoing calls bypass VoiceConnectionService to avoid
        // foreground-service icon crash; connect directly to LiveKit.
        // URL/token must be set before calling this method.
      } catch (e) {
        if (__DEV__) console.error('Failed to start call:', e);
        this.updateCallState('errored');
        this.activeCallUUID = null;
        this.notifyListeners();
      }
    } else {
      RNCallKeep.startCall(uuid, handle, 'LiveKit Call', 'generic', false);
      RNCallKeep.reportConnectingOutgoingCallWithUUID(uuid);
      try {
        RNCallKeep.reportConnectedOutgoingCallWithUUID(uuid);
        this.updateCallState('connected');
      } catch (e) {
        if (__DEV__) console.error('Failed to start call:', e);
        RNCallKeep.reportEndCallWithUUID(uuid, CK_CONSTANTS.END_CALL_REASONS.FAILED);
        this.updateCallState('errored');
        this.activeCallUUID = null;
        this.notifyListeners();
      }
    }
  }

  async endCall() {
    if (!this.activeCallUUID) return;

    const uuid = this.activeCallUUID;
    if (Platform.OS === 'ios') {
      RNCallKeep.endCall(uuid);
    } else {
      IncomingCallUI?.hide(uuid);
    }
    await this.disconnectFromRoom();
    this.activeCallUUID = null;
    this.callerName = null;
    this.callerHandle = null;
    if (this.callState !== 'errored') {
      this.updateCallState('idle');
    }
    this.notifyListeners();
  }

  // --- Room control ---

  private async ensureAndroidCallPermissions() {
    if (Platform.OS !== 'android') return;
    const result = await PermissionsAndroid.requestMultiple([
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
      PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
      PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
    ]);
    const mic = result[PermissionsAndroid.PERMISSIONS.RECORD_AUDIO];
    if (mic !== PermissionsAndroid.RESULTS.GRANTED) {
      throw new Error('Microphone permission denied');
    }
  }

  private async disconnectFromRoom() {
    if (__DEV__) console.log('[CallManager] Disconnecting from room');
    await this.room.disconnect();
    if (Platform.OS === 'android') {
      AudioSession.stopAudioSession().catch(() => {});
    } else {
      // Deactivate audio engine; on the CallKit path didDeactivateAudioSession
      // would do this, but on the Realtime path we must do it explicitly.
      AudioDeviceModule.setEngineAvailability(AudioEngineAvailability.none)
        .catch(() => {});
    }
    this.notifyListeners();
  }

  // --- State management ---

  private updateCallState(state: CallState) {
    this.callState = state;
    this.notifyListeners();
  }

  subscribe(listener: CallManagerListener): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private notifyListeners() {
    this.listeners.forEach(listener => listener());
  }
}

export default CallManager;
