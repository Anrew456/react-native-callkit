import 'react-native-url-polyfill/auto';
import { createClient } from '@supabase/supabase-js';
import * as Keychain from 'react-native-keychain';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config';

// Persist Supabase auth tokens in the platform secure store (Keychain on iOS,
// Android Keystore via EncryptedSharedPreferences). Compared to AsyncStorage,
// which writes the JWT in plaintext, this prevents token extraction via
// adb backup or physical access on unencrypted Android devices.
//
// react-native-keychain stores a single service→credential object.
// We use a fixed service name per key so the auth-token JSON and the
// refresh-token string each get their own entry.
const SERVICE_PREFIX = 'supabase_auth';

const KeychainAdapter = {
  async getItem(key: string): Promise<string | null> {
    try {
      const result = await Keychain.getGenericPassword({ service: `${SERVICE_PREFIX}_${key}` });
      return result ? result.password : null;
    } catch {
      return null;
    }
  },
  async setItem(key: string, value: string): Promise<void> {
    try {
      await Keychain.setGenericPassword('supabase', value, {
        service: `${SERVICE_PREFIX}_${key}`,
        accessible: Keychain.ACCESSIBLE.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
      });
    } catch {}
  },
  async removeItem(key: string): Promise<void> {
    try {
      await Keychain.resetGenericPassword({ service: `${SERVICE_PREFIX}_${key}` });
    } catch {}
  },
};

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    storage: KeychainAdapter,
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
});
