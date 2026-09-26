// HostArbiterActivation.h
// Compatibility declarations retained for the generated Xcode project.
// The App Store implementation is intentionally public-API-only.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Public API-only compatibility status. No host app inspection is performed.
@interface UTUVOHostArbiterActivation : NSObject
/// 回傳 disabled-public-api-only。
+ (NSString *)activate;
/// 回傳 disabled-public-api-only。
+ (NSString *)loadTimeOutcome;
+ (BOOL)isInstalled;
@end

NS_ASSUME_NONNULL_END
