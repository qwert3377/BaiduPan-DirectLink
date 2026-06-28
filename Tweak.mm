//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v8.6.0
//  Feature: Minimal auto-download flow
//    1. Select file (keep action sheet)
//    2. Auto-rename to .pdf
//    3. Auto-refresh file list
//    4. Poll for renamed file
//    5. Auto-find cell & simulate tap to trigger native download
//    6. Auto-restore original filename after delay
//  Security: Operation lock, timeout protection, auto-rollback, safer memory scan
//  Stability: Robust cell finding, decoupled from internal download APIs
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// Operation lock to prevent duplicate execution
static BOOL gIsProcessing = NO;
static NSTimer *gAutoRestoreTimer = nil;
static NSString *gPendingRestoreFileId = nil;
static NSString *gPendingRestorePdfPath = nil;
static NSString *gPendingRestoreOriginalName = nil;

// ========== Forward declarations ==========
static UIViewController * topViewController(void);
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
static void simulatePullToRefreshOnScrollView(UIScrollView *scrollView);
static void pollForFileExistence(NSString *expectedPath, NSString *fileId, NSString *originalName, NSInteger attempt, void (^completion)(BOOL found, NSError *err));
static void runMinimalAutoDownloadFlow(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);
static void cancelPendingRestore(void);
static void scheduleAutoRestore(NSString *fileId, NSString *pdfPath, NSString *originalName);
static void executeAutoRestore(void);

// Cell finding & simulation
static UITableView * findTableViewInHierarchy(UIView *view);
static UICollectionView * findCollectionViewInHierarchy(UIView *view);
static UIView * findCellContainingText(UIView *view, NSString *text);
static void simulateTapOnView(UIView *targetView);
static void autoFindAndTapFileCell(NSString *fileName, NSInteger retryCount, void (^completion)(BOOL success, NSError *err));

// ========== Implementations ==========

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

// Safer memory scan with length validation and key filtering
static NSString * scanMemoryForBdstoken(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    NSString *bestToken = nil;
    NSString *bestKey = nil;

    // Known safe keys to check first
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

    // Fallback: scan all keys but avoid suspicious ones
    NSArray *blacklistKeys = @[@"password", @"passwd", @"secret", @"credit", @"card", @"phone", @"mobile", @"email", @"address"];
    for (NSString *key in allDefaults) {
        // Skip blacklisted keys for security
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
    if (path && path.length > 0 && ![path isEqualToString:@"/"]) {
        DLog(@"Path from current VC property: %@", path);
        return path;
    }

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

    if (nav) {
        UIViewController *topVC = nav.topViewController;
        NSString *topPath = extractPathFromVC(topVC);
        if (topPath && topPath.length > 0 && ![topPath isEqualToString:@"/"]) {
            DLog(@"Path from nav topVC property: %@", topPath);
            return topPath;
        }

        NSArray *vcs = nav.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            NSString *p = extractPathFromVC(vcs[i]);
            if (p && p.length > 0 && ![p isEqualToString:@"/"]) {
                DLog(@"Path from nav stack[%ld] property: %@", (long)i, p);
                return p;
            }
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
            DLog(@"Path from title concatenation: %@", fullPath);
            return fullPath;
        }
    }

    DLog(@"Could not determine path from VC hierarchy");
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
    if (!gBdstoken) DLog(@"WARNING: No token detected from app");

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
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token detected. Please ensure you are logged in."}]);
        return;
    }
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100", encodedPath, gBdstoken];
    DLog(@"fetchFileList URL: %@", url);
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

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!gBdstoken) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=rename&clienttype=0&app_id=250528&web=1&bdstoken=%@", gBdstoken];
    NSString *filelist = [NSString stringWithFormat:@"[{\"id\":%@,\"path\":\"%@\",\"newname\":\"%@\"}]", fileId, path, newName];
    NSString *body = [NSString stringWithFormat:@"filelist=%@", strictEncodeURIComponent(filelist)];
    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded; charset=UTF-8",
        @"X-Requested-With": @"XMLHttpRequest"
    };
    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) { completion(NO, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"Unknown error";
            completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
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

    // Remove existing toast if any
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
    toast.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
    });
}

