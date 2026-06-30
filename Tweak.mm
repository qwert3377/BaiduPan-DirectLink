//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v11.1
//  Flow: select -> rename to .88888888888888 -> REFRESH -> TEST OPEN METHODS
//  CHANGELOG v11.1: No-scroll edition. Test multiple open methods with confirm dialogs.
//                   Each method auto-restore & exit on failure.
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
static BOOL gIsTestingMethods = NO;
static NSInteger gCurrentMethodIndex = 0;

// ====== Forward Declarations ======
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
static void simulateTouchOnCell(UIView *cell);
static void autoClickVisibleCell(NSString *ppName, UIScrollView *listView);
static void invokeOpenFileMethodOnVC(UIViewController *vc, NSString *fileName, NSString *filePath);
static NSString * topVCClassName(void);
static NSString * topVCTitle(void);

// ====== NEW: Method Testing System ======
static void testOpenMethodAtIndex(NSInteger index, NSString *ppName, NSString *ppPath, NSString *fileId, NSString *originalName);
static void showMethodConfirmDialog(NSInteger methodIndex, NSString *ppName, NSString *ppPath, NSString *fileId, NSString *originalName);
static void finishMethodTesting(BOOL opened, NSString *ppName, NSString *ppPath, NSString *fileId, NSString *originalName);
static void tryDirectInternalOpen(NSString *ppName, NSString *ppPath);
static void tryNotificationOpen(NSString *ppName, NSString *ppPath);
static void tryURLSchemeOpen(NSString *ppName, NSString *ppPath);
static void tryDownloadDirectLink(NSString *fileId, NSString *ppPath, NSString *originalName);
static void tryPushFilePreviewVC(NSString *ppName, NSString *ppPath);
static void trySimulateDoubleTap(NSString *ppName);
static void tryFileActionMenu(NSString *ppName, NSString *ppPath);
static void tryBDAPIDownload(NSString *fileId, NSString *ppPath, NSString *originalName);
static void tryHookedOpenMethod(NSString *ppName, NSString *ppPath);
static void tryDocumentInteraction(NSString *ppPath);
static void trySafariOpenLink(NSString *url);

// ====== Implementation: Top View Controller ======
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
}// ====== NEW: Method Testing System Implementation ======

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        stopTapDetection();
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
        gIsWaitingForTap = NO;
        gHasOpenedFile = NO;
        gIsTestingMethods = NO;
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
    if (!gIsWaitingForTap && !gIsTestingMethods) return;

    NSInteger currentCount = currentNavStackCount();
    NSString *currentClass = topVCClassName();
    NSString *currentTitle = topVCTitle();

    DLog(@"Tap detection: nav=%ld->%ld class=[%@]->[%@] title=[%@]->[%@] hasOpened=%d testing=%d",
         (long)gNavStackCount, (long)currentCount,
         gInitialTopVCClass, currentClass,
         gInitialTopVCTitle, currentTitle, gHasOpenedFile, gIsTestingMethods);

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
            showToast(@"✅ 检测到文件已打开！");
            stopTapDetection();
            if (gIsTestingMethods) {
                gIsTestingMethods = NO;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    executeRestore();
                });
            }
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

// ====== NEW: Open Method Implementations ======

static void tryDirectInternalOpen(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 1: Direct internal open");
    showToast(@"方法1: 直接调用内部打开方法...");
    
    UIViewController *vc = topViewController();
    if (!vc) {
        DLog(@"No top VC");
        return;
    }
    
    NSArray *selectors = @[
        @"openFile:", @"openFileWithId:", @"previewFile:", @"previewFileWithPath:",
        @"didSelectFile:", @"handleFileTap:", @"fileCellClicked:", @"enterFileDetail:",
        @"showFilePreview:", @"presentFileViewer:", @"routeToFileDetail:",
        @"openDocument:", @"previewDocument:", @"showPreviewForFile:",
        @"handleCellTap:", @"didTapFile:", @"onFileSelected:",
        @"pushFileDetail:", @"presentFileDetail:", @"showFileDetail:",
        @"openFileAtPath:", @"previewFileAtPath:", @"showFileAtPath:",
        @"selectFile:", @"tapFile:", @"clickFile:", @"openItem:",
        @"previewItem:", @"showItem:", @"detailForFile:", @"detailForItem:"
    ];
    
    for (NSString *selName in selectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Trying selector: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            @try {
                [vc performSelector:sel withObject:ppPath];
                DLog(@"Called %@ with path", selName);
                return;
            } @catch (NSException *e) {
                @try {
                    [vc performSelector:sel withObject:ppName];
                    DLog(@"Called %@ with name", selName);
                    return;
                } @catch (NSException *e2) {}
            }
            #pragma clang diagnostic pop
        }
    }
    
    UIScrollView *listView = findListViewGlobally();
    if (listView) {
        NSIndexPath *foundPath = nil;
        if ([listView isKindOfClass:[UITableView class]]) {
            foundPath = searchFileInTableView(ppName, (UITableView *)listView);
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
        }
        
        if (foundPath) {
            DLog(@"Found file in visible list, clicking directly");
            autoClickVisibleCell(ppName, listView);
            return;
        }
    }
    
    DLog(@"Method 1: No direct open method found");
}

