const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');

const livekitRoot = path.resolve(__dirname, '../../livekit');
const appNodeModules = path.resolve(__dirname, 'node_modules');

/**
 * Metro configuration
 * https://reactnative.dev/docs/metro
 *
 * @type {import('@react-native/metro-config').MetroConfig}
 */
const config = {
  watchFolders: [
    path.resolve(livekitRoot, 'client-sdk-react-native'),
    path.resolve(livekitRoot, 'react-native-webrtc'),
    path.resolve(livekitRoot, 'client-sdk-js'),
    path.resolve(livekitRoot, 'react-native-callkeep'),
  ],
  resolver: {
    // Local LiveKit SDK checkouts rely on Metro's legacy package fields
    // (`react-native`, `source`, `main`) instead of package `exports`.
    unstable_enablePackageExports: false,
    // When Metro processes files from linked packages (e.g. SDK's src/index.tsx),
    // it needs to know where to find their dependencies. This maps all shared
    // dependencies to this app's node_modules so resolution works correctly.
    extraNodeModules: {
      '@livekit/react-native-webrtc': path.resolve(
        livekitRoot,
        'react-native-webrtc',
      ),
      '@livekit/react-native': path.resolve(
        livekitRoot,
        'client-sdk-react-native',
      ),
      'livekit-client': path.resolve(livekitRoot, 'client-sdk-js'),
      'react-native-callkeep': path.resolve(
        livekitRoot,
        'react-native-callkeep',
      ),
      // Ensure shared dependencies resolve to a single copy
      react: path.resolve(appNodeModules, 'react'),
      'react-native': path.resolve(appNodeModules, 'react-native'),
      'react-native-url-polyfill': path.resolve(
        appNodeModules,
        'react-native-url-polyfill',
      ),
    },
    // Also check the app's node_modules for any dependency not found locally
    nodeModulesPaths: [appNodeModules],
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
