#import <React/RCTEventEmitter.h>
#import <React/RCTBridgeModule.h>
#import <PushKit/PushKit.h>

@interface PushKitManager : RCTEventEmitter <RCTBridgeModule, PKPushRegistryDelegate>
@end
