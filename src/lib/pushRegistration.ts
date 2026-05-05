import { AppState, NativeEventEmitter, NativeModules, PermissionsAndroid, Platform } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import messaging, { type FirebaseMessagingTypes } from '@react-native-firebase/messaging';
import RNCallKeep from '@livekit/react-native-callkeep';
import { supabase } from './supabase';
import { claimHandoff, rejectHandoff } from './edgeFunctions';
import { navigateToInCall, navigateBack } from './navigation';
import type { HandoffRequest } from '../types';

// Payload received via FCM data message (Android) or VoIP push (iOS, future).
// caller_number_masked is the only phone field in the push — the full number
// is returned by claim_handoff to avoid leaking PII through push logs.
interface IncomingCallPayload {
  request_id: number;
  caller_number_masked?: string;
  pizzeria_id?: number;
  partial_order_id?: number | null;
  expires_at?: string;
}

// callUUID → payload (in-memory; also persisted to AsyncStorage for killed→relaunch)
const pendingByUuid = new Map<string, IncomingCallPayload>();
const inCallUuids = new Set<string>();

let voipListenersBound = false;
let fcmListenersBound = false;
let callkeepListenersBound = false;
let androidIncomingListenersBound = false;
let registeredUserId: string | null = null;

const IncomingCallUI = NativeModules.IncomingCallUI as
  | { show: (uuid: string, name: string, handle: string | null) => void; hide: (uuid: string) => void }
  | undefined;

// Single entry point. Called from RootNavigator when the user authenticates.
export async function setupPush(userId: string) {
  registeredUserId = userId;

  if (Platform.OS === 'ios') {
    setupVoipPushIos(userId);
    bindCallKeepListeners(); // CallKit answer/decline (foreground + future VoIP push)
    return;
  }

  if (Platform.OS === 'android') {
    await requestAndroidPermissions();
    await setupFcmAndroid(userId);
    bindAndroidIncomingListeners(); // custom notification action receiver
  }
}

export function teardownPushOnLogout() {
  registeredUserId = null;
  pendingByUuid.clear();
  inCallUuids.clear();
}

// ---------- iOS PushKit (future — requires APNs VoIP certificate) -----------

function setupVoipPushIos(_userId: string) {
  // Phase 2: wiring react-native-voip-push-notification here.
  // For now iOS relies on Supabase Realtime (foreground only).
  if (!voipListenersBound) {
    voipListenersBound = true;
  }
}

// ---------- Android FCM -----------------------------------------------------

async function setupFcmAndroid(userId: string) {
  await messaging().registerDeviceForRemoteMessages();
  const token = await messaging().getToken();
  await upsertAndroidDevice(userId, token);

  if (!fcmListenersBound) {
    messaging().onTokenRefresh((newToken) => {
      const uid = registeredUserId;
      if (uid) upsertAndroidDevice(uid, newToken);
    });
    // Foreground FCM messages
    messaging().onMessage(handleFcmMessage);
    fcmListenersBound = true;
  }
}

async function upsertAndroidDevice(userId: string, token: string) {
  const { error } = await supabase.from('operator_devices').upsert(
    {
      user_id: userId,
      platform: 'android',
      push_token: token,
      updated_at: new Date().toISOString(),
    },
    { onConflict: 'platform,push_token' },
  );
  if (error && __DEV__) console.warn('operator_devices upsert failed', error);
}

// Exported so index.js can register it as the background message handler at
// module load time. Must NOT live inside a React component.
export async function handleFcmMessage(msg: FirebaseMessagingTypes.RemoteMessage) {
  const data = msg.data;
  if (!data?.request_id) return;
  const requestId = Number(data.request_id);
  if (!Number.isInteger(requestId) || requestId <= 0) return;

  if (data.expires_at && typeof data.expires_at === 'string') {
    const t = Date.parse(data.expires_at);
    if (!Number.isNaN(t) && t <= Date.now()) return;
  }

  handleIncomingCallPayload({
    request_id: requestId,
    caller_number_masked:
      typeof data.caller_number_masked === 'string' ? data.caller_number_masked : undefined,
    pizzeria_id:
      data.pizzeria_id != null ? Number(data.pizzeria_id) : undefined,
    partial_order_id:
      data.partial_order_id != null ? Number(data.partial_order_id) : undefined,
    expires_at:
      typeof data.expires_at === 'string' ? data.expires_at : undefined,
  });
}

// ---------- Shared incoming-call display ------------------------------------

// Exported for WaitingScreen debug button and iOS PushKit handler.
export function handleIncomingCallPayload(payload: IncomingCallPayload) {
  if (!payload?.request_id) return;
  const callUuid = crypto.randomUUID();
  pendingByUuid.set(callUuid, payload);
  AsyncStorage.setItem(`pending_call_${callUuid}`, JSON.stringify(payload)).catch(() => {});

  const callerLabel = payload.caller_number_masked ?? 'Sconosciuto';

  if (Platform.OS === 'android') {
    // Custom notification UI (bypasses Android Telecom / VoiceConnectionService)
    IncomingCallUI?.show(callUuid, callerLabel, null);
  } else {
    // iOS: show native CallKit incoming-call screen
    RNCallKeep.displayIncomingCall(callUuid, callerLabel, 'Talky', 'number', false);
  }
}

