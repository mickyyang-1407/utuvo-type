// KeyboardLanguageBootstrap.m
// 鍵盤 process 載入時、任何字串查詢之前，依 UTUVO 的設定寫好鍵盤自己的 AppleLanguages
// （邏輯在 Shared/KeyboardUILanguage.swift）。Bundle 第一次查字串就會快取語言，晚了就換不掉。
#import <Foundation/Foundation.h>

__attribute__((constructor)) static void UTUVOKeyboardApplyInterfaceLanguage(void) {
    @autoreleasepool {
        Class loader = NSClassFromString(@"UTUVOKeyboardUILanguageLoader");
        SEL selector = NSSelectorFromString(@"applyAtLaunch");
        if ([loader respondsToSelector:selector]) {
            ((void (*)(id, SEL))[loader methodForSelector:selector])(loader, selector);
        }
    }
}
