//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v10.2
//  Flow: select -> rename to .ipa -> refresh x2 + scroll to top -> AUTO CLICK renamed file -> detect new VC pushed -> auto restore name
//  NO direct link download - only simulate user tap on renamed file
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// State for tap detection
static NSString *gPendingRestoreFileId = nil;
static NSString *gPendingRestorePdfPath = nil;
static NSString *gPendingRestoreOriginalName = nil;
static NSTimer *gTapDetectionTimer = nil;
static NSInteger gNavStackCount = 0;
static BOOL gIsWaitingForTap = NO;
static NSString *gInitialTopVCClass = nil;
static NSString *gInitialTopVCTitle = nil;

// ========== Forward declarations ==========
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
static void simulatePullToRefreshOnScrollView(UIScrollView *scrollView);
static void tryRefreshOnScrollView(UIScrollView *scrollView);
static void startTapDetection(void);
static void stopTapDetection(void);
static void checkIfFileOpened(void);
static void executeRestore(void);
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

// ========== v10.6 Auto-click helpers ==========
static UIView * findViewRecursively(UIView *root, Class targetClass);
static void sendTouchToView(UIView *targetView, CGPoint point) {
    if (!targetView) return;
    @try {
        // Method 1: Create UITouch with proper initialization
        UITouch *touch = [[UITouch alloc] init];
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:@(1) forKey:@"tapCount"];
        [touch setValue:targetView forKey:@"view"];
        [touch setValue:targetView.window forKey:@"window"];

        // Set touch location
        CGPoint loc = [targetView convertPoint:point toView:targetView.window];
        NSValue *locValue = [NSValue valueWithCGPoint:loc];
        [touch setValue:locValue forKey:@"locationInWindow"];

        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:touch forKey:@"_firstTouchForView"];
        [event setValue:[NSSet setWithObject:touch] forKey:@"_allTouches"];

        // Send to view and its responders
        [targetView touchesBegan:[NSSet setWithObject:touch] withEvent:event];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [targetView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
        });
    } @catch (NSException *e) {
        DLog(@"Touch send failed: %@", e.reason);
    }
}

static void triggerGestureRecognizers(UIView *view) {
    if (!view) return;
    @try {
        NSArray *gestures = view.gestureRecognizers;
        for (UIGestureRecognizer *gr in gestures) {
            if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
                DLog(@"Triggering tap gesture on view");
                gr.enabled = YES;
                [gr setValue:@(UIGestureRecognizerStateEnded) forKey:@"state"];
                if (gr.delegate && [gr.delegate respondsToSelector:@selector(gestureRecognizer:shouldReceiveTouch:)]) {
                    // Try to trigger through delegate
                }
            }
        }
        // Also check subviews
        for (UIView *sub in view.subviews) {
            triggerGestureRecognizers(sub);
        }
    } @catch (NSException *e) {}
}

static void callSelectOnTableView(UITableView *tv, NSIndexPath *ip) {
    if (!tv || !ip) return;
    @try {
        // Method A: Direct delegate call
        id delegate = tv.delegate;
        if (delegate && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            DLog(@"Calling delegate didSelectRowAtIndexPath:");
            NSMethodSignature *sig = [delegate methodSignatureForSelector:@selector(tableView:didSelectRowAtIndexPath:)];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:@selector(tableView:didSelectRowAtIndexPath:)];
                [inv setTarget:delegate];
                id tvArg = tv;
                id ipArg = ip;
                [inv setArgument:&tvArg atIndex:2];
                [inv setArgument:&ipArg atIndex:3];
                [inv invoke];
            }
        }

        // Method B: Call through UITableView itself
        SEL selectSel = NSSelectorFromString(@"_selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:");
        if ([tv respondsToSelector:selectSel]) {
            DLog(@"Calling _selectRowAtIndexPath:animated:scrollPosition:notifyDelegate:");
            NSMethodSignature *sig = [tv methodSignatureForSelector:selectSel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:selectSel];
                [inv setTarget:tv];
                id ipArg = ip;
                BOOL animated = YES;
                NSInteger scrollPos = UITableViewScrollPositionNone;
                BOOL notify = YES;
                [inv setArgument:&ipArg atIndex:2];
                [inv setArgument:&animated atIndex:3];
                [inv setArgument:&scrollPos atIndex:4];
                [inv setArgument:&notify atIndex:5];
                [inv invoke];
            }
        }

        // Method C: Use selectRowAtIndexPath:animated:scrollPosition:
        [tv selectRowAtIndexPath:ip animated:YES scrollPosition:UITableViewScrollPositionNone];

    } @catch (NSException *e) {
        DLog(@"TableView select failed: %@", e.reason);
    }
}

