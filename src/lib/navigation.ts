import { createNavigationContainerRef } from '@react-navigation/native';
import type { RootStackParamList } from '../navigation/RootNavigator';

export const navigationRef = createNavigationContainerRef<RootStackParamList>();

export function navigateToInCall(params: RootStackParamList['InCall']) {
  if (!navigationRef.isReady()) return;
  navigationRef.navigate('InCall', params);
}

export function navigateBack() {
  if (!navigationRef.isReady()) return;
  if (navigationRef.canGoBack()) navigationRef.goBack();
}