// ========== Auto-restore safety mechanism ==========

static void cancelPendingRestore(void) {
    if (gAutoRestoreTimer) {
        [gAutoRestoreTimer invalidate];
        gAutoRestoreTimer = nil;
    }
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;
}

static void executeAutoRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        cancelPendingRestore();
        return;
    }
    DLog(@"Executing auto-restore: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            showToast(@"已自动恢复原文件名");
            forceRefreshFileList();
        } else {
            DLog(@"Auto-restore failed: %@", e.localizedDescription);
            showToast(@"自动恢复原名失败，请手动修改");
        }
        cancelPendingRestore();
    });
}

static void scheduleAutoRestore(NSString *fileId, NSString *pdfPath, NSString *originalName) {
    cancelPendingRestore();
    gPendingRestoreFileId = fileId;
    gPendingRestorePdfPath = pdfPath;
    gPendingRestoreOriginalName = originalName;
    // Auto-restore after 15 seconds to ensure download has started
    gAutoRestoreTimer = [NSTimer scheduledTimerWithTimeInterval:15.0
                                                         target:[NSBlockOperation blockOperationWithBlock:^{
                                                             executeAutoRestore();
                                                         }]
                                                       selector:@selector(main)
                                                       userInfo:nil
                                                        repeats:NO];
}

// ========== Refresh mechanism ==========

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
        DLog(@"Triggered MJRefresh beginRefreshing");
    }
    if ([headerOrFooter respondsToSelector:executeSel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [headerOrFooter performSelector:executeSel];
        #pragma clang diagnostic pop
    }
}

static void triggerNotificationFallback(void) {
    DLog(@"Falling back to notification broadcast");
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
    DLog(@"Simulating full pull-to-refresh gesture");
    CGPoint originalOffset = scrollView.contentOffset;

    SEL willBeginDragging = @selector(scrollViewWillBeginDragging:);
    if (scrollView.delegate && [scrollView.delegate respondsToSelector:willBeginDragging]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [scrollView.delegate performSelector:willBeginDragging withObject:scrollView];
        #pragma clang diagnostic pop
    }

    [scrollView setContentOffset:CGPointMake(originalOffset.x, -150) animated:NO];

    SEL didScroll = @selector(scrollViewDidScroll:);
    if (scrollView.delegate && [scrollView.delegate respondsToSelector:didScroll]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [scrollView.delegate performSelector:didScroll withObject:scrollView];
        #pragma clang diagnostic pop
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                scrollView.contentOffset = originalOffset;
            }];
        });
    });
}

static void tryRefreshOnScrollView(UIScrollView *scrollView) {
    if (!scrollView) return;

    if (scrollView.refreshControl) {
        DLog(@"Triggering UIRefreshControl");
        [scrollView.refreshControl beginRefreshing];
        CGPoint offset = scrollView.contentOffset;
        [UIView animateWithDuration:0.25 animations:^{
            scrollView.contentOffset = CGPointMake(offset.x, -scrollView.refreshControl.frame.size.height);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        DLog(@"Calling reloadData on UITableView");
        [(UITableView *)vc.view reloadData];
        return;
    }
    if ([vc.view isKindOfClass:[UICollectionView class]]) {
        DLog(@"Calling reloadData on UICollectionView");
        [(UICollectionView *)vc.view reloadData];
        return;
    }

    UIScrollView *sv = findScrollViewInView(vc.view);
    if (sv) {
        DLog(@"Found scrollView in %@, trying refresh", NSStringFromClass([vc class]));
        tryRefreshOnScrollView(sv);
        return;
    }

    if ([vc isKindOfClass:[UINavigationController class]]) {
        for (UIViewController *child in [(UINavigationController *)vc viewControllers]) {
            refreshVC(child);
        }
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)vc viewControllers]) {
            refreshVC(child);
        }
    } else if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in [(UISplitViewController *)vc viewControllers]) {
            refreshVC(child);
        }
    }

    refreshVC(vc.presentedViewController);
}