static void executeClickOnCell(UITableViewCell *cell, NSIndexPath *ip, UITableView *tableView) {
    if (!cell || !ip || !tableView) return;
    DLog(@"Executing click on cell at %@", ip);

    CGPoint center = CGPointMake(cell.bounds.size.width / 2, cell.bounds.size.height / 2);

    // Layer 1: contentView
    if (cell.contentView) {
        DLog(@"Touch layer 1: contentView");
        sendTouchToView(cell.contentView, center);
    }

    // Layer 2: cell itself
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DLog(@"Touch layer 2: cell");
        sendTouchToView(cell, center);

        // Layer 3: delegate + gestures
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DLog(@"Touch layer 3: delegate + gestures");
            callSelectOnTableView(tableView, ip);
            triggerGestureRecognizers(cell);
            showToast(@"已自动点击文件");
        });
    });
}

static void autoClickRenamedFile(NSString *ipaName);

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

static void scrollToFileLocation(NSString *fileName) {
    if (!fileName) return;
    DLog(@"scrollToFileLocation: %@", fileName);

    UIViewController *vc = topViewController();
    if (!vc) return;

    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);
    if (!tableView) return;

    // BaiduPan sorts folders first, files last. Force scroll to absolute bottom.
    // Use contentOffset directly because scrollToRowAtIndexPath may not work with custom layouts.
    CGFloat contentHeight = tableView.contentSize.height;
    CGFloat boundsHeight = tableView.bounds.size.height;
    CGFloat bottomOffset = contentHeight - boundsHeight;

    if (bottomOffset > 0) {
        [UIView animateWithDuration:0.5 animations:^{
            tableView.contentOffset = CGPointMake(0, bottomOffset);
        }];
        DLog(@"Forced scroll to bottom offset %.0f", bottomOffset);
    } else {
        // Content is smaller than view, already at bottom
        DLog(@"Content already fits in view");
    }
}

// ========== v10.6 Auto-click helpers ==========

static UIView * findViewRecursively(UIView *root, Class targetClass) {
    if (!root) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = findViewRecursively(subview, targetClass);
        if (found) return found;
    }
    return nil;
}

// ========== v10.6 CORE: Auto-click renamed file (rebuilt) ==========