// Called by InCallScreen when LiveKit disconnects.
export function endCallKeepSession(callUUID: string | undefined) {
  if (!callUUID) return;
  if (inCallUuids.has(callUUID)) {
    if (Platform.OS === 'ios') RNCallKeep.endCall(callUUID);
    else IncomingCallUI?.hide(callUUID);
    inCallUuids.delete(callUUID);
  }
}

// ---------- Android: custom IncomingCallAction receiver ---------------------

function bindAndroidIncomingListeners() {
  if (androidIncomingListenersBound) return;
  if (!NativeModules.IncomingCallUI) return;
  androidIncomingListenersBound = true;

  const emitter = new NativeEventEmitter(NativeModules.IncomingCallUI);
  emitter.addListener(
    'IncomingCallAction',
    async ({ action, callUUID }: { action: 'answer' | 'decline'; callUUID: string }) => {
      if (__DEV__) console.log('[pushRegistration] IncomingCallAction:', action, callUUID);
      IncomingCallUI?.hide(callUUID);

      if (action === 'answer') {
        await handleAnswer(callUUID);
      } else {
        await handleDecline(callUUID);
      }
    },
  );
}

// ---------- iOS: CallKit answer / decline via RNCallKeep -------------------

function bindCallKeepListeners() {
  if (callkeepListenersBound) return;
  callkeepListenersBound = true;

  RNCallKeep.addEventListener('answerCall', async ({ callUUID }) => {
    await handleAnswer(callUUID);
  });

  RNCallKeep.addEventListener('endCall', async ({ callUUID }) => {
    const wasActive = inCallUuids.has(callUUID);
    await handleDecline(callUUID);
    if (wasActive) {
      // System call UI ended an active call — navigate back from InCallScreen.
      navigateBack();
    }
  });
}

// ---------- Shared answer / decline logic -----------------------------------

async function handleAnswer(callUUID: string) {
  let entry = pendingByUuid.get(callUUID);
  if (!entry) {
    const stored = await AsyncStorage.getItem(`pending_call_${callUUID}`).catch(() => null);
    if (!stored) return;
    try { entry = JSON.parse(stored) as IncomingCallPayload; }
    catch { return; }
  }
  pendingByUuid.delete(callUUID);
  AsyncStorage.removeItem(`pending_call_${callUUID}`).catch(() => {});

  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return;

  const res = await claimHandoff(entry.request_id, session);
  if (!res.ok) {
    if (__DEV__) console.warn('claim_handoff failed during answer', res.error);
    return;
  }

  inCallUuids.add(callUUID);

  if (Platform.OS === 'ios') {
    RNCallKeep.setCurrentCallActive(callUUID);
  }

  // When answering from notification while app is backgrounded, wait for the
  // activity to come to foreground before mounting InCallScreen.
  if (Platform.OS === 'android' && AppState.currentState !== 'active') {
    await new Promise<void>((resolve) => {
      const sub = AppState.addEventListener('change', (state) => {
        if (state === 'active') { sub.remove(); resolve(); }
      });
      setTimeout(() => { try { sub.remove(); } catch {} resolve(); }, 5000);
    });
  }

  const request: HandoffRequest = {
    id: entry.request_id,
    pizzeria_id: entry.pizzeria_id ?? 0,
    room_name: res.data.room_name,
    caller_number: res.data.caller_number,
    partial_order_id: entry.partial_order_id ?? res.data.partial_order_id,
    status: 'claimed',
    claimed_by: session.user.id,
    rejected_by: null,
    created_at: new Date().toISOString(),
    expires_at: entry.expires_at ?? new Date(Date.now() + 60_000).toISOString(),
    claimed_at: new Date().toISOString(),
    rejected_at: null,
    completed_at: null,
  };
  navigateToInCall({ request, claim: res.data, callUUID });
}

async function handleDecline(callUUID: string) {
  let entry = pendingByUuid.get(callUUID);
  if (!entry) {
    const stored = await AsyncStorage.getItem(`pending_call_${callUUID}`).catch(() => null);
    if (stored) {
      try { entry = JSON.parse(stored) as IncomingCallPayload; } catch { /* ignore */ }
    }
  }
  if (entry) {
    pendingByUuid.delete(callUUID);
    AsyncStorage.removeItem(`pending_call_${callUUID}`).catch(() => {});
    const { data: { session } } = await supabase.auth.getSession();
    if (session) {
      const res = await rejectHandoff(entry.request_id, session);
      if (!res.ok && __DEV__) console.warn('reject_handoff after decline failed', res.error);
    }
  }
  inCallUuids.delete(callUUID);
}

async function requestAndroidPermissions() {
  await PermissionsAndroid.requestMultiple([
    PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
    PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
  ]);
}
