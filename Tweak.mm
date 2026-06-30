//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v11.0
//  Flow: select -> rename to .88888888888888 -> REFRESH -> auto try open methods
//  CHANGELOG v11.0: No-scroll approach, test multiple open methods with user confirmation
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

static NSString *gPendingRestoreFileId = nil;
static NSString *gPendingRestorePdfPath = nil;
static NSString *gPendingRestoreOriginalName = nil;
static NSString *gPendingPpName = nil;
static NSString *gPendingFilePath = nil;

static NSInteger gCurrentMethodIndex = 0;
static NSArray *gOpenMethods = nil;

// Forward declarations
static UIViewController * topViewController(void);
static NSInteger currentNavStackCount(void);
static NSString * strictEncodeURIComponent(NSString *str);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static NSString * scanMemoryForBdstoken(void);
static NSString * extractPathFromVC(UIViewController *vc);
static NSString * buildPathFromNavStack(void);
static void autoDetectPathAndToken(void);
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void showToast(NSString *msg);
static void forceRefreshFileList(void);
static void refreshVC(UIViewController *vc);
static UIScrollView * findScrollViewInView(UIView *view);
static void simulatePullToRefreshOnScrollView(UIScrollView *scrollView);
static void tryRefreshOnScrollView(UIScrollView *scrollView);
static void triggerMJRefresh(id headerOrFooter);
static void triggerNotificationFallback(void);
static void triggerEGORefresh(UIView *subview, UIScrollView *scrollView);
static void triggerBDWalletRefresh(UIView *subview, UIScrollView *scrollView);
static void executeRestore(void);
static void executeRestoreWithoutRefresh(void (^completion)(BOOL success));
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);
static void tryNextOpenMethod(void);
static void showMethodResultDialog(NSString *methodName, NSString *detail);
static void finishAllMethodsAndRestore(void);

// Open method implementations
static void openMethod_delegateCall(NSString *ppName, NSString *filePath);
static void openMethod_vcDirectCall(NSString *ppName, NSString *filePath);
static void openMethod_simulateCellTap(NSString *ppName, NSString *filePath);
static void openMethod_sendAction(NSString *ppName, NSString *filePath);
static void openMethod_notification(NSString *ppName, NSString *filePath);
static void openMethod_runtimeSearch(NSString *ppName, NSString *filePath);
static void openMethod_kvoTrigger(NSString *ppName, NSString *filePath);
static void openMethod_urlScheme(NSString *ppName, NSString *filePath);
static void openMethod_pushVC(NSString *ppName, NSString *filePath);
static void openMethod_fileIDLookup(NSString *ppName, NSString *filePath);
static void openMethod_downloadDirect(NSString *ppName, NSString *filePath);
static void openMethod_shareSheet(NSString *ppName, NSString *filePath);
static void openMethod_quickLook(NSString *ppName, NSString *filePath);
static void openMethod_webView(NSString *ppName, NSString *filePath);
static void openMethod_documentPicker(NSString *ppName, NSString *filePath);
static void openMethod_accessibility(NSString *ppName, NSString *filePath);
static void openMethod_responderChain(NSString *ppName, NSString *filePath);
static void openMethod_customURL(NSString *ppName, NSString *filePath);
static void openMethod_deepLink(NSString *ppName, NSString *filePath);
static void openMethod_fileProvider(NSString *ppName, NSString *filePath);

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

static NSInteger currentNavStackCount(void) {
    UIViewController *vc = topViewController();
    if (!vc) return 0;
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    } else {
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
        if (window && window.rootViewController) {
            UIViewController *root = window.rootViewController;
            while (root.presentedViewController) root = root.presentedViewController;
            if ([root isKindOfClass:[UINavigationController class]]) {
                nav = (UINavigationController *)root;
            } else if ([root isKindOfClass:[UITabBarController class]]) {
                UIViewController *sel = [(UITabBarController *)root selectedViewController];
                if ([sel isKindOfClass:[UINavigationController class]]) {
                    nav = (UINavigationController *)sel;
                }
            }
        }
    }
    if (nav) return nav.viewControllers.count;
    return 1;
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

    NSArray *preferredKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN",
                                @"access_token", @"bd_token", @"pan_token", @"panToken",
                                @"user_token", @"auth_token"];
    for (NSString *key in preferredKeys) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            if (str.length == 32) {
                NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
                if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                    NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                    if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] > 0) {
                        DLog(@"Found 32-bit token in preferred key '%@': %@...", key, [str substringToIndex:8]);
                        return str;
                    }
                }
            }
        }
    }

    NSArray *blacklistKeys = @[@"password", @"passwd", @"secret", @"credit", @"card", @"phone", @"mobile", @"email", @"address"];
    for (NSString *key in allDefaults) {
        BOOL isBlacklisted = NO;
        NSString *lowKey = key.lowercaseString;
        for (NSString *bk in blacklistKeys) {
            if ([lowKey containsString:bk]) { isBlacklisted = YES; break; }
        }
        if (isBlacklisted) continue;

        id value = allDefaults[key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
            if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] > 0) {
                    if (str.length == 32) {
                        DLog(@"Found 32-bit token in key '%@': %@...", key, [str substringToIndex:8]);
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
        DLog(@"Only found 16-bit token in key '%@': %@...", bestKey, [bestToken substringToIndex:8]);
        return bestToken;
    }
    return nil;
}

