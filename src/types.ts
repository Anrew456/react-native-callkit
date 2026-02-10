export type CallState =
  | 'idle'
  | 'errored'
  | 'activeIncoming'
  | 'activeOutgoing'
  | 'connected';

export interface CallManagerState {
  callState: CallState;
  voipToken: string | null;
  activeCallUUID: string | null;
  url: string;
  token: string;
}