static void tryNotificationOpen(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 2: Notification open");
    showToast(@"方法2: 发送打开文件通知...");
    
    NSArray *notifNames = @[
        @"BDPanOpenFileNotification",
        @"BDPanPreviewFileNotification",
        @"BDPanFileSelectedNotification",
        @"kOpenFileNotification",
        @"kPreviewFileNotification",
        @"OpenFileNotification",
        @"PreviewFileNotification",
        @"FileSelectedNotification",
        @"com.baidu.pan.openFile",
        @"com.baidu.pan.previewFile",
        @"BDPanFileDidSelectNotification",
        @"BDPanFileNeedOpenNotification",
        @"kFileSelectedNotification",
        @"FileOpenNotification",
        @"FilePreviewNotification"
    ];
    
    NSDictionary *userInfo = @{
        @"fileName": ppName,
        @"filePath": ppPath,
        @"path": ppPath,
        @"name": ppName,
        @"fileId": gPendingRestoreFileId ?: @"",
        @"fs_id": gPendingRestoreFileId ?: @""
    };
    
    for (NSString *name in notifNames) {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:userInfo];
        DLog(@"Posted notification: %@", name);
    }
    
    triggerNotificationFallback();
}

static void tryURLSchemeOpen(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 3: URL Scheme open");
    showToast(@"方法3: 尝试URL Scheme打开...");
    
    NSString *encodedPath = strictEncodeURIComponent(ppPath);
    NSArray *urlSchemes = @[
        [NSString stringWithFormat:@"baidupan://open?path=%@", encodedPath],
        [NSString stringWithFormat:@"baidupan://preview?path=%@", encodedPath],
        [NSString stringWithFormat:@"baidupan://file?path=%@", encodedPath],
        [NSString stringWithFormat:@"baiduwp://open?path=%@", encodedPath],
        [NSString stringWithFormat:@"baiduwp://preview?path=%@", encodedPath],
        [NSString stringWithFormat:@"pan.baidu.com://open?path=%@", encodedPath],
        [NSString stringWithFormat:@"bdnetdisk://n/action.MYFILE?path=%@", encodedPath],
        [NSString stringWithFormat:@"bdnetdisk://n/action.PREVIEW?path=%@", encodedPath],
        [NSString stringWithFormat:@"bdnetdisk://n/action.OPEN?path=%@", encodedPath]
    ];
    
    for (NSString *scheme in urlSchemes) {
        NSURL *url = [NSURL URLWithString:scheme];
        if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
            DLog(@"Trying URL scheme: %@", scheme);
            if (@available(iOS 10.0, *)) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                    DLog(@"URL scheme %@ opened: %d", scheme, success);
                }];
            } else {
                [[UIApplication sharedApplication] openURL:url];
            }
            return;
        }
    }
    
    DLog(@"Method 3: No supported URL scheme found");
}