static NSString * extractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir",
                          @"_path", @"_currentPath", @"directory", @"folderPath", @"currentFolder",
                          @"mPath", @"_mPath", @"fileListPath", @"currentDirectory", @"directoryPath",
                          @"currentDirPath", @"_directory", @"_dirPath"];
    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                NSString *path = (NSString *)value;
                if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
                return path;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;
    NSString *path = extractPathFromVC(vc);
    if (path && path.length > 0 && ![path isEqualToString:@"/"]) return path;
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }
    if (nav) {
        UIViewController *topVC = nav.topViewController;
        NSString *topPath = extractPathFromVC(topVC);
        if (topPath && topPath.length > 0 && ![topPath isEqualToString:@"/"]) return topPath;
        NSArray *vcs = nav.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            NSString *p = extractPathFromVC(vcs[i]);
            if (p && p.length > 0 && ![p isEqualToString:@"/"]) return p;
        }
        NSMutableArray *components = [NSMutableArray array];
        for (UIViewController *controller in vcs) {
            NSString *title = controller.title;
            if (!title || title.length == 0) title = controller.navigationItem.title;
            if (title && title.length > 0
                && ![title isEqualToString:@"百度网盘"]
                && ![title isEqualToString:@"文件"]
                && ![title isEqualToString:@"首页"]) {
                if (components.count == 0 || ![components.lastObject isEqualToString:title]) {
                    [components addObject:title];
                }
            }
        }
        if (components.count > 0) {
            NSString *fullPath = [components componentsJoinedByString:@"/"];
            if (![fullPath hasPrefix:@"/"]) fullPath = [@"/" stringByAppendingString:fullPath];
            return fullPath;
        }
    }
    return nil;
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
    if (!gBdstoken) DLog(@"WARNING: No token detected");
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) { gBDUSS = cookie.value; DLog(@"Got BDUSS from cookie"); break; }
    }
    if (!gBDUSS) { gBDUSS = [defaults objectForKey:@"BDUSS"]; if (gBDUSS) DLog(@"Got BDUSS from NSUserDefaults"); }
    gCurrentPath = buildPathFromNavStack();
    if (!gCurrentPath) gCurrentPath = @"/";
    NSString *tokenPreview = gBdstoken ? [gBdstoken substringToIndex:MIN(8, gBdstoken.length)] : @"missing";
    DLog(@"Path: %@ | Token: %@ | BDUSS: %@", gCurrentPath, tokenPreview, gBDUSS ? @"OK" : @"missing");
}

static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token detected."}]);
        return;
    }
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100&app_id=250528", encodedPath, gBdstoken];
    DLog(@"fetchFileList URL: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] != 0) {
            NSString *errMsg = json[@"errmsg"] ?: [NSString stringWithFormat:@"API errno=%@", errnoNum];
            DLog(@"fetchFileList API error: %@", errMsg);
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            return;
        }
        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        completion(list, nil);
    });
}

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!gBdstoken) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=rename&clienttype=0&app_id=250528&web=1&bdstoken=%@", gBdstoken];
    NSString *filelist = [NSString stringWithFormat:@"[{\"id\":%@,\"path\":\"%@\",\"newname\":\"%@\"}]", fileId, path, newName];
    NSString *body = [NSString stringWithFormat:@"filelist=%@", strictEncodeURIComponent(filelist)];
    DLog(@"RENAME body: %@", body);
    DLog(@"RENAME filelist raw: %@", filelist);
    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded; charset=UTF-8",
        @"X-Requested-With": @"XMLHttpRequest"
    };
    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) {
            DLog(@"RENAME network error: %@", err);
            completion(NO, err);
            return;
        }
        DLog(@"RENAME response: %@", json);
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"Unknown error";
            NSString *fullErr = [NSString stringWithFormat:@"errno=%@ | %@", errnoNum ?: @"nil", msg];
            DLog(@"RENAME failed: %@", fullErr);
            completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: fullErr}]);
        }
    });
}

static void showToast(NSString *msg) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) { window = scene.windows.firstObject; break; }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return;
    for (UIView *sub in window.subviews) {
        if (sub.tag == 0xBDF0) [sub removeFromSuperview];
    }
    UILabel *toast = [[UILabel alloc] init];
    toast.tag = 0xBDF0;
    toast.text = msg;
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14];
    toast.layer.cornerRadius = 16;
    toast.layer.masksToBounds = YES;
    toast.numberOfLines = 0;
    [toast sizeToFit];
    CGFloat w = MIN(toast.bounds.size.width + 32, window.bounds.size.width - 40);
    CGFloat h = toast.bounds.size.height + 16;
    toast.frame = CGRectMake((window.bounds.size.width - w) / 2, window.bounds.size.height - 140, w, h);
    [window addSubview:toast];
    toast.alpha = 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [toast removeFromSuperview];
    });
}

