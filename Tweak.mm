//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v10.36
//  Flow: select -> rename to .88888888888888 -> REFRESH ONCE -> scroll to file
//        -> restore original name -> AUTO CLICK visible cell
//  CHANGELOG v10.36: Added single refresh after rename to ensure renamed file appears in list
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
static NSTimer *gTapDetectionTimer = nil;
static NSInteger gNavStackCount = 0;
static BOOL gIsWaitingForTap = NO;
static BOOL gHasOpenedFile = NO;
static NSString *gInitialTopVCClass = nil;
static NSString *gInitialTopVCTitle = nil;

static BOOL gHasRestored = NO;
static BOOL gHasClicked = NO;

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
static BOOL viewContainsText(UIView *view, NSString *text);
static void startTapDetection(void);
static void stopTapDetection(void);
static void checkIfFileOpened(void);
static void executeRestore(void);
static void executeRestoreWithoutRefresh(void (^completion)(BOOL success));
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

static UIScrollView * findListViewInHierarchy(UIView *root);
static UIScrollView * findListViewGlobally(void);
static NSIndexPath * searchFileInTableView(NSString *targetName, UITableView *tv);
static NSIndexPath * searchFileInCollectionView(NSString *targetName, UICollectionView *cv);
static void performScrollAttempt(NSString *ppName, UIScrollView *listView, NSInteger attempt, NSInteger maxAttempts, CGFloat scrollStep);
static void scrollToRenamedFileAndAutoClick(NSString *ppName);
static void simulateTouchOnCell(UIView *cell);
static void autoClickVisibleCell(NSString *ppName, UIScrollView *listView);
static void invokeOpenFileMethodOnVC(UIViewController *vc, NSString *fileName, NSString *filePath);
static NSString * topVCClassName(void);
static NSString * topVCTitle(void);

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

static BOOL viewContainsText(UIView *view, NSString *text) {
    if (!view || !text) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (lbl.text && [lbl.text containsString:text]) return YES;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        if (btn.currentTitle && [btn.currentTitle containsString:text]) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (viewContainsText(sub, text)) return YES;
    }
    return NO;
}

static UIScrollView * findListViewInHierarchy(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UITableView class]] || [root isKindOfClass:[UICollectionView class]]) {
        return (UIScrollView *)root;
    }
    for (UIView *sub in root.subviews) {
        UIScrollView *found = findListViewInHierarchy(sub);
        if (found) return found;
    }
    return nil;
}

static UIScrollView * findListViewGlobally(void) {
    UIViewController *vc = topViewController();
    if (vc) {
        UIScrollView *found = findListViewInHierarchy(vc.view);
        if (found) return found;
    }
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        UIScrollView *found = findListViewInHierarchy(window);
        if (found) return found;
    }
    return nil;
}

