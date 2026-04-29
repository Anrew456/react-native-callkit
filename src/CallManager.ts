import { Room, ConnectionState } from 'livekit-client';
import {
  AudioDeviceModule,
  AudioEngineAvailability,
  AudioSession,
} from '@livekit/react-native';
import RNCallKeep, { CONSTANTS as CK_CONSTANTS } from '@livekit/react-native-callkeep';
import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import type { CallState } from './types';

const STORAGE_KEY_URL = '@callkit_url';
const STORAGE_KEY_TOKEN = '@callkit_token';

type CallManagerListener = () => void;

class CallManager {
  // State
  callState: CallState = 'idle';
  voipToken: string | null = null;
  activeCallUUID: string | null = null;
  callerName: string | null = null;
  callerHandle: string | null = null;
  url: string = '';
  token: string = '';

  // LiveKit
  readonly room = new Room();

  // Listeners for state changes
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
    // Set audio engine off until CallKit activates
    if (Platform.OS === 'ios') {
      try {
        await AudioDeviceModule.setEngineAvailability(
          AudioEngineAvailability.none,
        );
      } catch (e) {
        console.error('Failed to set engine availability:', e);
      }
    }

    // Setup CallKeep
    this.setupCallKeep();

    // Setup PushKit listener (native module events)
    this.setupPushKit();

    // Load persisted URL/token
    await this.loadPersistedValues();