static UIScrollView * findScrollViewInView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) return (UIScrollView *)view;
    for (UIView *subview in view.subviews) {
        UIScrollView *found = findScrollViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static void triggerMJRefresh(id headerOrFooter) {
    if (!headerOrFooter) return;
    SEL beginSel = NSSelectorFromString(@"beginRefreshing");
    SEL executeSel = NSSelectorFromString(@"executeRefreshingCallback");
    if ([headerOrFooter respondsToSelector:beginSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [headerOrFooter performSelector:beginSel];
        #pragma clang diagnostic pop
    }
    if ([headerOrFooter respondsToSelector:executeSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [headerOrFooter performSelector:executeSel];
        #pragma clang diagnostic pop
    }
}

static void triggerNotificationFallback(void) {
    NSArray *notifNames = @[
        @"BDPanRefreshFileListNotification",
        @"BDPanReloadFileListNotification",
        @"kRefreshFileListNotification",
        @"kReloadDataNotification",
        @"RefreshFileListNotification",
        @"com.baidu.pan.refreshFileList",
        @"BDPanFileListDidChangeNotification",
        @"BDPanFileListNeedRefreshNotification"
    ];
    for (NSString *name in notifNames) {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:@{@"path": gCurrentPath ?: @"/"}];
    }
}

static void triggerEGORefresh(UIView *subview, UIScrollView *scrollView) {
    SEL egoScrollSel = NSSelectorFromString(@"egoRefreshScrollViewDidScroll:");
    SEL egoDragSel = NSSelectorFromString(@"egoRefreshScrollViewDidEndDragging:");
    if ([subview respondsToSelector:egoScrollSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [subview performSelector:egoScrollSel withObject:scrollView];
        if ([subview respondsToSelector:egoDragSel]) {
            [subview performSelector:egoDragSel withObject:scrollView];
        }
        #pragma clang diagnostic pop
    }
}

static void triggerBDWalletRefresh(UIView *subview, UIScrollView *scrollView) {
    SEL bdScrollSel = NSSelectorFromString(@"BDWalletRefreshScrollViewDidScroll:");
    SEL bdDragSel = NSSelectorFromString(@"BDWalletRefreshScrollViewDidEndDragging:");
    if ([subview respondsToSelector:bdScrollSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [subview performSelector:bdScrollSel withObject:scrollView];
        if ([subview respondsToSelector:bdDragSel]) {
            [subview performSelector:bdDragSel withObject:scrollView];
        }
        #pragma clang diagnostic pop
    }
}

static void simulatePullToRefreshOnScrollView(UIScrollView *scrollView) {
    if (!scrollView) return;
    DLog(@"Simulating pull-to-refresh gesture");
    CGPoint originalOffset = scrollView.contentOffset;
    SEL willBeginDragging = @selector(scrollViewWillBeginDragging:);
    if (scrollView.delegate && [scrollView.delegate respondsToSelector:willBeginDragging]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [scrollView.delegate performSelector:willBeginDragging withObject:scrollView];
        #pragma clang diagnostic pop
    }
    scrollView.contentOffset = CGPointMake(originalOffset.x, -150);
    SEL didScroll = @selector(scrollViewDidScroll:);
    if (scrollView.delegate && [scrollView.delegate respondsToSelector:didScroll]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [scrollView.delegate performSelector:didScroll withObject:scrollView];
        #pragma clang diagnostic pop
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        SEL didEndDragging = @selector(scrollViewDidEndDragging:willDecelerate:);
        if (scrollView.delegate && [scrollView.delegate respondsToSelector:didEndDragging]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [scrollView.delegate performSelector:didEndDragging withObject:scrollView withObject:@(NO)];
            #pragma clang diagnostic pop
        }
        SEL didEndDecelerating = @selector(scrollViewDidEndDecelerating:);
        if (scrollView.delegate && [scrollView.delegate respondsToSelector:didEndDecelerating]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [scrollView.delegate performSelector:didEndDecelerating withObject:scrollView];
            #pragma clang diagnostic pop
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            scrollView.contentOffset = originalOffset;
        });
    });
}

static void tryRefreshOnScrollView(UIScrollView *scrollView) {
    if (!scrollView) return;
    if (scrollView.refreshControl) {
        DLog(@"Triggering UIRefreshControl");
        [scrollView.refreshControl beginRefreshing];
        scrollView.contentOffset = CGPointMake(scrollView.contentOffset.x, -scrollView.refreshControl.frame.size.height);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [scrollView.refreshControl endRefreshing];
        });
        return;
    }
    id mjHeader = nil;
    id mjFooter = nil;
    @try {
        mjHeader = [scrollView valueForKey:@"mj_header"];
        mjFooter = [scrollView valueForKey:@"mj_footer"];
    } @catch (NSException *e) {}
    if (mjHeader) { triggerMJRefresh(mjHeader); return; }
    if (mjFooter) { triggerMJRefresh(mjFooter); return; }
    simulatePullToRefreshOnScrollView(scrollView);
    for (UIView *subview in scrollView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"RefreshHeader"] ||
            [className containsString:@"EGORefresh"] ||
            [className containsString:@"BDWalletRefresh"] ||
            [className containsString:@"BDPanRefresh"] ||
            [className containsString:@"RadarRefresh"] ||
            [className containsString:@"DimeCircleRefresh"]) {
            DLog(@"Found refresh component: %@", className);
            if ([subview respondsToSelector:@selector(beginRefreshing)]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [subview performSelector:@selector(beginRefreshing)];
                #pragma clang diagnostic pop
                return;
            }
            triggerEGORefresh(subview, scrollView);
            triggerBDWalletRefresh(subview, scrollView);
        }
    }
}

static void refreshVC(UIViewController *vc) {
    if (!vc) return;
    NSArray *baiduSelectors = @[
        @"refreshFileList", @"reloadFileList", @"updateFileList",
        @"refreshData", @"reloadData", @"updateData",
        @"refreshContent", @"reloadContent", @"updateContent",
        @"requestFileList", @"fetchFileList", @"loadFileList",
        @"beginRefreshing", @"beginRefresh:",
        @"refresh", @"reload", @"update",
        @"requestData", @"loadData", @"fetchData"
    ];
    for (NSString *selName in baiduSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC refresh method: %@ on %@", selName, NSStringFromClass([vc class]));
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            return;
        }
    }
    if ([vc.view isKindOfClass:[UITableView class]]) {
        [(UITableView *)vc.view reloadData];
        return;
    }
    if ([vc.view isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)vc.view reloadData];
        return;
    }
    UIScrollView *sv = findScrollViewInView(vc.view);
    if (sv) {
        tryRefreshOnScrollView(sv);
        return;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in [(UINavigationController *)vc viewControllers]) refreshVC(child);
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)vc viewControllers]) refreshVC(child);
    } else if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in [(UISplitViewController *)vc viewControllers]) refreshVC(child);
    }
    refreshVC(vc.presentedViewController);
}

