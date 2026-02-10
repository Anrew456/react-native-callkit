/**
 * @format
 */

// Must be registered before any livekit-client imports.
import { registerGlobals } from '@livekit/react-native';
registerGlobals({ autoConfigureAudioSession: false });
import CallManager from './src/CallManager';
CallManager.shared;

import { AppRegistry } from 'react-native';
import App from './App';
import { name as appName } from './app.json';

AppRegistry.registerComponent(appName, () => App);
