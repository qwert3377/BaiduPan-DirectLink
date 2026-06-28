//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v8.5.3
//  Fix: buildPathFromNavStack no longer concatenates all VC paths (caused duplicate/wrong paths)
//  Fix: forceRefreshFileList now recursively searches all windows/VCs for refresh targets
//  Fix: Added more path keys (currentDirectory, directoryPath, currentDirPath)
//  Fix: Path normalization ensures leading /
//  Fix: pollForFileExistence now uses correct path after rename
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

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
static NSString * digOutDlink(id obj);
static void fetchDlinkViaFilemetas(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err));
static void fetchDlinkViaLocatedownload(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err));
static void fetchDirectLink(NSString *filePath, void (^completion)(NSString *link, NSError *err));
static void copyToClipboard(NSString *text);
static void showToast(NSString *msg);
static void forceRefreshFileList(void);
static void refreshVC(UIViewController *vc);
static void pollForFileExistence(NSString *expectedPath, NSString *fileId, NSString *originalName, NSInteger attempt, void (^completion)(BOOL found, NSError *err));
static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath, BOOL needsRestore);
static void runRenameAndGetLink(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

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
    if (path && path.length > 0) {
        DLog(@"Path from current VC: %@", path);
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
        if (topPath && topPath.length > 0) {
            DLog(@"Path from nav topVC: %@", topPath);
            return topPath;
        }

        NSArray *vcs = nav.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            NSString *p = extractPathFromVC(vcs[i]);
            if (p && p.length > 0) {
                DLog(@"Path from nav stack[%ld]: %@", (long)i, p);
                return p;
            }
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

static NSString * digOutDlink(id obj) {
    if (!obj || ![obj isKindOfClass:[NSObject class]]) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        id dlink = dict[@"dlink"];
        if ([dlink isKindOfClass:[NSString class]] && [(NSString *)dlink length] > 0) return dlink;
        id data = dict[@"data"];
        if (data) { NSString *found = digOutDlink(data); if (found) return found; }
        for (id value in [dict allValues]) { NSString *found = digOutDlink(value); if (found) return found; }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) { NSString *found = digOutDlink(item); if (found) return found; }
    }
    return nil;
}

static void fetchDlinkViaFilemetas(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err)) {
    if (!gBdstoken) { completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]); return; }
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%lld", gBdstoken, encodedPath, ts];
    bdAsyncRequest(url, @"GET", @{@"X-Requested-With": @"XMLHttpRequest"}, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            NSString *dlink = digOutDlink(json);
            if (dlink) { completion(dlink, nil); return; }
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"No dlink in response"}]);
        } else if (errnoNum && [errnoNum integerValue] == -9 && retryCount < 3) {
            DLog(@"filemetas not ready, retry %ld...", (long)(retryCount + 1));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fetchDlinkViaFilemetas(filePath, retryCount + 1, completion);
            });
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"filemetas error (errno=%@)", errnoNum];
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static void fetchDlinkViaLocatedownload(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err)) {
    if (!gBdstoken) { completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]); return; }
    NSString *encodedPath = strictEncodeURIComponent(filePath);
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/locatedownload?clienttype=0&app_id=250528&web=1&channel=chunlei&path=%@&origin=pdf&use=1&bdstoken=%@&t=%lld", encodedPath, gBdstoken, ts];
    bdAsyncRequest(url, @"GET", @{@"X-Requested-With": @"XMLHttpRequest"}, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSString *dlink = digOutDlink(json);
        if (dlink) { completion(dlink, nil); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == -9 && retryCount < 3) {
            DLog(@"locatedownload not ready, retry %ld...", (long)(retryCount + 1));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fetchDlinkViaLocatedownload(filePath, retryCount + 1, completion);
            });
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"locatedownload error (errno=%@)", errnoNum];
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static void fetchDirectLink(NSString *filePath, void (^completion)(NSString *link, NSError *err)) {
    DLog(@"Fetching direct link for: %@", filePath);
    fetchDlinkViaFilemetas(filePath, 0, ^(NSString *link, NSError *err) {
        if (link) { completion(link, nil); return; }
        DLog(@"filemetas failed: %@, trying locatedownload...", err.localizedDescription);
        fetchDlinkViaLocatedownload(filePath, 0, ^(NSString *link2, NSError *err2) {
            if (link2) { completion(link2, nil); return; }
            NSString *msg = [NSString stringWithFormat:@"无法获取直链。\nfilemetas: %@\nlocatedownload: %@", err.localizedDescription, err2.localizedDescription];
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-5 userInfo:@{NSLocalizedDescriptionKey: msg}]);
        });
    });
}