static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) { DLog(@"No top VC for refresh"); return; }

    DLog(@"Attempting refresh on top VC: %@", NSStringFromClass([vc class]));
    refreshVC(vc);

    DLog(@"Trying all windows...");
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        if (window.rootViewController && window.rootViewController != vc) {
            refreshVC(window.rootViewController);
        }
    }

    triggerNotificationFallback();
}

// ========== Polling ==========

static void pollForFileExistence(NSString *expectedPath, NSString *fileId, NSString *originalName, NSInteger attempt, void (^completion)(BOOL found, NSError *err)) {
    if (attempt > 20) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"轮询超时：刷新后仍未找到文件"}]);
        return;
    }
    DLog(@"pollForFileExistence attempt %ld, expected: %@", (long)attempt, expectedPath);
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100", encodedPath, gBdstoken];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            DLog(@"pollForFileExistence error: %@", err.localizedDescription);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                pollForFileExistence(expectedPath, fileId, originalName, attempt + 1, completion);
            });
            return;
        }
        NSArray *list = json[@"list"];
        if ([list isKindOfClass:[NSArray class]]) {
            for (NSDictionary *file in list) {
                NSString *path = file[@"path"];
                if ([path isEqualToString:expectedPath]) {
                    DLog(@"pollForFileExistence: found %@", expectedPath);
                    completion(YES, nil);
                    return;
                }
            }
        }
        DLog(@"pollForFileExistence: not found yet, retrying...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            pollForFileExistence(expectedPath, fileId, originalName, attempt + 1, completion);
        });
    });
}

// ========== Cell Finding & Tap Simulation ==========

static UITableView * findTableViewInHierarchy(UIView *view) {
    if ([view isKindOfClass:[UITableView class]]) return (UITableView *)view;
    for (UIView *sub in view.subviews) {
        UITableView *found = findTableViewInHierarchy(sub);
        if (found) return found;
    }
    return nil;
}

static UICollectionView * findCollectionViewInHierarchy(UIView *view) {
    if ([view isKindOfClass:[UICollectionView class]]) return (UICollectionView *)view;
    for (UIView *sub in view.subviews) {
        UICollectionView *found = findCollectionViewInHierarchy(sub);
        if (found) return found;
    }
    return nil;
}

static UIView * findCellContainingText(UIView *view, NSString *text) {
    if (!view || !text) return nil;

    // Check if this view itself is a cell containing the text
    if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) {
        NSString *viewText = nil;
        if ([view isKindOfClass:[UITableViewCell class]]) {
            viewText = [(UITableViewCell *)view textLabel].text;
            if (!viewText) viewText = [(UITableViewCell *)view detailTextLabel].text;
        }
        // Try to find any UILabel with matching text inside this cell
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                UILabel *lbl = (UILabel *)sub;
                if (lbl.text && [lbl.text containsString:text]) return view;
            }
            // Deep search one more level for labels
            for (UIView *ss in sub.subviews) {
                if ([ss isKindOfClass:[UILabel class]]) {
                    UILabel *lbl = (UILabel *)ss;
                    if (lbl.text && [lbl.text containsString:text]) return view;
                }
            }
        }
    }

    // Recurse
    for (UIView *sub in view.subviews) {
        UIView *found = findCellContainingText(sub, text);
        if (found) return found;
    }
    return nil;
}