static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) { DLog(@"No top VC for refresh"); return; }
    DLog(@"Attempting refresh on top VC: %@", NSStringFromClass([vc class]));
    refreshVC(vc);
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        if (window.rootViewController && window.rootViewController != vc) {
            refreshVC(window.rootViewController);
        }
    }
    triggerNotificationFallback();
}

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        return;
    }
    DLog(@"Executing restore: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            showToast(@"✅ 已自动恢复原名");
            forceRefreshFileList();
        } else {
            showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]);
        }
        gPendingRestoreFileId = nil;
        gPendingRestorePdfPath = nil;
        gPendingRestoreOriginalName = nil;
        gPendingPpName = nil;
        gPendingFilePath = nil;
        gCurrentMethodIndex = 0;
    });
}

static void executeRestoreWithoutRefresh(void (^completion)(BOOL success)) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        if (completion) completion(NO);
        return;
    }
    DLog(@"Executing restore without refresh: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            DLog(@"Restore success (no refresh)");
        } else {
            DLog(@"Restore failed: %@", e);
            showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]);
        }
        if (completion) completion(ok);
    });
}

#pragma mark - Open Methods

static void openMethod_delegateCall(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 1] Trying delegate call for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    // Try to find UITableView or UICollectionView in VC
    UIScrollView *sv = findScrollViewInView(vc.view);
    if ([sv isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)sv;
        id delegate = tv.delegate;
        NSInteger sections = 1;
        @try { sections = [tv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = 0;
            @try { rows = [tv numberOfRowsInSection:s]; } @catch (NSException *e) {}
            for (NSInteger r = 0; r < rows; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell) {
                        for (UIView *sub in cell.contentView.subviews) {
                            if ([sub isKindOfClass:[UILabel class]]) {
                                UILabel *lbl = (UILabel *)sub;
                                if (lbl.text && [lbl.text containsString:ppName]) {
                                    DLog(@"Found cell with name, calling didSelectRowAtIndexPath");
                                    SEL sel = @selector(tableView:didSelectRowAtIndexPath:);
                                    if (delegate && [delegate respondsToSelector:sel]) {
                                        #pragma clang diagnostic push
                                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                        [delegate performSelector:sel withObject:tv withObject:ip];
                                        #pragma clang diagnostic pop
                                    }
                                    return;
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    } else if ([sv isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)sv;
        id delegate = cv.delegate;
        NSInteger sections = 1;
        @try { sections = [cv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger items = 0;
            @try { items = [cv numberOfItemsInSection:s]; } @catch (NSException *e) {}
            for (NSInteger i = 0; i < items; i++) {
                NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:s];
                @try {
                    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                    if (cell) {
                        for (UIView *sub in cell.contentView.subviews) {
                            if ([sub isKindOfClass:[UILabel class]]) {
                                UILabel *lbl = (UILabel *)sub;
                                if (lbl.text && [lbl.text containsString:ppName]) {
                                    DLog(@"Found collection cell with name, calling didSelectItemAtIndexPath");
                                    SEL sel = @selector(collectionView:didSelectItemAtIndexPath:);
                                    if (delegate && [delegate respondsToSelector:sel]) {
                                        #pragma clang diagnostic push
                                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                                        [delegate performSelector:sel withObject:cv withObject:ip];
                                        #pragma clang diagnostic pop
                                    }
                                    return;
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
    DLog(@"Delegate call: no matching cell found");
}

static void openMethod_vcDirectCall(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 2] Trying VC direct method call for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    NSArray *possibleSelectors = @[
        @"openFile:", @"openFileWithId:", @"previewFile:", @"previewFileWithPath:",
        @"didSelectFile:", @"handleFileTap:", @"fileCellClicked:", @"enterFileDetail:",
        @"showFilePreview:", @"presentFileViewer:", @"routeToFileDetail:",
        @"openDocument:", @"previewDocument:", @"showPreviewForFile:",
        @"handleCellTap:", @"didTapFile:", @"onFileSelected:",
        @"pushFileDetail:", @"presentFileDetail:", @"showFileDetail:",
        @"openFileAtPath:", @"previewFileAtPath:", @"selectFile:",
        @"tapOnFile:", @"clickFile:", @"openItem:",
        @"showDetail:", @"presentDetail:", @"pushDetail:"
    ];

    for (NSString *selName in possibleSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Found VC method: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            @try {
                [vc performSelector:sel withObject:ppName];
                DLog(@"Called %@ with ppName", selName);
                return;
            } @catch (NSException *e) {
                @try {
                    [vc performSelector:sel withObject:filePath];
                    DLog(@"Called %@ with filePath", selName);
                    return;
                } @catch (NSException *e2) {}
            }
            #pragma clang diagnostic pop
        }
    }
    DLog(@"VC direct call: no matching method found");
}

static void openMethod_simulateCellTap(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 3] Trying simulate cell tap for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    UIScrollView *sv = findScrollViewInView(vc.view);
    UIView *targetCell = nil;

    if ([sv isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)sv;
        NSInteger sections = 1;
        @try { sections = [tv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger rows = 0;
            @try { rows = [tv numberOfRowsInSection:s]; } @catch (NSException *e) {}
            for (NSInteger r = 0; r < rows; r++) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:r inSection:s];
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell) {
                        for (UIView *sub in cell.contentView.subviews) {
                            if ([sub isKindOfClass:[UILabel class]]) {
                                UILabel *lbl = (UILabel *)sub;
                                if (lbl.text && [lbl.text containsString:ppName]) {
                                    targetCell = cell;
                                    break;
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}
                if (targetCell) break;
            }
            if (targetCell) break;
        }
    } else if ([sv isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)sv;
        NSInteger sections = 1;
        @try { sections = [cv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger s = 0; s < sections; s++) {
            NSInteger items = 0;
            @try { items = [cv numberOfItemsInSection:s]; } @catch (NSException *e) {}
            for (NSInteger i = 0; i < items; i++) {
                NSIndexPath *ip = [NSIndexPath indexPathForItem:i inSection:s];
                @try {
                    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                    if (cell) {
                        for (UIView *sub in cell.contentView.subviews) {
                            if ([sub isKindOfClass:[UILabel class]]) {
                                UILabel *lbl = (UILabel *)sub;
                                if (lbl.text && [lbl.text containsString:ppName]) {
                                    targetCell = cell;
                                    break;
                                }
                            }
                        }
                    }
                } @catch (NSException *e) {}
                if (targetCell) break;
            }
            if (targetCell) break;
        }
    }

    if (!targetCell) {
        DLog(@"Simulate tap: no visible cell found");
        return;
    }

    DLog(@"Simulating touch on cell: %@", NSStringFromClass([targetCell class]));

    if ([targetCell isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)targetCell;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        DLog(@"Sent UIControl action");
    }

    for (UIGestureRecognizer *gr in targetCell.gestureRecognizers) {
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
            DLog(@"Triggering tap gesture on cell");
            @try {
                SEL sel = NSSelectorFromString(@"_touchesEnded:withEvent:");
                if ([gr respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [gr performSelector:sel withObject:[NSSet set] withObject:nil];
                    #pragma clang diagnostic pop
                }
            } @catch (NSException *e) {
                DLog(@"Gesture trigger failed: %@", e);
            }
        }
    }

    @try {
        for (UIView *sub in targetCell.subviews) {
            if ([sub isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)sub;
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                DLog(@"Triggered button inside cell");
            }
        }
    } @catch (NSException *e) {}

    @try {
        CGPoint center = CGPointMake(targetCell.bounds.size.width / 2.0, targetCell.bounds.size.height / 2.0);
        CGPoint windowPoint = [targetCell convertPoint:center toView:nil];
        [[UIApplication sharedApplication] sendAction:@selector(touchesEnded:withEvent:) to:targetCell from:nil forEvent:nil];
        DLog(@"Sent action via UIApplication");
    } @catch (NSException *e) {}
}

static void openMethod_sendAction(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 4] Trying UIApplication sendAction for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    NSArray *actions = @[@"openFile:", @"previewFile:", @"selectFile:", @"tapFile:", @"clickFile:"];
    for (NSString *action in actions) {
        SEL sel = NSSelectorFromString(action);
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        @try {
            [[UIApplication sharedApplication] sendAction:sel to:vc from:nil forEvent:nil];
            DLog(@"Sent action %@", action);
            return;
        } @catch (NSException *e) {}
        #pragma clang diagnostic pop
    }
    DLog(@"SendAction: no response");
}

static void openMethod_notification(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 5] Trying notification for: %@", ppName);
    NSArray *notifNames = @[
        @"BDPanFileSelectedNotification",
        @"BDPanFileTappedNotification",
        @"kFileSelectedNotification",
        @"kFileTappedNotification",
        @"FileSelectedNotification",
        @"com.baidu.pan.fileSelected",
        @"BDPanFileOpenNotification",
        @"BDPanPreviewFileNotification"
    ];
    NSDictionary *userInfo = @{
        @"fileName": ppName,
        @"filePath": filePath ?: @"",
        @"path": gCurrentPath ?: @"/"
    };
    for (NSString *name in notifNames) {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:userInfo];
    }
    DLog(@"Posted %lu notifications", (unsigned long)notifNames.count);
}

static void openMethod_runtimeSearch(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 6] Trying runtime method search for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList([vc class], &methodCount);
    if (!methods) {
        DLog(@"Runtime search: no methods found");
        return;
    }

    NSArray *keywords = @[@"open", @"preview", @"select", @"tap", @"click", @"file", @"detail", @"show"];
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        BOOL matches = NO;
        for (NSString *kw in keywords) {
            if ([selName containsString:kw]) {
                matches = YES;
                break;
            }
        }
        if (matches && [vc respondsToSelector:sel]) {
            DLog(@"Runtime found method: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            @try {
                [vc performSelector:sel withObject:ppName];
                DLog(@"Called runtime method %@ with ppName", selName);
                free(methods);
                return;
            } @catch (NSException *e) {
                @try {
                    [vc performSelector:sel withObject:filePath];
                    DLog(@"Called runtime method %@ with filePath", selName);
                    free(methods);
                    return;
                } @catch (NSException *e2) {}
            }
            #pragma clang diagnostic pop
        }
    }
    free(methods);
    DLog(@"Runtime search: no matching method responded");
}

static void openMethod_kvoTrigger(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 7] Trying KVO trigger for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    NSArray *propKeys = @[@"selectedFile", @"currentFile", @"fileItem", @"fileModel",
                           @"selectedItem", @"currentItem", @"fileInfo", @"document",
                           @"selectedPath", @"currentPath", @"filePath"];
    for (NSString *key in propKeys) {
        @try {
            id value = [vc valueForKey:key];
            if (value) {
                DLog(@"Found property %@, trying to set filePath", key);
                [vc setValue:filePath forKey:key];
                // Also try to trigger any related method
                NSString *capitalized = [key stringByReplacingCharactersInRange:NSMakeRange(0,1) withString:[[key substringToIndex:1] uppercaseString]];
                NSString *setterName = [NSString stringWithFormat:@"set%@:", capitalized];
                SEL setterSel = NSSelectorFromString(setterName);
                if ([vc respondsToSelector:setterSel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [vc performSelector:setterSel withObject:filePath];
                    #pragma clang diagnostic pop
                }
                return;
            }
        } @catch (NSException *e) {}
    }
    DLog(@"KVO trigger: no matching property");
}

static void openMethod_urlScheme(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 8] Trying URL scheme for: %@", ppName);
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    NSArray *schemes = @[
        [NSString stringWithFormat:@"baidupan://file?path=%@", encodedPath],
        [NSString stringWithFormat:@"baidupan://preview?path=%@", encodedPath],
        [NSString stringWithFormat:@"baidupan://open?path=%@", encodedPath],
        [NSString stringWithFormat:@"baiduwp://file?path=%@", encodedPath],
        [NSString stringWithFormat:@"pan.baidu.com://file?path=%@", encodedPath]
    ];
    for (NSString *scheme in schemes) {
        NSURL *url = [NSURL URLWithString:scheme];
        if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
            DLog(@"Trying URL scheme: %@", scheme);
            if (@available(iOS 10.0, *)) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            } else {
                [[UIApplication sharedApplication] openURL:url];
            }
            return;
        }
    }
    DLog(@"URL scheme: no supported scheme found");
}

static void openMethod_pushVC(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 9] Trying push view controller for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;
    UINavigationController *nav = vc.navigationController;
    if (!nav && [vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    }
    if (!nav) {
        DLog(@"Push VC: no navigation controller");
        return;
    }

    // Try to find file detail VC class
    NSArray *possibleClasses = @[@"BDPanFileDetailVC", @"BDPanPreviewVC", @"BDPanFileViewerVC",
                                    @"FileDetailViewController", @"PreviewViewController",
                                    @"BDPanFileViewController", @"BDPanDocumentVC"];
    for (NSString *className in possibleClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            @try {
                UIViewController *detailVC = [[cls alloc] init];
                if (detailVC) {
                    [detailVC setValue:ppName forKey:@"fileName"];
                    [detailVC setValue:filePath forKey:@"filePath"];
                    [nav pushViewController:detailVC animated:YES];
                    DLog(@"Pushed %@", className);
                    return;
                }
            } @catch (NSException *e) {}
        }
    }
    DLog(@"Push VC: no detail VC class found");
}

static void openMethod_fileIDLookup(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 10] Trying file ID lookup for: %@", ppName);
    if (!gBdstoken) {
        DLog(@"File ID lookup: no token");
        return;
    }
    // Fetch file list and find the file by name, then try to open by fs_id
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files) {
            DLog(@"File ID lookup: fetch failed");
            return;
        }
        for (NSDictionary *file in files) {
            NSString *name = file[@"server_filename"];
            if ([name isEqualToString:ppName]) {
                NSNumber *fsId = file[@"fs_id"];
                DLog(@"Found fs_id: %@ for %@", fsId, ppName);
                // Try to open by fs_id via API or internal method
                UIViewController *vc = topViewController();
                if (vc) {
                    SEL sel = NSSelectorFromString(@"openFileWithId:");
                    if ([vc respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [vc performSelector:sel withObject:[fsId stringValue]];
                        #pragma clang diagnostic pop
                        DLog(@"Called openFileWithId:");
                    }
                }
                return;
            }
        }
        DLog(@"File ID lookup: file not found in list");
    });
}

