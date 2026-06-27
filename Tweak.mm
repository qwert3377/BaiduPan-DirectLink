//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v7.2
//  Improved: Better path & token detection
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

// ========== 全局状态 ==========
static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// ========== 前向声明 ==========
static UIViewController * topViewController(void);
static void showFloatButton(void);
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

// ========== 扫描内存中的 bdstoken ==========

static NSString * scanMemoryForBdstoken(void) {
    // 尝试从 NSUserDefaults 的所有键值中扫描
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];

    for (NSString *key in allDefaults) {
        id value = allDefaults[key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            // bdstoken 通常是 32 位十六进制字符串
            if (str.length == 32 && [str rangeOfString:@"bdstoken"].location == NSNotFound) {
                NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[a-f0-9]{32}$" options:0 error:nil];
                if ([regex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                    DLog(@"🔍 Found potential bdstoken in key: %@", key);
                    return str;
                }
            }
        }
    }
    return nil;
}

// ========== 从 ViewController 层级获取路径 ==========

static NSString * extractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;

    // 尝试各种可能的属性名
    NSArray *pathKeys = @[
        @"path", @"currentPath", @"filePath", @"dirPath", 
        @"currentDir", @"_path", @"_currentPath",
        @"directory", @"folderPath", @"currentFolder"
    ];

    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                DLog(@"✅ Found path from VC.%@ = %@", key, value);
                return value;
            }
        } @catch (NSException *e) {}
    }

    // 尝试从 title 重建路径（百度网盘通常用文件夹名做 title）
    if (vc.title && vc.title.length > 0 && ![vc.title isEqualToString:@"百度网盘"]) {
        DLog(@"ℹ️ VC title: %@", vc.title);
    }

    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

    if (!nav) return extractPathFromVC(vc);

    NSArray *vcs = nav.viewControllers;
    NSMutableArray *components = [NSMutableArray array];

    for (UIViewController *controller in vcs) {
        NSString *path = extractPathFromVC(controller);
        if (path && path.length > 0 && ![path isEqualToString:@"/"]) {
            [components addObject:path];
        } else if (controller.title && controller.title.length > 0 
                   && ![controller.title isEqualToString:@"百度网盘"]
                   && ![controller.title isEqualToString:@"文件"]) {
            // 用 title 作为路径组件
            [components addObject:controller.title];
        }
    }

    if (components.count == 0) return nil;

    NSString *fullPath = [components componentsJoinedByString:@"/"];
    if (![fullPath hasPrefix:@"/"]) {
        fullPath = [@"/" stringByAppendingString:fullPath];
    }
    return fullPath;
}

// ========== 自动获取 Token ==========

static void autoDetectPathAndToken(void) {
    DLog(@"🔍 Starting auto-detection...");

    // 1. 获取 bdstoken - 多种方式
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBdstoken = [defaults objectForKey:@"bdstoken"];
    if (!gBdstoken) gBdstoken = [defaults objectForKey:@"BDSTOKEN"];
    if (!gBdstoken) gBdstoken = [defaults objectForKey:@"token"];
    if (!gBdstoken) gBdstoken = scanMemoryForBdstoken();

    if (gBdstoken) {
        DLog(@"✅ Got bdstoken: %@...", [gBdstoken substringToIndex:MIN(8, gBdstoken.length)]);
    } else {
        DLog(@"❌ bdstoken not found");
    }

    // 2. 获取 BDUSS
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) {
            gBDUSS = cookie.value;
            DLog(@"✅ Got BDUSS from cookie");
            break;
        }
    }
    if (!gBDUSS) {
        gBDUSS = [defaults objectForKey:@"BDUSS"];
        if (gBDUSS) DLog(@"✅ Got BDUSS from NSUserDefaults");
    }

    // 3. 获取路径
    gCurrentPath = buildPathFromNavStack();
    if (!gCurrentPath) {
        // 尝试从当前 VC 直接获取
        UIViewController *vc = topViewController();
        gCurrentPath = extractPathFromVC(vc);
    }
    if (!gCurrentPath) gCurrentPath = @"/";

    DLog(@"📊 Path: %@ | Token: %@ | BDUSS: %@", 
         gCurrentPath, 
         gBdstoken ? @"✅" : @"❌", 
         gBDUSS ? @"✅" : @"❌");
}

// ========== 浮游按钮 ==========

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();

    NSString *msg = [NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@",
                       gCurrentPath,
                       gBdstoken ? [gBdstoken substringToIndex:MIN(16, gBdstoken.length)] : @"❌",
                       gBDUSS ? @"✅" : @"❌"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void showFloatButton(void) {
    if (gFloatButton) return;

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
    if (!window) return;

    CGFloat size = 50;
    CGFloat x = [UIScreen mainScreen].bounds.size.width - size - 20;
    CGFloat y = [UIScreen mainScreen].bounds.size.height / 2;

    gFloatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    gFloatButton.frame = CGRectMake(x, y, size, size);
    gFloatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.8];
    gFloatButton.layer.cornerRadius = size / 2;
    gFloatButton.layer.masksToBounds = YES;
    [gFloatButton setTitle:@"🚀" forState:UIControlStateNormal];
    [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont systemFontOfSize:24];

    [gFloatButton addTarget:nil action:@selector(bdt_floatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(bdt_floatButtonPanned:)];
    [gFloatButton addGestureRecognizer:pan];

    [window addSubview:gFloatButton];
    DLog(@"✅ Float button shown");
}

@interface NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender;
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture;
@end

@implementation NSObject (BaiduPanTroll)

- (void)bdt_floatButtonTapped:(id)sender {
    onFloatButtonTap();
}

- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}

@end

// ========== 初始化 ==========

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"🚀 BaiduPan Troll v7.2 loaded");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
