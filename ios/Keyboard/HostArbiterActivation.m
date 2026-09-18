// HostArbiterActivation.m
// Adapted from dictus-ios (MIT License, Copyright (c) 2026 PIVI Solutions),
// DictusKeyboard/HostArbiterActivation.m — see THIRD_PARTY_NOTICES.md.
//
// 為什麼是 Objective-C、為什麼在 main 之前跑：
// `+[_UIKeyboardArbiterClient enabled]` 回 YES 之前，arbiter 不會記錄宿主 app；
// UIKit 很早就決定要不要建立 arbiter client，等到 viewWillAppear 才換就來不及（Dictus 真機實測）。
// __attribute__((constructor)) 是 extension 裡最早能跑程式的時機。
//
// 這段在 extension 一切初始化之前執行：當掉＝鍵盤永遠出不來。所以每一步都判空、
// 以類別名稱動態取得（不連結私有符號）、不做 I/O、不 log（logger 還沒初始化）。
#import "HostArbiterActivation.h"
#import <objc/runtime.h>

static NSString *const kArbiterClassUnderscored = @"_UIKeyboardArbiterClient";
static NSString *const kArbiterClassPlain = @"UIKeyboardArbiterClient";
static NSString *const kEnabledSelector = @"enabled";

static BOOL gInstalled = NO;
static NSString *gLoadTimeOutcome = @"not-attempted";

static Class UTUVOResolveArbiterClass(void) {
    Class cls = NSClassFromString(kArbiterClassUnderscored);
    if (cls == Nil) { cls = NSClassFromString(kArbiterClassPlain); }
    return cls;
}

static NSString *UTUVOInstallArbiterSwizzle(void) {
    if (gInstalled) { return @"already"; }
    Class cls = UTUVOResolveArbiterClass();
    if (cls == Nil) { return @"no-class"; }
    // +enabled 是 class method：實作在 metaclass 上。
    Method method = class_getClassMethod(cls, NSSelectorFromString(kEnabledSelector));
    if (method == NULL) { return @"no-method"; }
    IMP replacement = imp_implementationWithBlock(^BOOL(id _self) { return YES; });
    method_setImplementation(method, replacement);
    gInstalled = YES;
    return @"installed";
}

__attribute__((constructor))
static void UTUVOActivateArbiterAtLoad(void) {
    gLoadTimeOutcome = UTUVOInstallArbiterSwizzle();
}

@implementation UTUVOHostArbiterActivation
+ (NSString *)activate { return UTUVOInstallArbiterSwizzle(); }
+ (NSString *)loadTimeOutcome { return gLoadTimeOutcome; }
+ (BOOL)isInstalled { return gInstalled; }
@end