static void openMethod_downloadDirect(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 11] Trying download direct link for: %@", ppName);
    if (!gBdstoken) {
        DLog(@"Download direct: no token");
        return;
    }
    // Get dlink via API
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&access_token=%@&fsids=[]&dlink=1", gBdstoken];
    // This is a simplified version; in practice you'd need the correct fs_id
    DLog(@"Download direct: would fetch dlink from API");
    showToast(@"方法11: 尝试获取直链...");

    // Alternative: try to open download URL directly
    NSString *downloadUrl = [NSString stringWithFormat:@"https://pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=250528&path=%@", encodedPath];
    NSURL *urlObj = [NSURL URLWithString:downloadUrl];
    if (urlObj) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:urlObj options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:urlObj];
        }
        DLog(@"Opened download URL");
    }
}

static void openMethod_shareSheet(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 12] Trying share sheet for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[ppName, fileURL] applicationActivities:nil];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = vc.view;
        activityVC.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
    }
    [vc presentViewController:activityVC animated:YES completion:nil];
    DLog(@"Presented share sheet");
}

static void openMethod_quickLook(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 13] Trying QuickLook for: %@", ppName);
    // QuickLook requires QLPreviewController which needs proper import
    // We'll try to instantiate it via runtime
    Class qlClass = NSClassFromString(@"QLPreviewController");
    if (!qlClass) {
        DLog(@"QuickLook: QLPreviewController not available");
        return;
    }
    UIViewController *vc = topViewController();
    if (!vc) return;

    @try {
        id previewVC = [[qlClass alloc] init];
        if (previewVC) {
            UINavigationController *nav = vc.navigationController;
            if (nav) {
                [nav pushViewController:previewVC animated:YES];
                DLog(@"Pushed QLPreviewController");
            } else {
                [vc presentViewController:previewVC animated:YES completion:nil];
                DLog(@"Presented QLPreviewController");
            }
        }
    } @catch (NSException *e) {
        DLog(@"QuickLook failed: %@", e);
    }
}