static void simulateTapOnView(UIView *targetView) {
    if (!targetView) return;
    DLog(@"Simulating tap on view: %@", NSStringFromClass([targetView class]));

    CGPoint center = CGPointMake(targetView.bounds.size.width / 2, targetView.bounds.size.height / 2);

    // Method 1: Try to find a gesture recognizer and trigger it
    for (UIGestureRecognizer *gesture in targetView.gestureRecognizers) {
        if ([gesture isKindOfClass:[UITapGestureRecognizer class]]) {
            gesture.enabled = YES;
            [gesture setValue:@(UIGestureRecognizerStateBegan) forKey:@"state"];
            [gesture setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
            DLog(@"Triggered UITapGestureRecognizer");
            return;
        }
    }

    // Method 2: Send touch events
    SEL touchesBegan = @selector(touchesBegan:withEvent:);
    SEL touchesEnded = @selector(touchesEnded:withEvent:);

    @try {
        UITouch *touch = [[UITouch alloc] init];
        // Use KVC to configure the touch (private, but works in TrollStore environment)
        [touch setValue:@(1) forKey:@"tapCount"];
        [touch setValue:targetView.window forKey:@"window"];
        [touch setValue:targetView forKey:@"view"];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];

        CGPoint locInWindow = [targetView convertPoint:center toView:targetView.window];
        [touch setValue:[NSValue valueWithCGPoint:locInWindow] forKey:@"locationInWindow"];
        [touch setValue:[NSValue valueWithCGPoint:locInWindow] forKey:@"previousLocationInWindow"];

        UIEvent *event = [[UIApplication sharedApplication] performSelector:@selector(_touchesEvent)];
        if (event) {
            [event setValue:touch forKey:@"_firstTouchForView"];
            [event setValue:touch forKey:@"_allTouches"];
        }

        NSSet *touches = [NSSet setWithObject:touch];
        if ([targetView respondsToSelector:touchesBegan]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [targetView performSelector:touchesBegan withObject:touches withObject:event];
            #pragma clang diagnostic pop
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            if ([targetView respondsToSelector:touchesEnded]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [targetView performSelector:touchesEnded withObject:touches withObject:event];
                #pragma clang diagnostic pop
            }
        });
        DLog(@"Sent touch events to target view");
    } @catch (NSException *e) {
        DLog(@"Touch simulation exception: %@", e.reason);
    }

    // Method 3: If it's a table/collection cell, try select it via the data source controller
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([targetView isKindOfClass:[UITableViewCell class]]) {
            UITableViewCell *cell = (UITableViewCell *)targetView;
            UITableView *tv = findTableViewInHierarchy(targetView.superview);
            if (tv && [tv.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                NSIndexPath *ip = [tv indexPathForCell:cell];
                if (ip) {
                    [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone];
                    [tv.delegate tableView:tv didSelectRowAtIndexPath:ip];
                    DLog(@"Triggered tableView:didSelectRowAtIndexPath:");
                }
            }
        } else if ([targetView isKindOfClass:[UICollectionViewCell class]]) {
            UICollectionViewCell *cell = (UICollectionViewCell *)targetView;
            UICollectionView *cv = findCollectionViewInHierarchy(targetView.superview);
            if (cv && [cv.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                NSIndexPath *ip = [cv indexPathForCell:cell];
                if (ip) {
                    [cv selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionNone];
                    [cv.delegate collectionView:cv didSelectItemAtIndexPath:ip];
                    DLog(@"Triggered collectionView:didSelectItemAtIndexPath:");
                }
            }
        }
    });
}

static void autoFindAndTapFileCell(NSString *fileName, NSInteger retryCount, void (^completion)(BOOL success, NSError *err)) {
    if (retryCount > 15) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"无法找到重命名后的文件Cell"}]);
        return;
    }

    DLog(@"autoFindAndTapFileCell attempt %ld for: %@", (long)retryCount, fileName);

    UIViewController *vc = topViewController();
    if (!vc) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-12 userInfo:@{NSLocalizedDescriptionKey: @"无法获取当前视图控制器"}]);
        return;
    }

    // First try to find cell by exact file name
    UIView *cell = findCellContainingText(vc.view, fileName);

    if (cell) {
        DLog(@"Found cell for %@, simulating tap...", fileName);
        simulateTapOnView(cell);
        completion(YES, nil);
        return;
    }

    // Not found yet, maybe list hasn't updated, retry after delay
    DLog(@"Cell not found yet, retrying in 0.5s...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoFindAndTapFileCell(fileName, retryCount + 1, completion);
    });
}