static void tryDownloadDirectLink(NSString *fileId, NSString *ppPath, NSString *originalName) {
    DLog(@"Method 4: Download direct link");
    showToast(@"方法4: 获取下载直链...");
    
    if (!gBdstoken || !fileId) {
        DLog(@"No token or fileId");
        showToast(@"缺少token或fileId");
        return;
    }
    
    NSString *urlA = [NSString stringWithFormat:@"https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&access_token=%@&fsids=[%@]&dlink=1", gBdstoken, fileId];
    DLog(@"Trying API A: %@", urlA);
    
    bdAsyncRequest(urlA, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            DLog(@"API A error: %@", err);
            NSString *encodedPath = strictEncodeURIComponent(ppPath);
            NSString *urlB = [NSString stringWithFormat:@"https://pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=250528&path=%@", encodedPath];
            DLog(@"Trying API B: %@", urlB);
            
            bdAsyncRequest(urlB, @"GET", nil, nil, ^(id jsonB, NSError *errB) {
                if (errB) {
                    DLog(@"API B error: %@", errB);
                    showToast(@"获取直链失败");
                    return;
                }
                DLog(@"API B response: %@", jsonB);
                showToast(@"收到响应，请检查日志");
            });
            return;
        }
        
        DLog(@"API A response: %@", json);
        NSArray *list = json[@"list"];
        if ([list isKindOfClass:[NSArray class]] && list.count > 0) {
            NSDictionary *fileMeta = list[0];
            NSString *dlink = fileMeta[@"dlink"];
            if (dlink) {
                DLog(@"Got dlink: %@", dlink);
                showToast(@"✅ 获取到直链！");
                
                UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                pasteboard.string = dlink;
                showToast(@"直链已复制到剪贴板");
                
                NSURL *url = [NSURL URLWithString:dlink];
                if (url) {
                    if (@available(iOS 10.0, *)) {
                        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                    } else {
                        [[UIApplication sharedApplication] openURL:url];
                    }
                }
                return;
            }
        }
        showToast(@"未获取到直链");
    });
}

static void tryPushFilePreviewVC(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 5: Push file preview VC");
    showToast(@"方法5: 构造预览VC...");
    
    NSArray *possibleClasses = @[
        @"BDPanFilePreviewViewController",
        @"BDPanPreviewViewController",
        @"BDPanFileDetailViewController",
        @"BDPanFileViewerViewController",
        @"BDPanDocumentPreviewVC",
        @"BDPanFilePreviewVC",
        @"FilePreviewViewController",
        @"PreviewViewController",
        @"FileDetailViewController",
        @"BDFilePreviewController",
        @"BDPanFileController",
        @"BDPanPreviewController"
    ];
    
    UIViewController *topVC = topViewController();
    if (!topVC) return;
    
    for (NSString *className in possibleClasses) {
        Class cls = NSClassFromString(className);
        if (cls) {
            DLog(@"Found class: %@", className);
            @try {
                id instance = [[cls alloc] init];
                if (instance) {
                    NSArray *pathKeys = @[@"filePath", @"path", @"fileURL", @"documentPath", @"sourcePath"];
                    for (NSString *key in pathKeys) {
                        @try {
                            [instance setValue:ppPath forKey:key];
                            DLog(@"Set %@ = %@", key, ppPath);
                        } @catch (NSException *e) {}
                    }
                    
                    NSArray *nameKeys = @[@"fileName", @"title", @"documentName", @"name"];
                    for (NSString *key in nameKeys) {
                        @try {
                            [instance setValue:ppName forKey:key];
                        } @catch (NSException *e) {}
                    }
                    
                    if (topVC.navigationController) {
                        [topVC.navigationController pushViewController:instance animated:YES];
                        DLog(@"Pushed %@", className);
                        return;
                    } else {
                        [topVC presentViewController:instance animated:YES completion:nil];
                        DLog(@"Presented %@", className);
                        return;
                    }
                }
            } @catch (NSException *e) {
                DLog(@"Failed to use %@: %@", className, e);
            }
        }
    }
    
    DLog(@"Method 5: No preview VC class found");
}

static void trySimulateDoubleTap(NSString *ppName) {
    DLog(@"Method 6: Simulate double tap");
    showToast(@"方法6: 模拟双击文件...");
    
    UIScrollView *listView = findListViewGlobally();
    if (!listView) {
        DLog(@"No list view found");
        return;
    }
    
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        foundPath = searchFileInTableView(ppName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
    }
    
    if (!foundPath) {
        DLog(@"File not visible in current view");
        showToast(@"文件不在当前可见区域");
        return;
    }
    
    UIView *cell = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        cell = [(UITableView *)listView cellForRowAtIndexPath:foundPath];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        cell = [(UICollectionView *)listView cellForItemAtIndexPath:foundPath];
    }
    
    if (!cell) {
        DLog(@"Cell not visible");
        return;
    }
    
    CGPoint center = CGPointMake(cell.bounds.size.width / 2.0, cell.bounds.size.height / 2.0);
    
    @try {
        [[UIApplication sharedApplication] sendAction:@selector(touchesBegan:withEvent:) to:cell from:nil forEvent:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] sendAction:@selector(touchesEnded:withEvent:) to:cell from:nil forEvent:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] sendAction:@selector(touchesBegan:withEvent:) to:cell from:nil forEvent:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[UIApplication sharedApplication] sendAction:@selector(touchesEnded:withEvent:) to:cell from:nil forEvent:nil];
                });
            });
        });
    } @catch (NSException *e) {
        DLog(@"Double tap simulation failed: %@", e);
    }
    
    DLog(@"Method 6: Double tap simulated");
}

