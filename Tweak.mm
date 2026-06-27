//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v7.0
//  Minimal: Auto-detect path & token only
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

// ========== 全局状态 ==========
static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static NSString *gCuid = nil;

// ========== 前向声明 ==========
static UIViewController * topViewController(void);
static NSString * getBdstoken(void);
static NSString * getBDUSS(void);
static NSString * getCuid(void);
static NSString * extractPathFromViewController(UIViewController *vc);
static NSString * getPathFromNavStack(void);
static void autoDetectPathAndToken(void);

// ========== 工具函数 ==========

static UIViewController * topViewController(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = scene.windows.firstObject;
                break;
            }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return nil;

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = [(UITabBarController *)vc selectedViewController];
        if ([selected isKindOfClass:[UINavigationController class]]) {
            vc = [(UINavigationController *)selected topViewController];
        } else {
            vc = selected;
        }
    }

    return vc;
}

// ========== 自动获取 Token ==========

static NSString * getBdstoken(void) {
    if (gBdstoken) return gBdstoken;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBdstoken = [defaults objectForKey:@"bdstoken"];
    if (gBdstoken) {
        DLog(@"✅ Got bdstoken from NSUserDefaults");
        return gBdstoken;
    }

    NSArray *keychainKeys = @[@"com.baidu.netdisk.bdstoken", @"bdstoken", @"token"];
    for (NSString *key in keychainKeys) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: key,
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
        };
        CFDataRef dataRef = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataRef);
        if (status == errSecSuccess && dataRef) {
            NSData *data = (__bridge_transfer NSData *)dataRef;
            NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (value && value.length > 0) {
                gBdstoken = value;
                DLog(@"✅ Got bdstoken from Keychain");
                return gBdstoken;
            }
        }
    }

    return nil;
}

static NSString * getBDUSS(void) {
    if (gBDUSS) return gBDUSS;

    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) {
            gBDUSS = cookie.value;
            DLog(@"✅ Got BDUSS from cookie");
            return gBDUSS;
        }
    }

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBDUSS = [defaults objectForKey:@"BDUSS"];
    if (gBDUSS) {
        DLog(@"✅ Got BDUSS from NSUserDefaults");
    }
    return gBDUSS;
}

static NSString * getCuid(void) {
    if (gCuid) return gCuid;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gCuid = [defaults objectForKey:@"cuid"];
    if (!gCuid) {
        gCuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    }
    return gCuid;
}

// ========== 自动获取当前路径 ==========

static NSString * extractPathFromViewController(UIViewController *vc) {
    if (!vc) return nil;

    NSString *path = nil;
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir"];
    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                path = value;
                DLog(@"✅ Found path from VC.%@ = %@", key, path);
                break;
            }
        } @catch (NSException *e) {}
    }
    return path;
}

static NSString * getPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

    if (nav) {
        NSArray *vcs = nav.viewControllers;
        NSMutableArray *pathComponents = [NSMutableArray array];

        for (UIViewController *controller in vcs) {
            NSString *component = extractPathFromViewController(controller);
            if (component && component.length > 0 && ![component isEqualToString:@"/"]) {
                [pathComponents addObject:component];
            }
        }

        if (pathComponents.count > 0) {
            NSString *fullPath = [pathComponents componentsJoinedByString:@"/"];
            if (![fullPath hasPrefix:@"/"]) {
                fullPath = [@"/" stringByAppendingString:fullPath];
            }
            return fullPath;
        }
    }

    return extractPathFromViewController(vc);
}

static void autoDetectPathAndToken(void) {
    DLog(@"🔍 Starting auto-detection...");

    NSString *bdstoken = getBdstoken();
    NSString *bduss = getBDUSS();
    NSString *cuid = getCuid();

    DLog(@"bdstoken: %@", bdstoken ? @"✅ Found" : @"❌ Not found");
    DLog(@"BDUSS: %@", bduss ? @"✅ Found" : @"❌ Not found");
    DLog(@"cuid: %@", cuid ? @"✅ Found" : @"❌ Not found");

    if (bdstoken) DLog(@"bdstoken value: %@", bdstoken);
    if (bduss) DLog(@"BDUSS value: %@", bduss);

    NSString *path = getPathFromNavStack();
    if (!path) {
        UIViewController *vc = topViewController();
        path = extractPathFromViewController(vc);
    }

    if (path) {
        gCurrentPath = path;
        DLog(@"✅ Auto-detected path: %@", path);
    } else {
        gCurrentPath = @"/";
        DLog(@"⚠️ Could not auto-detect path, using default: /");
    }
}

// ========== 对外接口 ==========

NSString * BDTGetCurrentPath(void) {
    return gCurrentPath ?: @"/";
}

NSString * BDTGetBdstoken(void) {
    return gBdstoken;
}

NSString * BDTGetBDUSS(void) {
    return gBDUSS;
}

NSString * BDTGetCuid(void) {
    return gCuid;
}

void BDTRefreshPathAndToken(void) {
    gCurrentPath = nil;
    gBdstoken = nil;
    gBDUSS = nil;
    gCuid = nil;
    autoDetectPathAndToken();
}

// ========== 初始化 ==========

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"🚀 BaiduPan SVIP Direct Link Helper v7.0 (Minimal) loaded");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoDetectPathAndToken();
    });
}