static void openMethod_webView(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 14] Trying WebView for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    Class wkClass = NSClassFromString(@"WKWebView");
    if (!wkClass) {
        wkClass = NSClassFromString(@"UIWebView");
    }
    if (!wkClass) {
        DLog(@"WebView: no webview class available");
        return;
    }

    @try {
        UIView *webView = [[wkClass alloc] initWithFrame:vc.view.bounds];
        if (webView) {
            NSString *encodedPath = strictEncodeURIComponent(filePath);
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://pan.baidu.com/disk/home?path=%@", encodedPath]];
            if ([webView respondsToSelector:@selector(loadRequest:)]) {
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [webView performSelector:@selector(loadRequest:) withObject:req];
                #pragma clang diagnostic pop
            }
            [vc.view addSubview:webView];
            DLog(@"Added WebView");
        }
    } @catch (NSException *e) {
        DLog(@"WebView failed: %@", e);
    }
}

static void openMethod_documentPicker(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 15] Trying document picker for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    Class dpClass = NSClassFromString(@"UIDocumentPickerViewController");
    if (!dpClass) {
        DLog(@"DocumentPicker: class not available");
        return;
    }

    @try {
        NSURL *url = [NSURL fileURLWithPath:filePath];
        id picker = [[dpClass alloc] initWithURL:url inMode:0]; // 0 = UIDocumentPickerModeImport
        if (picker) {
            [vc presentViewController:picker animated:YES completion:nil];
            DLog(@"Presented document picker");
        }
    } @catch (NSException *e) {
        DLog(@"DocumentPicker failed: %@", e);
    }
}

