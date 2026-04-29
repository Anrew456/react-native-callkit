# LiveKit React-Native CallKit Example

React Native example showing CallKit (iOS) and ConnectionService (Android) integration with LiveKit using [@livekit/react-native-callkeep](https://github.com/livekit/react-native-callkeep).

## What it does

- Outgoing calls via `RNCallKeep.startCall`
- Simulated incoming calls via `RNCallKeep.displayIncomingCall`
- VoIP push token display (PushKit, iOS only)
- Audio session managed by LiveKit's `AudioDeviceModule`, not by CallKeep (`autoConfigure: false`)
- Mute/unmute via CallKit UI

## Project structure

```
index.js              registerGlobals, CallManager bootstrap
App.tsx               Navigation shell
src/
  CallManager.ts      Singleton: CallKeep setup, LiveKit room, PushKit listeners
  types.ts            CallState type
  screens/
    HomeScreen.tsx    UI: state display, URL/token input, call controls
ios/
  LiveKitCallKitExample/
    AppDelegate.swift
    PushKitManager.{h,m}    Native module for VoIP push tokens
    LiveKitCallKitExample.entitlements
```

## Prerequisites

- Node >= 20
- Xcode (iOS)
- Android Studio (Android)
- [React Native environment setup](https://reactnative.dev/docs/set-up-your-environment)

## Setup

```sh
npm install
```

### iOS

```sh
bundle install
cd ios && bundle exec pod install && cd ..
```

Open `ios/LiveKitCallKitExample.xcworkspace` in Xcode. You will need to set a development team and enable the following capabilities:

- **Background Modes**: Voice over IP, Remote notifications
- **Push Notifications**

Then run:

```sh
npm run ios
```

> CallKit's native call UI is unavailable in the iOS Simulator. The app builds and Room connections work, but to test incoming/outgoing call flows you need a physical device.

### Android

```sh
npm run android
```

## Usage

1. Enter a LiveKit server URL and access token.
2. **Start call** initiates an outgoing call and connects to the room.
3. **Simulate incoming call** shows the native call UI without a real push.
4. Use the native call UI to end or mute the call.

## Audio session handling

CallKeep is configured with `autoConfigure: false` so it does not touch `AVAudioSession`. Instead, when CallKit activates the audio session, the app configures it via `AudioSession.setAppleAudioConfiguration` and then enables the audio engine with `AudioDeviceModule.setEngineAvailability`. This matches the pattern from the [Swift CallKit example](https://github.com/livekit/client-sdk-swift/tree/main/Examples/CallKit).