static NSIndexPath * searchFileInTableView(NSString *targetName, UITableView *tv) {
    if (!targetName || !tv) return nil;
    NSInteger totalSections = 1;
    @try { totalSections = [tv numberOfSections]; } @catch (NSException *e) {}

    for (NSInteger section = 0; section < totalSections; section++) {
        NSInteger rows = 0;
        @try { rows = [tv numberOfRowsInSection:section]; } @catch (NSException *e) {}

        for (NSInteger row = rows - 1; row >= 0; row--) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
            @try {
                UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                if (!cell) continue;
                if (viewContainsText(cell, targetName)) {
                    DLog(@"Found cell at row %ld, section %ld", (long)row, (long)section);
                    return ip;
                }
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

static NSIndexPath * searchFileInCollectionView(NSString *targetName, UICollectionView *cv) {
    if (!targetName || !cv) return nil;
    NSInteger totalSections = 1;
    @try { totalSections = [cv numberOfSections]; } @catch (NSException *e) {}

    for (NSInteger section = 0; section < totalSections; section++) {
        NSInteger items = 0;
        @try { items = [cv numberOfItemsInSection:section]; } @catch (NSException *e) {}

        for (NSInteger item = items - 1; item >= 0; item--) {
            NSIndexPath *ip = [NSIndexPath indexPathForItem:item inSection:section];
            @try {
                UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                if (!cell) continue;
                if (viewContainsText(cell, targetName)) {
                    DLog(@"Found collection cell at item %ld, section %ld", (long)item, (long)section);
                    return ip;
                }
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

static void simulateTouchOnCell(UIView *cell) {
    if (!cell) return;
    DLog(@"Simulating touch on visible cell: %@", NSStringFromClass([cell class]));

    if ([cell isKindOfClass:[UIControl class]]) {
        UIControl *control = (UIControl *)cell;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        DLog(@"Sent UIControl action");
    }

    for (UIGestureRecognizer *gr in cell.gestureRecognizers) {
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
        for (UIView *sub in cell.subviews) {
            if ([sub isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)sub;
                [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                DLog(@"Triggered button inside cell");
            }
        }
    } @catch (NSException *e) {}

    @try {
        CGPoint center = CGPointMake(cell.bounds.size.width / 2.0, cell.bounds.size.height / 2.0);
        CGPoint windowPoint = [cell convertPoint:center toView:nil];
        [[UIApplication sharedApplication] sendAction:@selector(touchesEnded:withEvent:) to:cell from:nil forEvent:nil];
        DLog(@"Sent action via UIApplication");
    } @catch (NSException *e) {}
}

static void autoClickVisibleCell(NSString *ppName, UIScrollView *listView) {
    if (!ppName || !listView) return;

    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        foundPath = searchFileInTableView(ppName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
    }

    if (!foundPath) {
        DLog(@"Cell still not visible after scroll, will retry...");
        return;
    }

    if (!gHasRestored && gPendingRestoreFileId && gPendingRestorePdfPath && gPendingRestoreOriginalName) {
        gHasRestored = YES;
        showToast(@"4. 恢复原名...");
        executeRestoreWithoutRefresh(^(BOOL success) {
            if (success) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    showToast(@"5. 自动打开文件...");
                    autoClickVisibleCell(ppName, listView);
                });
            } else {
                showToast(@"恢复原名失败，取消自动打开");
            }
        });
        return;
    }

    if (gHasClicked) {
        DLog(@"Already clicked, skipping duplicate");
        return;
    }
    gHasClicked = YES;

    UIView *visibleCell = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        visibleCell = [(UITableView *)listView cellForRowAtIndexPath:foundPath];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        visibleCell = [(UICollectionView *)listView cellForItemAtIndexPath:foundPath];
    }

    if (!visibleCell) {
        DLog(@"Cell at path %@ is not visible (returns nil), cannot click", foundPath);
        gHasClicked = NO;
        return;
    }

    DLog(@"Cell is VISIBLE, proceeding with auto-click");
    showToast(@"正在自动打开文件...");

    id delegate = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        delegate = [(UITableView *)listView delegate];
        SEL didSelect = @selector(tableView:didSelectRowAtIndexPath:);
        if (delegate && [delegate respondsToSelector:didSelect]) {
            DLog(@"Calling tableView:didSelectRowAtIndexPath:");
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:didSelect withObject:listView withObject:foundPath];
            #pragma clang diagnostic pop
        }
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        delegate = [(UICollectionView *)listView delegate];
        SEL didSelect = @selector(collectionView:didSelectItemAtIndexPath:);
        if (delegate && [delegate respondsToSelector:didSelect]) {
            DLog(@"Calling collectionView:didSelectItemAtIndexPath:");
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:didSelect withObject:listView withObject:foundPath];
            #pragma clang diagnostic pop
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        simulateTouchOnCell(visibleCell);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = topViewController();
        invokeOpenFileMethodOnVC(vc, ppName, gPendingRestorePdfPath);
    });
}

static void invokeOpenFileMethodOnVC(UIViewController *vc, NSString *fileName, NSString *filePath) {
    if (!vc) return;

    NSArray *possibleSelectors = @[
        @"openFile:", @"openFileWithId:", @"previewFile:", @"previewFileWithPath:",
        @"didSelectFile:", @"handleFileTap:", @"fileCellClicked:", @"enterFileDetail:",
        @"showFilePreview:", @"presentFileViewer:", @"routeToFileDetail:",
        @"openDocument:", @"previewDocument:", @"showPreviewForFile:",
        @"handleCellTap:", @"didTapFile:", @"onFileSelected:",
        @"pushFileDetail:", @"presentFileDetail:", @"showFileDetail:"
    ];

    for (NSString *selName in possibleSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Found open file method: %@ on %@", selName, NSStringFromClass([vc class]));
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            @try {
                [vc performSelector:sel withObject:fileName];
                DLog(@"Called %@ with fileName", selName);
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

    NSArray *filePropKeys = @[@"selectedFile", @"currentFile", @"fileItem", @"fileModel",
                               @"selectedItem", @"currentItem", @"fileInfo", @"document"];
    for (NSString *key in filePropKeys) {
        @try {
            id fileObj = [vc valueForKey:key];
            if (fileObj) {
                for (NSString *selName in possibleSelectors) {
                    SEL sel = NSSelectorFromString(selName);
                    if ([vc respondsToSelector:sel]) {
                        DLog(@"Calling %@ with %@ object", selName, key);
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [vc performSelector:sel withObject:fileObj];
                        #pragma clang diagnostic pop
                        return;
                    }
                }
            }
        } @catch (NSException *e) {}
    }

    DLog(@"No internal open file method found on %@", NSStringFromClass([vc class]));
}

static void performScrollAttempt(NSString *ppName, UIScrollView *listView, NSInteger attempt, NSInteger maxAttempts, CGFloat scrollStep) {
    if (attempt >= maxAttempts) {
        DLog(@"Max scroll attempts reached");
        showToast(@"未找到文件，请手动查找");
        return;
    }

    CGFloat currentY = listView.contentOffset.y;
    CGFloat targetY = currentY + scrollStep;
    CGFloat maxY = listView.contentSize.height - listView.bounds.size.height;
    if (maxY < 0) maxY = 0;
    if (targetY > maxY) targetY = maxY;

    DLog(@"Scroll attempt %ld: %.0f -> %.0f (max %.0f)", (long)attempt, currentY, targetY, maxY);

    if (targetY <= currentY && attempt > 0) {
        DLog(@"Already at bottom, stopping scroll");
        showToast(@"已滚动到底部，未找到文件");
        return;
    }

    listView.contentOffset = CGPointMake(0, targetY);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoClickVisibleCell(ppName, listView);

        NSIndexPath *foundPath = nil;
        if ([listView isKindOfClass:[UITableView class]]) {
            foundPath = searchFileInTableView(ppName, (UITableView *)listView);
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
        }

        if (foundPath) {
            DLog(@"File found at attempt %ld, cell should be visible now", (long)attempt);
            return;
        }

        if (targetY >= maxY && maxY >= 0) {
            showToast(@"已滚动到底部，未找到文件");
            return;
        }

        showToast([NSString stringWithFormat:@"继续查找... (%ld/%ld)", (long)(attempt + 1), (long)maxAttempts]);
        performScrollAttempt(ppName, listView, attempt + 1, maxAttempts, scrollStep);
    });
}

static void scrollToRenamedFileAndAutoClick(NSString *ppName) {
    if (!ppName) return;
    DLog(@"v10.36 Scrolling to file and auto-click: %@", ppName);

    UIScrollView *listView = findListViewGlobally();
    if (!listView) {
        DLog(@"No list view found globally");
        showToast(@"未找到文件列表");
        return;
    }
    DLog(@"Found list view: %@", NSStringFromClass([listView class]));

    // Try to find and click the file in current visible area first
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        foundPath = searchFileInTableView(ppName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
    }

    if (foundPath) {
        DLog(@"File already visible, scrolling to position and auto-clicking...");
        if ([listView isKindOfClass:[UITableView class]]) {
            [(UITableView *)listView scrollToRowAtIndexPath:foundPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)listView scrollToItemAtIndexPath:foundPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            autoClickVisibleCell(ppName, listView);
        });
        return;
    }

    // If not found in visible area, start scroll search
    DLog(@"File not visible, starting scroll search...");
    showToast(@"正在查找并自动打开文件...");

    listView.contentOffset = CGPointZero;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGFloat scrollStep = listView.bounds.size.height * 0.7;
        if (scrollStep < 100) scrollStep = 100;
        performScrollAttempt(ppName, listView, 0, 15, scrollStep);
    });
}