    // Listen for room state changes
    this.room.on('connectionStateChanged', () => {
      this.notifyListeners();
    });
  }

  private setupCallKeep() {
    RNCallKeep.setSettings({
      ios: {
        appName: 'LiveKitCallKit',
        supportsVideo: false,
        maximumCallGroups: '1',
        maximumCallsPerCallGroup: '1',
        includesCallsInRecents: false,
        audioSession: {
          autoConfigure: false, // SDK's AudioDeviceModule owns the audio session
        },
      },
      android: {
        alertTitle: 'Permissions required',
        alertDescription:
          'This application needs to access your phone accounts',
        cancelButton: 'Cancel',
        okButton: 'Ok',
        additionalPermissions: [],
        foregroundService: {
          channelId: 'io.livekit.callkit',
          channelName: 'Foreground Service',
          notificationTitle: 'LiveKit CallKit Example is running',
        },
      },
    });

    // Audio session activation/deactivation coordination with the SDK's AudioEngine
    RNCallKeep.addEventListener('didActivateAudioSession', () => {
      console.log('[CallManager] Audio session activated');
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
            AudioDeviceModule.setEngineAvailability(
              AudioEngineAvailability.default,
            ),
          )
          .catch(e => console.error('Failed to configure audio session:', e));
      }
    });

    RNCallKeep.addEventListener('didDeactivateAudioSession', () => {
      console.log('[CallManager] Audio session deactivated');
      if (Platform.OS === 'ios') {
        AudioDeviceModule.setEngineAvailability(
          AudioEngineAvailability.none,
        ).catch(e => console.error('Failed to set engine availability:', e));
      }
    });

    // Answer incoming call
    RNCallKeep.addEventListener('answerCall', ({ callUUID }) => {
      console.log('[CallManager] Answer call:', callUUID);
      this.activeCallUUID = callUUID;
      this.connectToRoom()
        .then(() => {
          this.updateCallState('connected');
        })
        .catch(e => {
          console.error('Failed to connect to room:', e);
          this.updateCallState('errored');
        });
    });

    // End call
    RNCallKeep.addEventListener('endCall', ({ callUUID }) => {
      console.log('[CallManager] End call:', callUUID);
      this.disconnectFromRoom().then(() => {
        if (this.callState !== 'errored') {
          this.updateCallState('idle');
        }
        this.activeCallUUID = null;
        this.callerName = null;
        this.callerHandle = null;
        this.notifyListeners();
      });
    });

    // Start call action (from system)
    RNCallKeep.addEventListener(
      'didReceiveStartCallAction',
      ({ callUUID, handle }) => {
        console.log('[CallManager] Start call action:', callUUID, handle);
      },
    );

    // Mute action
    RNCallKeep.addEventListener(
      'didPerformSetMutedCallAction',
      ({ muted, callUUID }) => {
        console.log('[CallManager] Mute:', muted, callUUID);
        this.room.localParticipant
          ?.setMicrophoneEnabled(!muted)
          .catch(e => console.error('Failed to set microphone:', e));
      },
    );

    // Incoming call displayed
    RNCallKeep.addEventListener(
      'didDisplayIncomingCall',
      ({ error, callUUID, handle, localizedCallerName }) => {
        if (error) {
          console.error('[CallManager] Display incoming call error:', error);
          this.updateCallState('errored');
          return;
        }
        console.log('[CallManager] Incoming call displayed:', callUUID);
        this.activeCallUUID = callUUID;
        this.callerHandle = handle || null;
        this.callerName = localizedCallerName || null;
        this.updateCallState('activeIncoming');
      },
    );

    // Provider reset
    RNCallKeep.addEventListener('didResetProvider', () => {
      console.log('[CallManager] Provider reset');
      this.activeCallUUID = null;
      this.callerName = null;
      this.callerHandle = null;
      this.updateCallState('idle');
    });

    // Audio route changes
    RNCallKeep.addEventListener('didChangeAudioRoute', () => {});
  }

  private setupPushKit() {
    if (Platform.OS !== 'ios') {
      return;
    }

    const { PushKitManager } = NativeModules;
    if (!PushKitManager) {
      console.warn('[CallManager] PushKitManager native module not found');
      return;
    }

    const emitter = new NativeEventEmitter(PushKitManager);

    emitter.addListener('voipTokenUpdated', ({ token }: { token: string }) => {
      console.log('[CallManager] VoIP token updated:', token);
      this.voipToken = token;
      this.notifyListeners();
    });

    emitter.addListener('voipTokenInvalidated', () => {
      console.log('[CallManager] VoIP token invalidated');
      this.voipToken = null;
      this.notifyListeners();
    });
  }

  private async loadPersistedValues() {
    try {
      const [url, token] = await Promise.all([
        AsyncStorage.getItem(STORAGE_KEY_URL),
        AsyncStorage.getItem(STORAGE_KEY_TOKEN),
      ]);
      if (url) this.url = url;
      if (token) this.token = token;
      this.notifyListeners();
    } catch (e) {
      console.error('Failed to load persisted values:', e);
    }
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

  async setUrl(url: string) {
    this.url = url;
    await AsyncStorage.setItem(STORAGE_KEY_URL, url);
    this.notifyListeners();
  }

  async setToken(token: string) {
    this.token = token;
    await AsyncStorage.setItem(STORAGE_KEY_TOKEN, token);
    this.notifyListeners();
  }

  async startCall(handle: string) {
    const uuid = generateUUID();
    this.activeCallUUID = uuid;
    this.updateCallState('activeOutgoing');

    RNCallKeep.startCall(uuid, handle, 'LiveKit Call', 'generic', false);
    RNCallKeep.reportConnectingOutgoingCallWithUUID(uuid);

    try {
      await this.connectToRoom();
      RNCallKeep.reportConnectedOutgoingCallWithUUID(uuid);
      this.updateCallState('connected');
    } catch (e) {
      console.error('Failed to start call:', e);
      RNCallKeep.reportEndCallWithUUID(
        uuid,
        CK_CONSTANTS.END_CALL_REASONS.FAILED,
      );
      this.updateCallState('errored');
      this.activeCallUUID = null;
      this.notifyListeners();
    }
  }

  async endCall() {
    if (!this.activeCallUUID) return;

    const uuid = this.activeCallUUID;
    RNCallKeep.endCall(uuid);
    await this.disconnectFromRoom();
    this.activeCallUUID = null;
    this.callerName = null;
    this.callerHandle = null;
    if (this.callState !== 'errored') {
      this.updateCallState('idle');
    }
    this.notifyListeners();
  }

  simulateIncomingCall(callerName: string) {
    const uuid = generateUUID();
    RNCallKeep.displayIncomingCall(
      uuid,
      'incoming-user',
      callerName,
      'generic',
      false,
    );
  }

  // --- Room control ---

  private async connectToRoom() {
    console.log('[CallManager] Connecting to room:', this.url);
    await this.room.connect(this.url, this.token);
    await this.room.localParticipant.setMicrophoneEnabled(true);
    console.log('[CallManager] Connected to room');
    this.notifyListeners();
  }

  private async disconnectFromRoom() {
    console.log('[CallManager] Disconnecting from room');
    await this.room.disconnect();
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

function generateUUID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export default CallManager;
