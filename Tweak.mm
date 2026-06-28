//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v12.1
//  精简版：仅保留自动点击测试流程 + 刷新类引用
//  流程：打开浮窗 -> 点击测试 -> 自动点击第一个文件 -> 打印每一步日志
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// ========== 刷新/更新类引用（确保编译器保留符号）==========
__attribute__((used)) static const char *kRefreshClasses[] = {
    "BDPanCapacityRefreshRequest",
    "BDPanFaceCoverUpdateRequest", 
    "BDPanFaceUpdateRequest",
    "BDPanNetworkUpdateLogProtocol",
    "BDPanNovelUpdateRequest",
    "BDPanRandUpdateApi",
    "BDPanRefreshBackNormalFooter",
    "BDPanUpdateFolderPropertyRequest",
    "BDPanUpdateLogger",
    "BBADimeCircleRefreshHeader",
    "BBADimeCircleRefreshFooter",
    "BBARefreshAutoNormalFooter",
    "MJRefreshImgLoadingHeader",
    "MJRefreshAutoImgLoadingFooter",
    "EGORefreshTableHeaderDelegate",
    "BDWalletRefreshScrollViewDidScroll",
    "BDWalletRefreshTableHeaderDidTriggerRefresh",
    "addRefreshHeaderForWebView",
    "appearanceRefresh",
    "BBAJSBindingUpdateManager",
    "BBASMUpdateManager",
    "BBASMUpdateService",
    "BBASMPreloadManager",
    "BDPanPreLoadWebViewManager",
    "BDPanPreLoadModel",
    "BDPanAjaxPreloader",
    "BBAStoreKitAdPreloadManager",
    "GDTAdPreloadManager",
    "GDTSplashAdPreloadManager",
    "UpdateListenerNode",
    "UpdateType",
    "getUpdateManager",
    NULL
};

// ========== 前置声明 ==========
static UIViewController * topViewController(void);
static void showToast(NSString *msg);
static void showAlert(NSString *title, NSString *msg);
static UIView * findViewRecursively(UIView *root, Class targetClass);
static id getFileListDataSource(UIViewController *vc);
static void performSelectTableViewRow(UITableView *tableView, NSIndexPath *indexPath);
static void performSelectCollectionViewItem(UICollectionView *collectionView, NSIndexPath *indexPath);
static void autoClickFirstFile(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

// ========== 浮窗按钮 Target ==========
@interface BDTFloatButtonTarget : NSObject
@end
@implementation BDTFloatButtonTarget
- (void)floatButtonTapped:(id)sender { onFloatButtonTap(); }
- (void)floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}
@end
static BDTFloatButtonTarget *gFloatButtonTarget = nil;

// ========== 基础工具 ==========

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
    while (vc.presentedViewController) vc = vc.presentedViewController;
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

static void showToast(NSString *msg) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ showToast(msg); });
        return;
    }
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) { window = scene.windows.firstObject; break; }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return;
    UILabel *toast = [[UILabel alloc] init];
    toast.text = msg;
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14];
    toast.layer.cornerRadius = 16;
    toast.layer.masksToBounds = YES;
    toast.numberOfLines = 0;
    [toast sizeToFit];
    CGFloat w = toast.bounds.size.width + 32;
    CGFloat h = toast.bounds.size.height + 16;
    toast.frame = CGRectMake((window.bounds.size.width - w) / 2, window.bounds.size.height - 120, w, h);
    [window addSubview:toast];
    toast.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
    });
}

static void showAlert(NSString *title, NSString *msg) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ showAlert(title, msg); });
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static UIView * findViewRecursively(UIView *root, Class targetClass) {
    if (!root) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = findViewRecursively(subview, targetClass);
        if (found) return found;
    }
    return nil;
}

static id getFileListDataSource(UIViewController *vc) {
    if (!vc) return nil;
    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);
    if (tableView && tableView.dataSource) return tableView.dataSource;
    UICollectionView *collectionView = (UICollectionView *)findViewRecursively(vc.view, [UICollectionView class]);
    if (collectionView && collectionView.dataSource) return collectionView.dataSource;

    NSArray *dataSourceKeys = @[@"dataSource", @"viewModel", @"fileViewModel", @"listViewModel", @"_dataSource", @"_viewModel", @"presenter", @"interactor"];
    for (NSString *key in dataSourceKeys) {
        @try {
            id value = [vc valueForKey:key];
            if (value) return value;
        } @catch (NSException *e) {}
    }
    if (vc.navigationController) {
        for (UIViewController *controller in vc.navigationController.viewControllers) {
            for (NSString *key in dataSourceKeys) {
                @try {
                    id value = [controller valueForKey:key];
                    if (value) return value;
                } @catch (NSException *e) {}
            }
        }
    }
    return nil;
}