static NSString * topVCClassName(void) {
    UIViewController *vc = topViewController();
    return vc ? NSStringFromClass([vc class]) : @"nil";
}

static NSString * topVCTitle(void) {
    UIViewController *vc = topViewController();
    if (!vc) return @"nil";
    NSString *title = vc.title;
    if (!title || title.length == 0) title = vc.navigationItem.title;
    return title ?: @"nil";
}

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        stopTapDetection();
        return;
    }
    DLog(@"Executing restore: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            showToast(@"✅ 已自动恢复原名");
        } else {
            showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]);
        }
        gPendingRestoreFileId = nil;
        gPendingRestorePdfPath = nil;
        gPendingRestoreOriginalName = nil;
        gIsWaitingForTap = NO;
        gHasOpenedFile = NO;
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

static void stopTapDetection(void) {
    if (gTapDetectionTimer) {
        [gTapDetectionTimer invalidate];
        gTapDetectionTimer = nil;
    }
    gIsWaitingForTap = NO;
    gHasOpenedFile = NO;
}

static void checkIfFileOpened(void) {
    if (!gIsWaitingForTap) return;

    NSInteger currentCount = currentNavStackCount();
    NSString *currentClass = topVCClassName();
    NSString *currentTitle = topVCTitle();

    DLog(@"Tap detection: nav=%ld->%ld class=[%@]->[%@] title=[%@]->[%@] hasOpened=%d",
         (long)gNavStackCount, (long)currentCount,
         gInitialTopVCClass, currentClass,
         gInitialTopVCTitle, currentTitle, gHasOpenedFile);

    if (!gHasOpenedFile) {
        BOOL opened = NO;

        if (currentCount > gNavStackCount) {
            DLog(@"File opened (nav stack increased)!");
            opened = YES;
        } else if (gInitialTopVCClass && ![gInitialTopVCClass isEqualToString:currentClass]) {
            DLog(@"File opened (VC class changed)!");
            opened = YES;
        } else if (currentTitle && ([currentTitle containsString:@"预览"] || [currentTitle containsString:@"下载"] || [currentTitle containsString:@"文件详情"])) {
            DLog(@"File opened (preview title)!");
            opened = YES;
        } else if (gPendingRestoreOriginalName && currentTitle && [currentTitle containsString:gPendingRestoreOriginalName]) {
            DLog(@"File opened (title matches file name)!");
            opened = YES;
        }

        if (opened) {
            gHasOpenedFile = YES;
            showToast(@"已进入下载界面，马上恢复原名...");

            if (gTapDetectionTimer) {
                [gTapDetectionTimer invalidate];
                gTapDetectionTimer = nil;
            }

            executeRestore();
            return;
        }
    }
}