static void openMethod_accessibility(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 16] Trying accessibility for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    UIScrollView *sv = findScrollViewInView(vc.view);
    if (!sv) {
        DLog(@"Accessibility: no scroll view");
        return;
    }

    for (UIView *sub in sv.subviews) {
        if ([sub isKindOfClass:[UITableViewCell class]] || [sub isKindOfClass:[UICollectionViewCell class]]) {
            for (UIView *inner in sub.subviews) {
                if ([inner isKindOfClass:[UILabel class]]) {
                    UILabel *lbl = (UILabel *)inner;
                    if (lbl.text && [lbl.text containsString:ppName]) {
                        if ([sub respondsToSelector:@selector(accessibilityActivate)]) {
                            BOOL activated = [sub accessibilityActivate];
                            DLog(@"Accessibility activate result: %d", activated);
                            return;
                        }
                    }
                }
            }
        }
    }
    DLog(@"Accessibility: no matching accessible element");
}

static void openMethod_responderChain(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 17] Trying responder chain for: %@", ppName);
    UIViewController *vc = topViewController();
    if (!vc) return;

    // Try to send action through responder chain
    SEL sel = NSSelectorFromString(@"openFile:");
    [[UIApplication sharedApplication] sendAction:sel to:nil from:vc forEvent:nil];
    DLog(@"Sent action through responder chain");
}

static void openMethod_customURL(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 18] Trying custom URL for: %@", ppName);
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://pan.baidu.com/disk/home?path=%@", encodedPath]];
    if (url) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
        DLog(@"Opened custom URL");
    }
}

static void openMethod_deepLink(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 19] Trying deep link for: %@", ppName);
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://pan.baidu.com/wap/init?path=%@", encodedPath]];
    if (url) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
        DLog(@"Opened deep link");
    }
}

static void openMethod_fileProvider(NSString *ppName, NSString *filePath) {
    DLog(@"[Method 20] Trying file provider for: %@", ppName);
    // Try to use NSFileProviderManager if available
    Class fpmClass = NSClassFromString(@"NSFileProviderManager");
    if (!fpmClass) {
        DLog(@"FileProvider: NSFileProviderManager not available");
        return;
    }
    DLog(@"FileProvider: would trigger file provider (requires domain setup)");
}

#pragma mark - Method Testing Framework

static void finishAllMethodsAndRestore(void) {
    DLog(@"All methods exhausted, restoring original name...");
    showToast(@"所有方法已尝试，恢复原名...");
    executeRestore();
}

static void showMethodResultDialog(NSString *methodName, NSString *detail) {
    UIViewController *vc = topViewController();
    if (!vc) {
        // If no VC, just continue to next method
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            tryNextOpenMethod();
        });
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"方法 %ld/%lu", (long)(gCurrentMethodIndex + 1), (unsigned long)gOpenMethods.count]
                                                                   message:[NSString stringWithFormat:@"%@\n\n%@", methodName, detail]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *openedAction = [UIAlertAction actionWithTitle:@"✅ 已打开"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
        // User confirmed file opened! Restore name.
        showToast(@"文件已打开，恢复原名...");
        executeRestore();
    }];

    UIAlertAction *notOpenedAction = [UIAlertAction actionWithTitle:@"❌ 没打开"
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction *action) {
        // Try next method
        gCurrentMethodIndex++;
        tryNextOpenMethod();
    }];

    [alert addAction:openedAction];
    [alert addAction:notOpenedAction];

    dispatch_async(dispatch_get_main_queue(), ^{
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

static void tryNextOpenMethod(void) {
    if (!gOpenMethods || gCurrentMethodIndex >= gOpenMethods.count) {
        finishAllMethodsAndRestore();
        return;
    }

    NSDictionary *methodInfo = gOpenMethods[gCurrentMethodIndex];
    NSString *methodName = methodInfo[@"name"];
    NSString *detail = methodInfo[@"detail"];
    NSString *selectorName = methodInfo[@"selector"];

    DLog(@"=== Trying method %ld: %@ ===", (long)(gCurrentMethodIndex + 1), methodName);
    showToast([NSString stringWithFormat:@"尝试方法 %ld/%lu...", (long)(gCurrentMethodIndex + 1), (unsigned long)gOpenMethods.count]);

    // Execute the method
    SEL methodSel = NSSelectorFromString(selectorName);
    if ([self respondsToSelector:methodSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self performSelector:methodSel withObject:gPendingPpName withObject:gPendingFilePath];
        #pragma clang diagnostic pop
    }

    // Show dialog after a short delay to let the method take effect
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showMethodResultDialog(methodName, detail);
    });
}

#pragma mark - Main Flow

