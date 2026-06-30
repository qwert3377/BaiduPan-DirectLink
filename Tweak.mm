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