static void performSelectTableViewRow(UITableView *tableView, NSIndexPath *indexPath) {
    if (!tableView || !indexPath) { DLog(@"performSelectTableViewRow: nil tableView or indexPath"); return; }
    @try {
        [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        [tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
        id delegate = tableView.delegate;
        if (delegate && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            [delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
            DLog(@"✅ Triggered tableView:didSelectRowAtIndexPath: %@", indexPath);
            showToast([NSString stringWithFormat:@"✅ 点击了第%ld行", (long)indexPath.row]);
        } else {
            DLog(@"❌ TableView delegate missing didSelectRowAtIndexPath");
            showToast(@"❌ Delegate 无响应");
        }
    } @catch (NSException *e) {
        DLog(@"❌ performSelectTableViewRow exception: %@", e.reason);
        showToast([NSString stringWithFormat:@"❌ 异常: %@", e.reason]);
    }
}

static void performSelectCollectionViewItem(UICollectionView *collectionView, NSIndexPath *indexPath) {
    if (!collectionView || !indexPath) { DLog(@"performSelectCollectionViewItem: nil collectionView or indexPath"); return; }
    @try {
        [collectionView scrollToItemAtIndexPath:indexPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
        [collectionView selectItemAtIndexPath:indexPath animated:NO scrollPosition:UICollectionViewScrollPositionNone];
        id delegate = collectionView.delegate;
        if (delegate && [delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
            [delegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
            DLog(@"✅ Triggered collectionView:didSelectItemAtIndexPath: %@", indexPath);
            showToast([NSString stringWithFormat:@"✅ 点击了第%ld项", (long)indexPath.item]);
        } else {
            DLog(@"❌ CollectionView delegate missing didSelectItemAtIndexPath");
            showToast(@"❌ Delegate 无响应");
        }
    } @catch (NSException *e) {
        DLog(@"❌ performSelectCollectionViewItem exception: %@", e.reason);
        showToast([NSString stringWithFormat:@"❌ 异常: %@", e.reason]);
    }
}

// ========== 核心：自动点击第一个文件（带详细日志）==========

static void autoClickFirstFile(void) {
    DLog(@"========== 开始自动点击测试 ==========");

    UIViewController *vc = topViewController();
    if (!vc) {
        DLog(@"❌ Step 1: topViewController = nil");
        showToast(@"❌ 无法获取当前页面");
        return;
    }
    DLog(@"✅ Step 1: topViewController = %@", NSStringFromClass([vc class]));

    // Step 2: 查找 UITableView
    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);
    if (tableView) {
        DLog(@"✅ Step 2: 找到 UITableView");

        // Step 3: 获取数据源
        id dataSource = getFileListDataSource(vc);
        if (!dataSource) {
            DLog(@"❌ Step 3: dataSource = nil");
            showToast(@"❌ 无法获取数据源");
            return;
        }
        DLog(@"✅ Step 3: dataSource = %@", NSStringFromClass([dataSource class]));

        // Step 4: 获取文件数量
        NSInteger count = 0;
        if ([dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
            count = [dataSource tableView:tableView numberOfRowsInSection:0];
            DLog(@"✅ Step 4: 文件数量 = %ld", (long)count);
        } else {
            DLog(@"❌ Step 4: dataSource 不响应 numberOfRowsInSection");
            showToast(@"❌ 数据源无行数方法");
            return;
        }

        if (count == 0) {
            DLog(@"❌ Step 5: 文件列表为空");
            showToast(@"❌ 文件列表为空");
            return;
        }

        // Step 5: 点击第一行
        DLog(@"🎯 Step 5: 准备点击第 0 行...");
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:0];
        performSelectTableViewRow(tableView, indexPath);
        return;
    }

    // Step 2b: 查找 UICollectionView
    UICollectionView *collectionView = (UICollectionView *)findViewRecursively(vc.view, [UICollectionView class]);
    if (collectionView) {
        DLog(@"✅ Step 2: 找到 UICollectionView");

        id dataSource = collectionView.dataSource;
        if (!dataSource) {
            DLog(@"❌ Step 3: collectionView.dataSource = nil");
            showToast(@"❌ CollectionView 无数据源");
            return;
        }
        DLog(@"✅ Step 3: dataSource = %@", NSStringFromClass([dataSource class]));

        NSInteger count = 0;
        if ([dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
            count = [dataSource collectionView:collectionView numberOfItemsInSection:0];
            DLog(@"✅ Step 4: 文件数量 = %ld", (long)count);
        } else {
            DLog(@"❌ Step 4: dataSource 不响应 numberOfItemsInSection");
            showToast(@"❌ 数据源无项数方法");
            return;
        }

        if (count == 0) {
            DLog(@"❌ Step 5: 文件列表为空");
            showToast(@"❌ 文件列表为空");
            return;
        }

        DLog(@"🎯 Step 5: 准备点击第 0 项...");
        NSIndexPath *indexPath = [NSIndexPath indexPathForItem:0 inSection:0];
        performSelectCollectionViewItem(collectionView, indexPath);
        return;
    }

    DLog(@"❌ Step 2: 未找到 UITableView 或 UICollectionView");
    showToast(@"❌ 未找到文件列表视图");
}

// ========== 浮窗按钮 ==========

static void onFloatButtonTap(void) {
    DLog(@"浮窗按钮被点击");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v12.1"
                                                                   message:@"3秒后将自动点击第一个文件，请确保当前在文件列表页面"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"🧪 立即测试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        autoClickFirstFile();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"⏱️ 3秒后自动测试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        showToast(@"3秒后开始自动点击...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            autoClickFirstFile();
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void showFloatButton(void) {
    if (gFloatButton) return;
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) { window = scene.windows.firstObject; break; }
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

    if (!gFloatButtonTarget) gFloatButtonTarget = [[BDTFloatButtonTarget alloc] init];
    [gFloatButton addTarget:gFloatButtonTarget action:@selector(floatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gFloatButtonTarget action:@selector(floatButtonPanned:)];
    [gFloatButton addGestureRecognizer:pan];
    [window addSubview:gFloatButton];
    DLog(@"✅ 浮窗按钮已显示");
}

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"BaiduPan Troll v12.1 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
    });
}
