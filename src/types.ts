export type CallState =
  | 'idle'
  | 'errored'
  | 'activeIncoming'
  | 'activeOutgoing'
  | 'connected';

export type HandoffStatus =
  | 'pending'
  | 'claimed'
  | 'in_progress'
  | 'timeout'
  | 'caller_abandoned'
  | 'completed'
  | 'completed_by_agent_resume'
  | 'rejected';

export interface HandoffRequest {
  id: number;
  pizzeria_id: number;
  room_name: string;
  caller_number: string;
  partial_order_id: number | null;
  status: HandoffStatus;
  claimed_by: string | null;
  rejected_by: string | null;
  created_at: string;
  expires_at: string;
  claimed_at: string | null;
  rejected_at: string | null;
  completed_at: string | null;
}

export interface ClaimResponse {
  token: string;
  livekit_url: string;
  room_name: string;
  partial_order_id: number | null;
  caller_number: string;
}
