#import "PushKitManager.h"
#import <RNCallKeep/RNCallKeep.h>
#import <AVFoundation/AVFoundation.h>

@implementation PushKitManager {
  PKPushRegistry *_pushRegistry;
  bool _hasListeners;
}

RCT_EXPORT_MODULE();

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _pushRegistry = [[PKPushRegistry alloc] initWithQueue:dispatch_get_main_queue()];
    _pushRegistry.delegate = self;
    _pushRegistry.desiredPushTypes = [NSSet setWithObject:PKPushTypeVoIP];
  }
  return self;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[@"voipTokenUpdated", @"voipTokenInvalidated"];
}

- (void)startObserving {
  _hasListeners = YES;
}

- (void)stopObserving {
  _hasListeners = NO;
}

#pragma mark - PKPushRegistryDelegate

- (void)pushRegistry:(PKPushRegistry *)registry
    didUpdatePushCredentials:(PKPushCredentials *)pushCredentials
                     forType:(PKPushType)type {
  if (![type isEqualToString:PKPushTypeVoIP]) return;

  NSMutableString *token = [NSMutableString string];
  const unsigned char *bytes = pushCredentials.token.bytes;
  for (NSUInteger i = 0; i < pushCredentials.token.length; i++) {
    [token appendFormat:@"%02x", bytes[i]];
  }

  NSLog(@"[PushKitManager] VoIP token: %@", token);

  if (_hasListeners) {
    [self sendEventWithName:@"voipTokenUpdated" body:@{@"token": token}];
  }
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didInvalidatePushTokenForType:(PKPushType)type {
  if (![type isEqualToString:PKPushTypeVoIP]) return;

  NSLog(@"[PushKitManager] VoIP token invalidated");

  if (_hasListeners) {
    [self sendEventWithName:@"voipTokenInvalidated" body:@{}];
  }
}

- (void)pushRegistry:(PKPushRegistry *)registry
    didReceiveIncomingPushWithPayload:(PKPushPayload *)payload
                              forType:(PKPushType)type
                withCompletionHandler:(void (^)(void))completion {
  if (![type isEqualToString:PKPushTypeVoIP]) {
    completion();
    return;
  }

  NSLog(@"[PushKitManager] Received VoIP push: %@", payload.dictionaryPayload);

  // IMPORTANT: Set audio category before reporting incoming call.
  // This is required for the microphone to initialize correctly.
  NSError *error = nil;
  [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord
                                          mode:AVAudioSessionModeVoiceChat
                                       options:AVAudioSessionCategoryOptionMixWithOthers
                                         error:&error];
  if (error) {
    NSLog(@"[PushKitManager] Failed to configure AVAudioSession: %@", error);
  }

  NSString *callerId = payload.dictionaryPayload[@"callerId"];
  if (!callerId) {
    callerId = [[NSUUID UUID] UUIDString];
  }

  NSString *callerName = payload.dictionaryPayload[@"callerName"];
  if (!callerName) {
    callerName = @"Unknown Caller";
  }

  NSString *uuid = [[NSUUID UUID] UUIDString];

  // CRITICAL: Must call reportNewIncomingCall synchronously on the same
  // thread as the push callback to ensure the call UI appears on the lock screen.
  [RNCallKeep reportNewIncomingCall:uuid
                             handle:callerId
                         handleType:@"generic"
                           hasVideo:NO
                localizedCallerName:callerName
                    supportsHolding:NO
                       supportsDTMF:NO
                   supportsGrouping:NO
                 supportsUngrouping:NO
                        fromPushKit:YES
                            payload:payload.dictionaryPayload
              withCompletionHandler:completion];
}

@end
