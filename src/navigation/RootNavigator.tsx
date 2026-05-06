import { useEffect, useState } from 'react';
import { ActivityIndicator, NativeModules, Platform, StyleSheet, Text, View } from 'react-native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import type { Session } from '@supabase/supabase-js';
import { supabase } from '../lib/supabase';
import { SessionProvider } from '../lib/session';
import { setupPush, teardownPushOnLogout } from '../lib/pushRegistration';
import { LoginScreen } from '../screens/LoginScreen';
import { WaitingScreen } from '../screens/WaitingScreen';
import { InCallScreen } from '../screens/InCallScreen';
import type { ClaimResponse, HandoffRequest } from '../types';

export type RootStackParamList = {
  Waiting: undefined;
  InCall: { request: HandoffRequest; claim: ClaimResponse; callUUID?: string };
};

const Stack = createNativeStackNavigator<RootStackParamList>();

export function RootNavigator() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (session) {
      // Persist JWT so the native Android decline handler can call reject_handoff
      // without opening the app.
      if (Platform.OS === 'android') {
        (NativeModules.IncomingCallUI as { saveAuthToken?: (t: string) => void } | undefined)
          ?.saveAuthToken?.(session.access_token);
      }
      setupPush(session.user.id).catch((err) => {
        if (__DEV__) console.warn('setupPush failed', err);
      });
    } else {
      teardownPushOnLogout();
    }
  }, [session]);

  if (!authReady) {
    return (
      <View style={styles.loading}>
        <ActivityIndicator />
        <Text style={styles.loadingText}>Caricamento...</Text>
      </View>
    );
  }

  if (!session) {
    return <LoginScreen />;
  }

  return (
    <SessionProvider session={session}>
      <Stack.Navigator initialRouteName="Waiting">
        <Stack.Screen
          name="Waiting"
          component={WaitingScreen}
          options={{ title: 'Talky Operator' }}
        />
        <Stack.Screen
          name="InCall"
          component={InCallScreen}
          options={{ title: 'In chiamata' }}
        />
      </Stack.Navigator>
    </SessionProvider>
  );
}

const styles = StyleSheet.create({
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: '#f5f5f7',
  },
  loadingText: { marginTop: 12, color: '#666' },
});