static void tryFileActionMenu(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 7: File action menu");
    showToast(@"方法7: 模拟文件操作菜单...");
    
    UIScrollView *listView = findListViewGlobally();
    if (!listView) {
        DLog(@"No list view");
        return;
    }
    
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        foundPath = searchFileInTableView(ppName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        foundPath = searchFileInCollectionView(ppName, (UICollectionView *)listView);
    }
    
    if (!foundPath) {
        DLog(@"File not visible");
        showToast(@"文件不在当前可见区域");
        return;
    }
    
    UIView *cell = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        cell = [(UITableView *)listView cellForRowAtIndexPath:foundPath];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        cell = [(UICollectionView *)listView cellForItemAtIndexPath:foundPath];
    }
    
    if (!cell) return;
    
    @try {
        NSArray *menuSelectors = @[
            @"showActionMenu:", @"showFileMenu:", @"showContextMenu:",
            @"presentActionSheet:", @"showOptions:", @"showMoreOptions:",
            @"fileLongPressed:", @"handleLongPress:", @"onLongPress:",
            @"showFileActions:", @"presentFileOptions:", @"showMenuForFile:"
        ];
        
        UIViewController *vc = topViewController();
        for (NSString *selName in menuSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([vc respondsToSelector:sel]) {
                DLog(@"Calling menu selector: %@", selName);
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [vc performSelector:sel withObject:ppPath];
                #pragma clang diagnostic pop
                return;
            }
        }
        
        for (UIGestureRecognizer *gr in cell.gestureRecognizers) {
            if ([gr isKindOfClass:[UILongPressGestureRecognizer class]]) {
                DLog(@"Triggering long press gesture");
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL sel = NSSelectorFromString(@"_touchesBegan:withEvent:");
                if ([gr respondsToSelector:sel]) {
                    [gr performSelector:sel withObject:[NSSet set] withObject:nil];
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    SEL sel2 = NSSelectorFromString(@"_touchesEnded:withEvent:");
                    if ([gr respondsToSelector:sel2]) {
                        [gr performSelector:sel2 withObject:[NSSet set] withObject:nil];
                    }
                });
                #pragma clang diagnostic pop
                return;
            }
        }
    } @catch (NSException *e) {
        DLog(@"Menu simulation failed: %@", e);
    }
    
    DLog(@"Method 7: Action menu attempted");
}

static void tryBDAPIDownload(NSString *fileId, NSString *ppPath, NSString *originalName) {
    DLog(@"Method 8: Baidu API direct download");
    showToast(@"方法8: API直接下载请求...");
    
    if (!gBdstoken || !fileId) {
        DLog(@"Missing token or fileId");
        showToast(@"缺少认证信息");
        return;
    }
    
    NSString *encodedPath = strictEncodeURIComponent(ppPath);
    NSString *url = [NSString stringWithFormat:@"https://d.pcs.baidu.com/rest/2.0/pcs/file?method=download&app_id=250528&path=%@&bdstoken=%@", encodedPath, gBdstoken];
    
    DLog(@"Download URL: %@", url);
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 30;
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://pan.baidu.com/" forHTTPHeaderField:@"Referer"];
    if (gBDUSS) {
        [req setValue:[NSString stringWithFormat:@"BDUSS=%@", gBDUSS] forHTTPHeaderField:@"Cookie"];
    }
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                DLog(@"Download request error: %@", error);
                showToast(@"下载请求失败");
                return;
            }
            
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            DLog(@"Download response status: %ld", (long)httpResponse.statusCode);
            DLog(@"Download response headers: %@", httpResponse.allHeaderFields);
            
            if (httpResponse.statusCode == 302 || httpResponse.statusCode == 301) {
                NSString *location = httpResponse.allHeaderFields[@"Location"];
                if (!location) location = httpResponse.allHeaderFields[@"location"];
                if (location) {
                    DLog(@"Redirect location: %@", location);
                    showToast(@"✅ 获取到下载地址！");
                    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                    pasteboard.string = location;
                    showToast(@"下载地址已复制");
                    
                    NSURL *openURL = [NSURL URLWithString:location];
                    if (openURL) {
                        if (@available(iOS 10.0, *)) {
                            [[UIApplication sharedApplication] openURL:openURL options:@{} completionHandler:nil];
                        } else {
                            [[UIApplication sharedApplication] openURL:openURL];
                        }
                    }
                    return;
                }
            }
            
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            DLog(@"Download response JSON: %@", json);
            
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSString *errorMsg = json[@"error_msg"] ?: json[@"errmsg"];
                if (errorMsg) {
                    showToast([NSString stringWithFormat:@"API错误: %@", errorMsg]);
                } else {
                    showToast(@"收到响应，请检查日志");
                }
            } else {
                showToast(@"下载请求已发送");
            }
        });
    }];
    [task resume];
}

