/**
 * @format
 */

// URL polyfill required by @supabase/supabase-js in React Native.
import 'react-native-url-polyfill/auto';

// LiveKit globals must be registered before any livekit-client imports.
import { registerGlobals } from '@livekit/react-native';
registerGlobals({ autoConfigureAudioSession: false });

// Bootstrap the CallManager singleton (sets up CallKeep + PushKit listeners).
import CallManager from './src/CallManager';
CallManager.shared;

// Register FCM background message handler BEFORE AppRegistry. This handler
// runs in a headless JS context when the app is killed; it must not import
// React or anything that depends on the UI thread.
import messaging from '@react-native-firebase/messaging';
import { handleFcmMessage } from './src/lib/pushRegistration';
messaging().setBackgroundMessageHandler(handleFcmMessage);

import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