static void copyToClipboard(NSString *text) {
    if (!text) return;
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = text;
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

// ========== Refresh mechanism v8.5.3 ==========

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

    DLog(@"Simulating pull-to-refresh via contentOffset");
    CGPoint originalOffset = scrollView.contentOffset;
    [UIView animateWithDuration:0.3 animations:^{
        scrollView.contentOffset = CGPointMake(originalOffset.x, -120);
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                scrollView.contentOffset = originalOffset;
            }];
        });
    }];

    if (scrollView.delegate) {
        SEL scrollSel = @selector(scrollViewDidScroll:);
        SEL dragSel = @selector(scrollViewDidEndDragging:willDecelerate:);
        if ([scrollView.delegate respondsToSelector:scrollSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [scrollView.delegate performSelector:scrollSel withObject:scrollView];
            #pragma clang diagnostic pop
        }
        if ([scrollView.delegate respondsToSelector:dragSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [scrollView.delegate performSelector:dragSel withObject:scrollView withObject:@(NO)];
            #pragma clang diagnostic pop
        }
    }

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

// ========== UI Dialog ==========

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath, BOOL needsRestore) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"直链已复制"
                                                                   message:[NSString stringWithFormat:@"%@ 的直链已成功复制到剪贴板。\n\n可使用 IDM、Aria2、Motrix 等工具粘贴下载。", fileName]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = link;
        textField.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        textField.textColor = [UIColor colorWithRed:0.18 green:0.42 blue:1.0 alpha:1.0];
        textField.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:1.0 alpha:1.0];
        textField.layer.borderColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0].CGColor;
        textField.layer.borderWidth = 1.0;
        textField.layer.cornerRadius = 6;
        textField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 0)];
        textField.leftViewMode = UITextFieldViewModeAlways;
        textField.clearButtonMode = UITextFieldViewModeNever;
        textField.userInteractionEnabled = YES;
    }];

    if (needsRestore) {
        UIAlertAction *copyRestoreAction = [UIAlertAction actionWithTitle:@"再次复制并恢复原名"
                                                                    style:UIAlertActionStyleDefault
                                                                  handler:^(UIAlertAction *a) {
            copyToClipboard(link);
            showToast(@"直链已再次复制！");
            renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
            });
        }];
        [alert addAction:copyRestoreAction];

        UIAlertAction *keepPdfAction = [UIAlertAction actionWithTitle:@"保持pdf后缀"
                                                                style:UIAlertActionStyleCancel
                                                              handler:nil];
        [alert addAction:keepPdfAction];
    } else {
        UIAlertAction *copyAgainAction = [UIAlertAction actionWithTitle:@"再次复制"
                                                                    style:UIAlertActionStyleDefault
                                                                  handler:^(UIAlertAction *a) {
            copyToClipboard(link);
            showToast(@"直链已再次复制！");
        }];
        [alert addAction:copyAgainAction];

        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
        [alert addAction:okAction];
    }

    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void runRenameAndGetLink(NSString *fileName, NSString *filePath, NSString *fileId) {
    NSString *ext = fileName.pathExtension.lowercaseString;
    BOOL isAlreadyPDF = [ext isEqualToString:@"pdf"];

    if (isAlreadyPDF) {
        DLog(@"File is already PDF, skipping rename...");
        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..."
                                                                               message:@"获取直链..."
                                                                        preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *presentVC = topViewController();
        if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

        __weak UIAlertController *weakProgress = progressAlert;

        fetchDirectLink(filePath, ^(NSString *link, NSError *err) {
            [weakProgress dismissViewControllerAnimated:YES completion:^{
                if (err || !link) {
                    UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"获取直链失败"
                                                                                       message:err.localizedDescription
                                                                                preferredStyle:UIAlertControllerStyleAlert];
                    [failAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc = topViewController();
                    if (vc) [vc presentViewController:failAlert animated:YES completion:nil];
                    return;
                }
                copyToClipboard(link);
                showToast(@"直链已复制到剪贴板！");
                showLinkDialog(link, fileName, fileId, filePath, NO);
            }];
        });
        return;
    }

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..."
                                                                           message:@"1. 重命名文件"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presentVC = topViewController();
    if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

    __weak UIAlertController *weakProgress = progressAlert;

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            [weakProgress dismissViewControllerAnimated:YES completion:^{
                UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"重命名失败"
                                                                                   message:err.localizedDescription
                                                                            preferredStyle:UIAlertControllerStyleAlert];
                [failAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = topViewController();
                if (vc) [vc presentViewController:failAlert animated:YES completion:nil];
            }];
            return;
        }

        DLog(@"Renamed to %@, triggering refresh...", pdfName);
        weakProgress.message = @"2. 刷新文件列表...";
        forceRefreshFileList();

        weakProgress.message = @"3. 等待文件列表同步...";
        pollForFileExistence(pdfPath, fileId, fileName, 0, ^(BOOL found, NSError *pollErr) {
            if (!found) {
                [weakProgress dismissViewControllerAnimated:YES completion:^{
                    renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                        DLog(@"Auto restore (poll failed): %@", ok ? @"OK" : e.localizedDescription);
                    });
                    UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"同步失败"
                                                                                       message:pollErr.localizedDescription
                                                                                preferredStyle:UIAlertControllerStyleAlert];
                    [failAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc = topViewController();
                    if (vc) [vc presentViewController:failAlert animated:YES completion:nil];
                }];
                return;
            }

            weakProgress.message = @"4. 获取直链...";
            fetchDirectLink(pdfPath, ^(NSString *link, NSError *err) {
                [weakProgress dismissViewControllerAnimated:YES completion:^{
                    if (err || !link) {
                        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                            DLog(@"Auto restore: %@", ok ? @"OK" : e.localizedDescription);
                        });
                        UIAlertController *failAlert = [UIAlertController alertControllerWithTitle:@"获取直链失败"
                                                                                           message:err.localizedDescription
                                                                                    preferredStyle:UIAlertControllerStyleAlert];
                        [failAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        UIViewController *vc = topViewController();
                        if (vc) [vc presentViewController:failAlert animated:YES completion:nil];
                        return;
                    }

                    copyToClipboard(link);
                    showToast(@"直链已复制到剪贴板！");
                    showLinkDialog(link, fileName, fileId, pdfPath, YES);
                }];
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    DLog(@"Starting download flow...");
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            DLog(@"Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取文件列表失败"
                                                                           message:err ? err.localizedDescription : @"文件夹为空"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }

        if (fileItems.count == 0) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"没有文件"
                                                                           message:@"当前文件夹没有可下载的文件"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件获取直链"
                                                                       message:nil
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
                runRenameAndGetLink(name, path, fid);
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
        NSUInteger previewLen = len > 16 ? 16 : len;
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v8.5.3"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"获取直链"
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
    DLog(@"BaiduPan Troll v8.5.3 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