static void tryHookedOpenMethod(NSString *ppName, NSString *ppPath) {
    DLog(@"Method 9: Hooked open method");
    showToast(@"方法9: 尝试Hook内部打开...");
    
    Class fileListVCClass = nil;
    NSArray *possibleClassNames = @[
        @"BDPanFileListViewController",
        @"BDPanFileViewController",
        @"BDPanListViewController",
        @"BDPanHomeViewController",
        @"BDPanMainViewController",
        @"FileListViewController",
        @"PanFileListViewController",
        @"BDPanFileListVC",
        @"BDPanFileListController"
    ];
    
    for (NSString *className in possibleClassNames) {
        Class cls = NSClassFromString(className);
        if (cls) {
            fileListVCClass = cls;
            DLog(@"Found file list VC class: %@", className);
            break;
        }
    }
    
    if (!fileListVCClass) {
        DLog(@"No file list VC class found");
        showToast(@"未找到文件列表VC");
        return;
    }
    
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(fileListVCClass, &methodCount);
    
    for (unsigned int i = 0; i < methodCount; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        
        if ([selName containsString:@"open"] || [selName containsString:@"preview"] || 
            [selName containsString:@"select"] || [selName containsString:@"tap"] ||
            [selName containsString:@"click"] || [selName containsString:@"file"]) {
            DLog(@"Found potential method: %@", selName);
            
            UIViewController *vc = topViewController();
            if ([vc isKindOfClass:fileListVCClass] && [vc respondsToSelector:sel]) {
                DLog(@"Trying to call %@ on current VC", selName);
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                @try {
                    [vc performSelector:sel withObject:ppPath];
                    DLog(@"Called %@ with path", selName);
                    free(methods);
                    return;
                } @catch (NSException *e) {
                    @try {
                        [vc performSelector:sel withObject:ppName];
                        DLog(@"Called %@ with name", selName);
                        free(methods);
                        return;
                    } @catch (NSException *e2) {}
                }
                #pragma clang diagnostic pop
            }
        }
    }
    
    free(methods);
    DLog(@"Method 9: No hooked method worked");
    showToast(@"未找到可用的Hook方法");
}

static void tryDocumentInteraction(NSString *ppPath) {
    DLog(@"Method 10: Document Interaction");
    showToast(@"方法10: 文档交互打开...");
    
    NSString *encodedPath = strictEncodeURIComponent(ppPath);
    NSString *urlString = [NSString stringWithFormat:@"https://pan.baidu.com/disk/home?path=%@", encodedPath];
    NSURL *url = [NSURL URLWithString:urlString];
    
    if (url) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
                DLog(@"Document interaction open: %d", success);
            }];
        } else {
            [[UIApplication sharedApplication] openURL:url];
        }
    }
    
    DLog(@"Method 10: Document interaction attempted");
}

static void trySafariOpenLink(NSString *url) {
    if (!url || url.length == 0) return;
    DLog(@"Opening in Safari: %@", url);
    NSURL *nsurl = [NSURL URLWithString:url];
    if (nsurl) {
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:nsurl options:@{} completionHandler:nil];
        } else {
            [[UIApplication sharedApplication] openURL:nsurl];
        }
    }
}

// ====== NEW: Method Testing Controller ======

static void testOpenMethodAtIndex(NSInteger index, NSString *ppName, NSString *ppPath, NSString *fileId, NSString *originalName) {
    gCurrentMethodIndex = index;
    
    switch (