static void autoClickRenamedFile(NSString *ipaName) {
    if (!ipaName) return;
    DLog(@"v10.6 Auto-clicking: %@", ipaName);

    UIViewController *vc = topViewController();
    if (!vc) {
        DLog(@"No top VC for auto-click");
        return;
    }

    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);
    if (!tableView) {
        DLog(@"No tableView found");
        showToast(@"未找到文件列表");
        return;
    }

    DLog(@"Found tableView, searching for: %@ (files are always below all folders)", ipaName);

    // Fix iOS 11+ estimated height issue
    @try {
        tableView.estimatedRowHeight = 0;
        tableView.estimatedSectionHeaderHeight = 0;
        tableView.estimatedSectionFooterHeight = 0;
    } @catch (NSException *e) {}

    [tableView layoutIfNeeded];

    // Helper: search for file in currently visible cells, scanning from bottom-up
    __block NSIndexPath *foundIndexPath = nil;
    void (^searchFile)(void) = ^{
        foundIndexPath = nil;
        NSInteger totalSections = 1;
        @try { totalSections = [tableView numberOfSections]; } @catch (NSException *e) {}

        for (NSInteger section = 0; section < totalSections; section++) {
            NSInteger rows = 0;
            @try { rows = [tableView numberOfRowsInSection:section]; } @catch (NSException *e) {}

            // Search from bottom to top: files are sorted below folders in BaiduPan
            for (NSInteger row = rows - 1; row >= 0; row--) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
                @try {
                    UITableViewCell *cell = [tableView cellForRowAtIndexPath:ip];
                    if (!cell) continue;
                    if (viewContainsText(cell, ipaName)) {
                        foundIndexPath = ip;
                        DLog(@"Found cell at row %ld, section %ld", (long)row, (long)section);
                        break;
                    }
                } @catch (NSException *e) {}
            }
            if (foundIndexPath) break;
        }
    };

    // Helper: scroll down by one screen worth of content to reveal more cells
    void (^scrollDownOneScreen)(void) = ^{
        CGFloat currentOffset = tableView.contentOffset.y;
        CGFloat screenHeight = tableView.bounds.size.height;
        CGFloat maxOffset = tableView.contentSize.height - screenHeight;
        CGFloat newOffset = MIN(currentOffset + screenHeight * 0.8, maxOffset);

        if (newOffset > currentOffset) {
            [UIView animateWithDuration:0.4 animations:^{
                tableView.contentOffset = CGPointMake(0, newOffset);
            }];
            DLog(@"Scrolled down from %.0f to %.0f", currentOffset, newOffset);
        }
    };

    // Helper: perform the actual click on found cell
    void (^clickFoundCell)(void) = ^{
        if (!foundIndexPath) return;

        // Center the cell on screen for reliable clicking
        CGRect cellRect = [tableView rectForRowAtIndexPath:foundIndexPath];
        CGFloat targetOffset = cellRect.origin.y - (tableView.bounds.size.height / 2) + (cellRect.size.height / 2);
        targetOffset = MAX(0, MIN(targetOffset, tableView.contentSize.height - tableView.bounds.size.height));

        [UIView animateWithDuration:0.3 animations:^{
            tableView.contentOffset = CGPointMake(0, targetOffset);
        }];
        showToast(@"正在滚动到文件...");

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:foundIndexPath];
            if (cell) {
                executeClickOnCell(cell, foundIndexPath, tableView);
            } else {
                DLog(@"Cell became nil after scroll");
                showToast(@"文件未显示，请手动点击");
            }
        });
    };

    // Step-by-step scrolling strategy
    __block NSInteger attemptCount = 0;
    __block NSInteger maxAttempts = 15;

    __block void (^stepSearch)(void) = ^{
        attemptCount++;
        DLog(@"Step search attempt %ld/%ld", (long)attemptCount, (long)maxAttempts);

        [tableView layoutIfNeeded];
        searchFile();

        if (foundIndexPath) {
            DLog(@"File found on attempt %ld!", (long)attemptCount);
            clickFoundCell();
            return;
        }

        if (attemptCount >= maxAttempts) {
            DLog(@"Max attempts reached, file not found");
            showToast(@"未找到文件，请手动点击");
            return;
        }

        // File not found, scroll down one screen to load more cells
        showToast([NSString stringWithFormat:@"正在向下查找... (%ld/%ld)", (long)attemptCount, (long)maxAttempts]);
        scrollDownOneScreen();

        // Wait for scroll animation + cell loading, then try again
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), stepSearch);
    };

    // Start the step-by-step search
    searchFile();
    if (foundIndexPath) {
        clickFoundCell();
    } else {
        showToast(@"开始向下查找文件...");
        stepSearch();
    }
}

// ========== Tap Detection ==========

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        stopTapDetection();
        return;
    }
    DLog(@"Executing restore: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            showToast(@"✅ 已自动恢复原名");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                forceRefreshFileList();
            });
        } else {
            showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]);
        }
        gPendingRestoreFileId = nil;
        gPendingRestorePdfPath = nil;
        gPendingRestoreOriginalName = nil;
        gIsWaitingForTap = NO;
    });
}