static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize) {
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;
    gPendingPpName = nil;
    gPendingFilePath = nil;
    gCurrentMethodIndex = 0;

    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"88888888888888"]) {
        showToast(@"文件已是 .8888888888888888，无需处理");
        return;
    }

    NSString *ppName = [fileName stringByAppendingString:@".8888888888888888"];
    NSString *ppPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName];

    showToast(@"1. 重命名...");
    renameFile(fileId, filePath, ppName, ^(BOOL success, NSError *err) {
        if (!success) {
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }

        gPendingRestoreFileId = fileId;
        gPendingRestorePdfPath = ppPath;
        gPendingRestoreOriginalName = fileName;
        gPendingPpName = ppName;
        gPendingFilePath = filePath;

        // Refresh list
        showToast(@"2. 刷新列表...");
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // Second refresh: reloadData
            UIScrollView *listView = findScrollViewInView(topViewController().view);
            if ([listView isKindOfClass:[UITableView class]]) {
                [(UITableView *)listView reloadData];
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                [(UICollectionView *)listView reloadData];
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                showToast(@"3. 开始测试打开方法...");

                // Initialize method list
                gOpenMethods = @[
                    @{@"name": @"Delegate调用", @"detail": @"调用 tableView/collectionView 的 didSelect 方法", @"selector": @"openMethod_delegateCall:"},
                    @{@"name": @"VC直接方法", @"detail": @"调用当前VC的 openFile/previewFile 等方法", @"selector": @"openMethod_vcDirectCall:"},
                    @{@"name": @"模拟Cell点击", @"detail": @"模拟 touchesBegan/touchesEnded 在可见cell上", @"selector": @"openMethod_simulateCellTap:"},
                    @{@"name": @"UIApplication sendAction", @"detail": @"通过 sendAction:to:from:forEvent: 发送打开事件", @"selector": @"openMethod_sendAction:"},
                    @{@"name": @"Notification发送", @"detail": @"发送百度网盘内部通知触发文件打开", @"selector": @"openMethod_notification:"},
                    @{@"name": @"Runtime方法搜索", @"detail": @"遍历VC所有方法，自动调用含open/preview的方法", @"selector": @"openMethod_runtimeSearch:"},
                    @{@"name": @"KVO触发", @"detail": @"设置 selectedFile/currentFile 属性触发响应", @"selector": @"openMethod_kvoTrigger:"},
                    @{@"name": @"URL Scheme", @"detail": @"通过 baidupan:// 等scheme打开文件", @"selector": @"openMethod_urlScheme:"},
                    @{@"name": @"Push导航", @"detail": @"直接push文件详情页面", @"selector": @"openMethod_pushVC:"},
                    @{@"name": @"文件ID查找", @"detail": @"通过fs_id查找并调用openFileWithId:", @"selector": @"openMethod_fileIDLookup:"},
                    @{@"name": @"下载直链", @"detail": @"获取下载链接并通过浏览器打开", @"selector": @"openMethod_downloadDirect:"},
                    @{@"name": @"ShareSheet", @"detail": @"通过系统分享面板打开", @"selector": @"openMethod_shareSheet:"},
                    @{@"name": @"QuickLook", @"detail": @"通过QLPreviewController预览文件", @"selector": @"openMethod_quickLook:"},
                    @{@"name": @"WebView", @"detail": @"通过内置浏览器打开文件网页", @"selector": @"openMethod_webView:"},
                    @{@"name": @"DocumentPicker", @"detail": @"通过文档选择器打开", @"selector": @"openMethod_documentPicker:"},
                    @{@"name": @"Accessibility", @"detail": @"通过accessibilityActivate激活文件cell", @"selector": @"openMethod_accessibility:"},
                    @{@"name": @"ResponderChain", @"detail": @"通过响应链传递打开事件", @"selector": @"openMethod_responderChain:"},
                    @{@"name": @"CustomURL", @"detail": @"构造文件URL并打开", @"selector": @"openMethod_customURL:"},
                    @{@"name": @"DeepLink", @"detail": @"通过通用链接打开文件", @"selector": @"openMethod_deepLink:"},
                    @{@"name": @"FileProvider", @"detail": @"通过NSFileProviderManager触发", @"selector": @"openMethod_fileProvider:"}
                ];

                gCurrentMethodIndex = 0;
                tryNextOpenMethod();
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();
    if (!gBdstoken) {
        showToast(@"未检测到登录状态");
        return;
    }
    showToast(@"正在获取文件列表...");
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err) {
            DLog(@"fetchFileList error: %@", err);
            showToast([NSString stringWithFormat:@"获取失败: %@", err.localizedDescription]);
            return;
        }
        if (!files || files.count == 0) {
            showToast(@"文件夹为空");
            return;
        }
        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }
        if (fileItems.count == 0) {
            showToast(@"当前文件夹没有可下载的文件");
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                       message:@"选择后自动重命名并测试多种打开方法"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *fid = [file[@"fs_id"] stringValue];
            NSString *path = file[@"path"];
            NSString *title = name;
            if (size) {
                double mb = [size doubleValue] / (1024.0 * 1024.0);
                title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb];
            }
            BOOL isTooLarge = (size && [size doubleValue] >= 300.0 * 1024.0 * 1024.0);
            UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction *action) {
                runSmartFlow(name, path, fid, size);
            }];
            if (isTooLarge) {
                [action setValue:@NO forKey:@"enabled"];
            }
            [sheet addAction:action];
        }
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        [sheet addAction:cancelAction];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = topViewController();
            if (vc) {
                if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                    sheet.popoverPresentationController.sourceView = vc.view;
                    sheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
                }
                [vc presentViewController:sheet animated:YES completion:nil];
            } else {
                DLog(@"No top VC to present action sheet");
                showToast(@"无法弹出选择界面");
            }
        });
    });
}

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = @"missing";
    if (gBdstoken) {
        NSUInteger len = gBdstoken.length;
        NSUInteger previewLen = len > 8 ? 8 : len;
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v11.0"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n新流程：改名->刷新->自动测试20种打开方法", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            triggerDownloadFlow();
        });
    }];
    [alert addAction:downloadAction];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil];
    [alert addAction:okAction];
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
    DLog(@"BaiduPan Troll v11.0 loaded - No-Scroll Multi-Method Edition");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
