//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v7.1
//  With floating button + auto-detect path & token
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

// ========== 自动获取 Token ==========

static void autoDetectPathAndToken(void) {
    DLog(@"🔍 Starting auto-detection...");

    // 获取 bdstoken
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBdstoken = [defaults objectForKey:@"bdstoken"];
    if (gBdstoken) {
        DLog(@"✅ Got bdstoken from NSUserDefaults");
    }

    // 获取 BDUSS
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

    // 获取路径
    UIViewController *vc = topViewController();
    if (vc) {
        NSArray *pathKeys = @[@"path", @"currentPath", @"dirPath"];
        for (NSString *key in pathKeys) {
            @try {
                id value = [vc valueForKey:key];
                if ([value isKindOfClass:[NSString class]]) {
                    gCurrentPath = value;
                    DLog(@"✅ Found path: %@", gCurrentPath);
                    break;
                }
            } @catch (NSException *e) {}
        }
    }

    if (!gCurrentPath) gCurrentPath = @"/";

    DLog(@"📊 Path: %@, Token: %@, BDUSS: %@", gCurrentPath, gBdstoken ? @"✅" : @"❌", gBDUSS ? @"✅" : @"❌");
}

// ========== 浮游按钮 ==========

static void onFloatButtonTap(void) {
    DLog(@"👆 Float button tapped!");

    // 刷新路径和 token
    gCurrentPath = nil;
    gBdstoken = nil;
    gBDUSS = nil;
    autoDetectPathAndToken();

    // 显示信息
    NSString *msg = [NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@",
                       gCurrentPath,
                       gBdstoken ? @"✅" : @"❌",
                       gBDUSS ? @"✅" : @"❌"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];

    UIViewController *vc = topViewController();
    if (vc) {
        [vc presentViewController:alert animated:YES completion:nil];
    }
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

    // 拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(bdt_floatButtonPanned:)];
    [gFloatButton addGestureRecognizer:pan];

    [window addSubview:gFloatButton];
    DLog(@"✅ Float button shown");
}

// ========== 手势处理 ==========

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
    DLog(@"🚀 BaiduPan Troll v7.1 loaded");

    // 延迟显示浮游按钮，等待 APP 界面加载完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