static void stopTapDetection(void) {
    if (gTapDetectionTimer) {
        [gTapDetectionTimer invalidate];
        gTapDetectionTimer = nil;
    }
    gIsWaitingForTap = NO;
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

static void checkIfFileOpened(void) {
    if (!gIsWaitingForTap) return;

    NSInteger currentCount = currentNavStackCount();
    NSString *currentClass = topVCClassName();
    NSString *currentTitle = topVCTitle();

    DLog(@"Tap detection: nav=%ld->%ld class=[%@]->[%@] title=[%@]->[%@]", 
         (long)gNavStackCount, (long)currentCount,
         gInitialTopVCClass, currentClass,
         gInitialTopVCTitle, currentTitle);

    if (currentCount > gNavStackCount) {
        DLog(@"File opened detected (nav stack increased)! Restoring...");
        stopTapDetection();
        showToast(@"检测到文件已打开，正在恢复原名...");
        executeRestore();
        return;
    }

    if (gInitialTopVCClass && ![gInitialTopVCClass isEqualToString:currentClass]) {
        DLog(@"File opened detected (VC class changed)! Restoring...");
        stopTapDetection();
        showToast(@"检测到文件已打开，正在恢复原名...");
        executeRestore();
        return;
    }

    if (gPendingRestoreOriginalName && currentTitle && [currentTitle containsString:gPendingRestoreOriginalName]) {
        DLog(@"File opened detected (title matches file name)! Restoring...");
        stopTapDetection();
        showToast(@"检测到文件已打开，正在恢复原名...");
        executeRestore();
        return;
    }

    if (currentTitle && ([currentTitle containsString:@"预览"] || [currentTitle containsString:@"下载"] || [currentTitle containsString:@"文件详情"])) {
        DLog(@"File opened detected (preview title)! Restoring...");
        stopTapDetection();
        showToast(@"检测到文件已打开，正在恢复原名...");
        executeRestore();
        return;
    }
}

static void startTapDetection(void) {
    stopTapDetection();
    gIsWaitingForTap = YES;
    gNavStackCount = currentNavStackCount();
    gInitialTopVCClass = topVCClassName();
    gInitialTopVCTitle = topVCTitle();
    DLog(@"Started tap detection, nav=%ld class=%@ title=%@", (long)gNavStackCount, gInitialTopVCClass, gInitialTopVCTitle);

    gTapDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                            target:[NSBlockOperation blockOperationWithBlock:^{
                                                                checkIfFileOpened();
                                                            }]
                                                          selector:@selector(main)
                                                          userInfo:nil
                                                           repeats:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gIsWaitingForTap) {
            DLog(@"Tap detection timeout, forcing restore");
            stopTapDetection();
            showToast(@"等待超时，自动恢复原名");
            executeRestore();
        }
    });
}

// ========== Smart Flow ==========

static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId) {
    stopTapDetection();
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;

    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"ipa"]) {
        showToast(@"文件已是IPA，无需处理");
        return;
    }

    NSString *ipaName = [fileName stringByAppendingString:@".ipa"];
    NSString *ipaPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ipaName];

    showToast(@"1. 重命名...");
    renameFile(fileId, filePath, ipaName, ^(BOOL success, NSError *err) {
        if (!success) {
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }

        gPendingRestoreFileId = fileId;
        gPendingRestorePdfPath = ipaPath;
        gPendingRestoreOriginalName = fileName;

        showToast(@"2. 刷新第1次...");
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showToast(@"3. 刷新第2次...");
            forceRefreshFileList();

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                showToast(@"4. 滚动到文件位置...");
                scrollToFileLocation(ipaName);

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    showToast(@"5. 自动点击文件...");
                    autoClickRenamedFile(ipaName);

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        showToast(@"已尝试自动点击，如未打开请手动点击");
                        startTapDetection();
                    });
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

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
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
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                       message:@"选择后自动重命名为.ipa并刷新，自动点击文件打开后自动恢复原名"
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
                runSmartFlow(name, path, fid);
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v10.6"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n智能流程：改名->刷新2次->自动点击->检测打开->自动恢复", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件"
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
    DLog(@"BaiduPan Troll v10.6 loaded - Auto-Click Edition");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
