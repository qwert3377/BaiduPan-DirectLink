//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v9.2
//  Fix: 选择文件后直接调用 App 内置下载管理器，彻底绕过直链/重命名流程
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

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

static NSString * strictEncodeURIComponent(NSString *str) {
    if (!str) return @"";
    NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
    [cs addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 30;
    NSMutableDictionary *allHeaders = [@{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        @"Accept": @"application/json, text/plain, */*",
        @"Accept-Language": @"zh-CN,zh-Hans;q=0.9",
        @"Referer": @"https://pan.baidu.com/"
    } mutableCopy];
    if (gBDUSS) allHeaders[@"Cookie"] = [NSString stringWithFormat:@"BDUSS=%@", gBDUSS];
    if (headers) [allHeaders addEntriesFromDictionary:headers];
    req.allHTTPHeaderFields = allHeaders;
    if (body) req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { handler(nil, error); return; }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            handler(json, nil);
        });
    }];
    [task resume];
}

static NSString * scanMemoryForBdstoken(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    NSString *bestToken = nil;
    NSString *bestKey = nil;
    for (NSString *key in allDefaults) {
        id value = allDefaults[key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
            if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] > 0) {
                    if (str.length == 32) {
                        NSString *preview = [str substringToIndex:16];
                        DLog(@"Found 32-bit token in key '%@': %@...", key, preview);
                        return str;
                    }
                    if (str.length == 16 && !bestToken) {
                        bestToken = str;
                        bestKey = key;
                    }
                }
            }
        }
    }
    if (bestToken) {
        NSString *preview = [bestToken substringToIndex:16];
        DLog(@"Only found 16-bit token in key '%@': %@...", bestKey, preview);
        return bestToken;
    }
    return nil;
}

static NSString * extractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir", @"_path", @"_currentPath", @"directory", @"folderPath", @"currentFolder", @"mPath", @"_mPath", @"fileListPath"];
    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) return value;
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)vc;
    else if (vc.navigationController) nav = vc.navigationController;
    if (!nav) return extractPathFromVC(vc);
    NSArray *vcs = nav.viewControllers;
    NSMutableArray *components = [NSMutableArray array];
    for (UIViewController *controller in vcs) {
        NSString *path = extractPathFromVC(controller);
        if (path && path.length > 0 && ![path isEqualToString:@"/"]) {
            [components addObject:path];
        } else if (controller.title && controller.title.length > 0
                   && ![controller.title isEqualToString:@"百度网盘"]
                   && ![controller.title isEqualToString:@"文件"]
                   && ![controller.title isEqualToString:@"首页"]) {
            [components addObject:controller.title];
        } else if (controller.navigationItem.title && controller.navigationItem.title.length > 0
                   && ![controller.navigationItem.title isEqualToString:@"百度网盘"]) {
            [components addObject:controller.navigationItem.title];
        }
    }
    if (components.count == 0) return nil;
    NSString *fullPath = [components componentsJoinedByString:@"/"];
    if (![fullPath hasPrefix:@"/"]) fullPath = [@"/" stringByAppendingString:fullPath];
    return fullPath;
}

static void autoDetectPathAndToken(void) {
    DLog(@"Starting auto-detection...");
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN", @"access_token", @"bd_token", @"pan_token"];
    for (NSString *key in tokenKeys) {
        gBdstoken = [defaults objectForKey:key];
        if (gBdstoken) { DLog(@"Got bdstoken from key: %@", key); break; }
    }
    if (!gBdstoken) gBdstoken = scanMemoryForBdstoken();
    if (!gBdstoken) DLog(@"WARNING: No token detected from app");

    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) { gBDUSS = cookie.value; DLog(@"Got BDUSS from cookie"); break; }
    }
    if (!gBDUSS) { gBDUSS = [defaults objectForKey:@"BDUSS"]; if (gBDUSS) DLog(@"Got BDUSS from NSUserDefaults"); }
    gCurrentPath = buildPathFromNavStack();
    if (!gCurrentPath) gCurrentPath = @"/";
    NSString *tokenPreview = gBdstoken ? [gBdstoken substringToIndex:MIN(16, gBdstoken.length)] : @"missing";
    DLog(@"Path: %@ | Token: %@ | BDUSS: %@", gCurrentPath, tokenPreview, gBDUSS ? @"OK" : @"missing");
}