static void startTapDetection(void) {
    stopTapDetection();
    gIsWaitingForTap = YES;
    gHasOpenedFile = NO;
    gNavStackCount = currentNavStackCount();
    gInitialTopVCClass = topVCClassName();
    gInitialTopVCTitle = topVCTitle();
    DLog(@"Started tap detection, nav=%ld class=%@ title=%@", (long)gNavStackCount, gInitialTopVCClass, gInitialTopVCTitle);

    gTapDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                            target:[NSBlockOperation blockOperationWithBlock:^{
                                                                checkIfFileOpened();
                                                            }]
                                                          selector:@selector(main)
                                                          userInfo:nil
                                                           repeats:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gIsWaitingForTap) {
            DLog(@"Tap detection timeout, forcing restore");
            stopTapDetection();
            showToast(@"等待超时，自动恢复原名");
            executeRestore();
        }
    });
}

// v10.36: rename -> refresh once -> scroll -> restore -> auto click
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize) {
    stopTapDetection();
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;
    gHasRestored = NO;
    gHasClicked = NO;

    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"88888888888888"]) {
        showToast(@"文件已是 .8888888888888888，无需处理");
        return;
    }

    NSString *ppName = [fileName stringByAppendingString:@".8888888888888888"];
    NSString *ppPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName];
    NSString *ppName2 = [ppName stringByAppendingString:@".1"];
    NSString *ppPath2 = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName2];

    showToast(@"1. 第一次重命名...");
    renameFile(fileId, filePath, ppName, ^(BOOL success, NSError *err) {
        if (!success) {
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }

        gPendingRestoreFileId = fileId;
        gPendingRestorePdfPath = ppPath;
        gPendingRestoreOriginalName = fileName;

        // 不刷新，等待后直接用原始文件名查找
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showToast(@"2. 查找文件...");
            UIScrollView *listView = findListViewGlobally();
            if (!listView) {
                showToast(@"未找到文件列表");
                return;
            }

            NSIndexPath *foundPath = nil;
            if ([listView isKindOfClass:[UITableView class]]) {
                foundPath = searchFileInTableView(fileName, (UITableView *)listView);
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                foundPath = searchFileInCollectionView(fileName, (UICollectionView *)listView);
            }

            if (foundPath) {
                DLog(@"File found after first rename");
                showToast(@"3. 恢复原名...");
                executeRestoreWithoutRefresh(^(BOOL restoreSuccess) {
                    if (restoreSuccess) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            showToast(@"4. 自动打开文件...");
                            autoClickVisibleCell(fileName, listView);
                            startTapDetection();
                        });
                    } else {
                        showToast(@"恢复原名失败");
                    }
                });
                return;
            }

            // 第一次没找到，执行第二次改名
            DLog(@"File not found after first rename, doing second rename...");
            showToast(@"3. 第二次重命名...");
            renameFile(fileId, ppPath, ppName2, ^(BOOL success2, NSError *err2) {
                if (!success2) {
                    showToast([NSString stringWithFormat:@"第二次重命名失败: %@", err2.localizedDescription]);
                    return;
                }

                // 更新 pending 为第二次改名的路径
                gPendingRestorePdfPath = ppPath2;

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    showToast(@"4. 再次查找...");
                    NSIndexPath *foundPath2 = nil;
                    if ([listView isKindOfClass:[UITableView class]]) {
                        foundPath2 = searchFileInTableView(ppName2, (UITableView *)listView);
                    } else if ([listView isKindOfClass:[UICollectionView class]]) {
                        foundPath2 = searchFileInCollectionView(ppName2, (UICollectionView *)listView);
                    }

                    if (foundPath2) {
                        DLog(@"File found after second rename");
                        showToast(@"5. 恢复原名...");
                        // 恢复时从 ppPath2 恢复到 original
                        renameFile(fileId, ppPath2, fileName, ^(BOOL restoreOk, NSError *restoreErr) {
                            if (restoreOk) {
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    showToast(@"6. 自动打开文件...");
                                    autoClickVisibleCell(fileName, listView);
                                    startTapDetection();
                                });
                            } else {
                                showToast(@"恢复原名失败");
                            }
                            gPendingRestoreFileId = nil;
                            gPendingRestorePdfPath = nil;
                            gPendingRestoreOriginalName = nil;
                        });
                    } else {
                        DLog(@"File still not found after second rename, scroll to find");
                        showToast(@"未找到，滚动查找...");
                        scrollToRenamedFileAndAutoClick(ppName2);
                    }
                });
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
                                                                       message:@"选择后自动重命名并快速打开"
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v10.36"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n快速流程：改名->刷新->滚动->恢复原名->自动点击", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
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
    DLog(@"BaiduPan Troll v10.36 loaded - Double Rename Edition");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