// ========== Minimal Auto-Download Flow ==========

static void runMinimalAutoDownloadFlow(NSString *fileName, NSString *filePath, NSString *fileId) {
    if (gIsProcessing) {
        showToast(@"正在处理中，请稍候...");
        return;
    }
    gIsProcessing = YES;

    NSString *ext = fileName.pathExtension.lowercaseString;
    BOOL isAlreadyPDF = [ext isEqualToString:@"pdf"];

    if (isAlreadyPDF) {
        DLog(@"File is already PDF, skipping rename, direct tap...");
        showToast(@"文件已是PDF，直接触发下载...");
        autoFindAndTapFileCell(fileName, 0, ^(BOOL success, NSError *err) {
            gIsProcessing = NO;
            if (!success) {
                showToast([NSString stringWithFormat:@"触发下载失败: %@", err.localizedDescription]);
            } else {
                showToast(@"已触发下载！");
            }
        });
        return;
    }

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    showToast(@"1. 正在重命名...");

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            gIsProcessing = NO;
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }

        DLog(@"Renamed to %@, triggering refresh...", pdfName);
        showToast(@"2. 重命名成功，刷新列表...");
        forceRefreshFileList();

        // Schedule auto-restore in case user kills app or something goes wrong
        scheduleAutoRestore(fileId, pdfPath, fileName);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showToast(@"3. 等待文件列表同步...");
            pollForFileExistence(pdfPath, fileId, fileName, 0, ^(BOOL found, NSError *pollErr) {
                if (!found) {
                    gIsProcessing = NO;
                    executeAutoRestore(); // Try to restore immediately
                    showToast([NSString stringWithFormat:@"同步失败: %@", pollErr.localizedDescription]);
                    return;
                }

                showToast(@"4. 正在触发下载...");
                autoFindAndTapFileCell(pdfName, 0, ^(BOOL success, NSError *tapErr) {
                    if (!success) {
                        gIsProcessing = NO;
                        showToast([NSString stringWithFormat:@"触发下载失败: %@", tapErr.localizedDescription]);
                        // Still try to restore after delay
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            executeAutoRestore();
                        });
                        return;
                    }

                    showToast(@"✅ 已触发下载！15秒后自动恢复原名...");
                    gIsProcessing = NO;
                    // The scheduled auto-restore will fire in 15s
                });
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    if (gIsProcessing) {
        showToast(@"正在处理中，请稍候...");
        return;
    }

    DLog(@"Starting minimal download flow...");
    autoDetectPathAndToken();

    if (!gBdstoken) {
        showToast(@"未检测到登录状态，请确保已登录百度网盘");
        return;
    }

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            DLog(@"Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            showToast(err ? err.localizedDescription : @"文件夹为空");
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

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件自动下载"
                                                                       message:@"选择后将自动重命名为.pdf并触发下载，随后自动恢复原名"
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
            UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction *action) {
                runMinimalAutoDownloadFlow(name, path, fid);
            }];
            [sheet addAction:action];
        }
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        [sheet addAction:cancelAction];

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

// ========== Float button ==========

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = @"missing";
    if (gBdstoken) {
        NSUInteger len = gBdstoken.length;
        NSUInteger previewLen = len > 8 ? 8 : len;
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v8.6.0"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n改进：极简自动下载流程，自动恢复原名", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件自动下载"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
        triggerDownloadFlow();
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
    DLog(@"BaiduPan Troll v8.6.0 loaded - Minimal Auto-Download Edition");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
