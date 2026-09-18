// HostArbiterActivation.h
// Adapted from dictus-ios (MIT License, Copyright (c) 2026 PIVI Solutions),
// DictusKeyboard/HostArbiterActivation.h — see THIRD_PARTY_NOTICES.md.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 讓 UIKit 的鍵盤 arbiter 開始回報「鍵盤正在服務哪個 app」。
/// 真正的安裝在載入期的 constructor（比 main 還早）；這裡是重試與回報。
@interface UTUVOHostArbiterActivation : NSObject
/// 回傳 installed／already／no-class／no-method。失敗不會被記住，下次會再試。
+ (NSString *)activate;
/// 載入期 constructor 的結果。
+ (NSString *)loadTimeOutcome;
+ (BOOL)isInstalled;
@end

NS_ASSUME_NONNULL_END