static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token detected from app. Please ensure you are logged in."}]);
        return;
    }
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100", encodedPath, gBdstoken];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        completion(list, nil);
    });
}

// ========== v9.2 核心：调用 App 内部下载管理器 ==========

static id findDownloadManager(void) {
    // 尝试获取 BDPanDownloadManager 单例
    Class mgrClass = NSClassFromString(@"BDPanDownloadManager");
    if (mgrClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedManager");
        if ([mgrClass respondsToSelector:sharedSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id mgr = [mgrClass performSelector:sharedSel];
            #pragma clang diagnostic pop
            if (mgr) { DLog(@"Found BDPanDownloadManager sharedManager"); return mgr; }
        }
        sharedSel = NSSelectorFromString(@"defaultManager");
        if ([mgrClass respondsToSelector:sharedSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id mgr = [mgrClass performSelector:sharedSel];
            #pragma clang diagnostic pop
            if (mgr) { DLog(@"Found BDPanDownloadManager defaultManager"); return mgr; }
        }
    }

    // 尝试 BBADownloadManager
    mgrClass = NSClassFromString(@"BBADownloadManager");
    if (mgrClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedManager");
        if ([mgrClass respondsToSelector:sharedSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id mgr = [mgrClass performSelector:sharedSel];
            #pragma clang diagnostic pop
            if (mgr) { DLog(@"Found BBADownloadManager sharedManager"); return mgr; }
        }
    }

    // 尝试 BBADownloaderManager
    mgrClass = NSClassFromString(@"BBADownloaderManager");
    if (mgrClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedManager");
        if ([mgrClass respondsToSelector:sharedSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id mgr = [mgrClass performSelector:sharedSel];
            #pragma clang diagnostic pop
            if (mgr) { DLog(@"Found BBADownloaderManager sharedManager"); return mgr; }
        }
    }

    return nil;
}

static void callInternalDownloadWithFileMeta(NSDictionary *fileMeta) {
    id downloadMgr = findDownloadManager();
    if (!downloadMgr) {
        DLog(@"ERROR: No download manager found in app");
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载失败" message:@"未找到 App 内部下载管理器，请确保百度网盘版本兼容" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
        return;
    }

    // 方法1: addToDownloadListWithFileMeta:completion:
    SEL sel1 = NSSelectorFromString(@"addToDownloadListWithFileMeta:completion:");
    if ([downloadMgr respondsToSelector:sel1]) {
        DLog(@"Calling addToDownloadListWithFileMeta:completion:");
        void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
            if (success) {
                DLog(@"Download queued successfully");
                showToast(@"已加入下载队列");
            } else {
                DLog(@"Download queue failed: %@", error.localizedDescription);
                showToast(@"加入下载队列失败");
            }
        };
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [downloadMgr performSelector:sel1 withObject:fileMeta withObject:completion];
        #pragma clang diagnostic pop
        return;
    }

    // 方法2: addToDownloadListWithFileMeta:
    SEL sel2 = NSSelectorFromString(@"addToDownloadListWithFileMeta:");
    if ([downloadMgr respondsToSelector:sel2]) {
        DLog(@"Calling addToDownloadListWithFileMeta:");
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [downloadMgr performSelector:sel2 withObject:fileMeta];
        #pragma clang diagnostic pop
        showToast(@"已加入下载队列");
        return;
    }

    // 方法3: addDownloadItemWithURL:Title:businessType:animationed:
    SEL sel3 = NSSelectorFromString(@"addDownloadItemWithURL:Title:businessType:animationed:");
    if ([downloadMgr respondsToSelector:sel3]) {
        NSString *path = fileMeta[@"path"];
        NSString *name = fileMeta[@"server_filename"];
        DLog(@"Calling addDownloadItemWithURL:Title:businessType:animationed:");
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [downloadMgr performSelector:sel3 withObject:path withObject:name withObject:@(0) withObject:@(YES)];
        #pragma clang diagnostic pop
        showToast(@"已加入下载队列");
        return;
    }

    // 方法4: downloadFileWithPath:
    SEL sel4 = NSSelectorFromString(@"downloadFileWithPath:");
    if ([downloadMgr respondsToSelector:sel4]) {
        NSString *path = fileMeta[@"path"];
        DLog(@"Calling downloadFileWithPath:");
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [downloadMgr performSelector:sel4 withObject:path];
        #pragma clang diagnostic pop
        showToast(@"已加入下载队列");
        return;
    }

    // 方法5: startDownloadWithFileMeta:
    SEL sel5 = NSSelectorFromString(@"startDownloadWithFileMeta:");
    if ([downloadMgr respondsToSelector:sel5]) {
        DLog(@"Calling startDownloadWithFileMeta:");
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [downloadMgr performSelector:sel5 withObject:fileMeta];
        #pragma clang diagnostic pop
        showToast(@"已加入下载队列");
        return;
    }

    DLog(@"ERROR: Download manager found but no compatible method");
    showToast(@"未找到兼容的下载方法");
}

// ========== 通过当前 VC 触发下载（备选方案） ==========

static void triggerDownloadViaCurrentVC(NSDictionary *fileMeta) {
    UIViewController *vc = topViewController();
    if (!vc) return;

    // 尝试调用 VC 上的下载方法
    NSArray *downloadSelectors = @[
        @"downloadFile:",
        @"downloadFileWithMeta:",
        @"startDownload:",
        @"addDownloadTask:",
        @"handleDownloadAction:",
        @"onDownloadButtonClick:",
        @"didClickDownload:",
    ];

    for (NSString *selName in downloadSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC download method: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel withObject:fileMeta];
            #pragma clang diagnostic pop
            showToast(@"已触发下载");
            return;
        }
    }

    // 如果 VC 没有下载方法，尝试找它的 navigationController 或 parent
    if (vc.navigationController) {
        UIViewController *rootVC = vc.navigationController.topViewController;
        if (rootVC != vc) {
            for (NSString *selName in downloadSelectors) {
                SEL sel = NSSelectorFromString(selName);
                if ([rootVC respondsToSelector:sel]) {
                    DLog(@"Calling rootVC download method: %@", selName);
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [rootVC performSelector:sel withObject:fileMeta];
                    #pragma clang diagnostic pop
                    showToast(@"已触发下载");
                    return;
                }
            }
        }
    }

    // 最后尝试通过内部下载管理器
    callInternalDownloadWithFileMeta(fileMeta);
}

// ========== UI 辅助 ==========

static void showToast(NSString *msg) {
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

// ========== 主流程 ==========

static void runDownloadFlow(NSDictionary *fileMeta) {
    NSString *name = fileMeta[@"server_filename"] ?: @"unknown";
    DLog(@"Starting download for: %@", name);

    // 优先尝试通过当前 VC 触发（最自然的方式）
    triggerDownloadViaCurrentVC(fileMeta);
}

static void triggerDownloadFlow(void) {
    DLog(@"Starting download flow...");
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            DLog(@"Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取文件列表失败" message:err ? err.localizedDescription : @"文件夹为空" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }

        if (fileItems.count == 0) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"没有文件" message:@"当前文件夹没有可下载的文件" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件下载" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *title = name;
            if (size) {
                double mb = [size doubleValue] / (1024.0 * 1024.0);
                title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                runDownloadFlow(file);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *vc = topViewController();
        if (vc) {
            if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                sheet.popoverPresentationController.sourceView = vc.view;
                sheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
            }
            [vc presentViewController:sheet animated:YES completion:nil];
        }
    });
}

// ========== 浮游按钮 ==========

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = @"missing";
    if (gBdstoken) {
        NSUInteger len = gBdstoken.length;
        NSUInteger previewLen = len > 16 ? 16 : len;
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v9.2"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 下载文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        triggerDownloadFlow();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
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
    [gFloatButton addTarget:nil action:@selector(bdt_floatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(bdt_floatButtonPanned:)];
    [gFloatButton addGestureRecognizer:pan];
    [window addSubview:gFloatButton];
    DLog(@"Float button shown");
}

@interface NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender;
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture;
@end

@implementation NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender { onFloatButtonTap(); }
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}
@end

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"BaiduPan Troll v9.2 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
