//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v10.37
//  CHANGELOG v10.37: Fixed path detection + UICollectionView cell visibility + reload timing
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ===== LOGGING =====
static NSString *gLogFilePath = nil;

static NSString * logFilePath(void) {
    if (gLogFilePath) return gLogFilePath;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = paths.firstObject ?: NSTemporaryDirectory();
    gLogFilePath = [docDir stringByAppendingPathComponent:@"BaiduPanTroll.log"];
    return gLogFilePath;
}

static void writeLogToFile(NSString *msg) {
    if (!msg) return;
    NSString *path = logFilePath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    NSNumber *fileSize = attrs[NSFileSize];
    if (fileSize && [fileSize unsignedLongLongValue] > 500 * 1024) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [[NSDate date] description], msg];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#define DLog(fmt, ...) do { \
    NSString *_msg = [NSString stringWithFormat:@"[BaiduPanTroll] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _msg); \
    writeLogToFile(_msg); \
} while(0)

// ===== GLOBAL STATE =====
static NSString *gCurrentPath = nil, *gBdstoken = nil, *gBDUSS = nil;
static UIButton *gFloatButton = nil;
static NSString *gPendingRestoreFileId = nil, *gPendingRestorePdfPath = nil, *gPendingRestoreOriginalName = nil;
static NSTimer *gTapDetectionTimer = nil;
static NSInteger gNavStackCount = 0;
static BOOL gIsWaitingForTap = NO, gHasOpenedFile = NO, gHasRestored = NO, gHasClicked = NO;
static NSString *gInitialTopVCClass = nil, *gInitialTopVCTitle = nil;

// ===== FORWARD DECLS =====
static UIWindow * keyWindow(void);
static UINavigationController * findNavController(UIViewController *vc);
static UIViewController * topViewController(void);
static NSInteger currentNavStackCount(void);
static NSString * strictEncodeURIComponent(NSString *str);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static void autoDetectPathAndToken(void);
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void showToast(NSString *msg);
static void forceRefreshFileList(void);
static void startTapDetection(void);
static void stopTapDetection(void);
static void checkIfFileOpened(void);
static void executeRestore(void);
static void executeRestoreWithoutRefresh(void (^completion)(BOOL success));
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);
static void showLogViewer(void);

static UIScrollView * findListViewGlobally(void);
static NSIndexPath * searchFileInListView(NSString *targetName, UIScrollView *listView);
static UIView * cellAtIndexPath(UIScrollView *listView, NSIndexPath *path);
static void scrollToIndexPath(UIScrollView *listView, NSIndexPath *path);
static void selectIndexPath(UIScrollView *listView, NSIndexPath *path);
static void performScrollAttempt(NSString *ppName, UIScrollView *listView, NSInteger attempt, NSInteger maxAttempts, CGFloat scrollStep);
static void scrollToRenamedFileAndAutoClick(NSString *ppName);
static void autoClickVisibleCell(NSString *ppName, UIScrollView *listView);
static NSString * topVCClassName(void);
static NSString * topVCTitle(void);
static NSString * detectCurrentPathFromVC(UIViewController *vc);

// ===== WINDOW / NAV HELPERS =====

static UIWindow * keyWindow(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = scene.windows.firstObject; break;
            }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    return window;
}

static UINavigationController * findNavController(UIViewController *vc) {
    if (!vc) return nil;
    if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController *)vc;
    if (vc.navigationController) return vc.navigationController;
    UIWindow *window = keyWindow();
    if (!window || !window.rootViewController) return nil;
    UIViewController *root = window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) return (UINavigationController *)root;
    if ([root isKindOfClass:[UITabBarController class]]) {
        UIViewController *sel = [(UITabBarController *)root selectedViewController];
        if ([sel isKindOfClass:[UINavigationController class]]) return (UINavigationController *)sel;
    }
    return nil;
}

static UIViewController * topViewController(void) {
    UIWindow *window = keyWindow();
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
    UINavigationController *nav = findNavController(topViewController());
    return nav ? nav.viewControllers.count : 1;
}

static NSString * strictEncodeURIComponent(NSString *str) {
    if (!str) return @"";
    NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
    [cs addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

// ===== NETWORK =====

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
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { handler(nil, error); return; }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            handler(json, nil);
        });
    }];
    [task resume];
}

// ===== PATH DETECTION from VC =====

static NSString * detectCurrentPathFromVC(UIViewController *vc) {
    if (!vc) return @"/";

    // Try to read path from VC properties
    NSArray *pathKeys = @[@"currentPath", @"path", @"dirPath", @"folderPath", @"currentDir", @"currentFolder"];
    for (NSString *key in pathKeys) {
        @try {
            id val = [vc valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                DLog(@"Detected path from VC.%@: %@", key, val);
                return val;
            }
        } @catch (NSException *e) {}
    }

    // Try to get from navigation item title (folder name)
    NSString *title = vc.title ?: vc.navigationItem.title;
    if (title && title.length > 0 && ![title isEqualToString:@"文件"]) {
        DLog(@"Using nav title as path hint: %@", title);
    }

    // Try to get from VC's data model
    @try {
        id fileListModel = [vc valueForKey:@"fileListModel"];
        if (fileListModel) {
            id path = [fileListModel valueForKey:@"path"];
            if ([path isKindOfClass:[NSString class]] && [(NSString *)path length] > 0) {
                DLog(@"Detected path from fileListModel.path: %@", path);
                return path;
            }
        }
    } @catch (NSException *e) {}

    @try {
        id viewModel = [vc valueForKey:@"viewModel"];
        if (viewModel) {
            id path = [viewModel valueForKey:@"path"];
            if ([path isKindOfClass:[NSString class]] && [(NSString *)path length] > 0) {
                DLog(@"Detected path from viewModel.path: %@", path);
                return path;
            }
        }
    } @catch (NSException *e) {}

    // Try to get from NSUserDefaults known path keys
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *defaultsPathKeys = @[@"current_path", @"currentPath", @"last_path", @"lastPath", @"pan_current_path"];
    for (NSString *key in defaultsPathKeys) {
        id val = [defaults objectForKey:key];
        if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
            DLog(@"Detected path from NSUserDefaults.%@: %@", key, val);
            return val;
        }
    }

    return @"/";
}

// ===== TOKEN / PATH DETECTION (with caching) =====

static void autoDetectPathAndToken(void) {
    // Always re-detect path, but cache token
    UIViewController *vc = topViewController();
    NSString *detectedPath = detectCurrentPathFromVC(vc);
    if (detectedPath) gCurrentPath = detectedPath;

    if (gBdstoken && gBDUSS) {
        DLog(@"Using cached token and BDUSS, path=%@", gCurrentPath);
        return;
    }
    DLog(@"Starting auto-detection... path=%@", gCurrentPath);
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Try known keys first
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN", @"access_token", @"bd_token", @"pan_token"];
    for (NSString *key in tokenKeys) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            if (str.length == 32) {
                NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
                NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, 32)] == 1 &&
                    [letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, 32)] > 0) {
                    gBdstoken = str;
                    DLog(@"Got bdstoken from key: %@", key);
                    break;
                }
            }
        }
    }

    // Fallback: scan all defaults but filter out non-token keys
    if (!gBdstoken) {
        NSDictionary *allDefaults = [defaults dictionaryRepresentation];
        NSArray *blacklistKeys = @[@"password", @"passwd", @"secret", @"credit", @"card", @"phone", @"mobile", @"email", @"address", @"turing", @"shield", @"cms", @"blob", @"md5", @"sha", @"hash", @"uuid", @"device", @"identifier", @"idfa", @"idfv", @"push", @"firebase", @"crashlytics", @"bugly", @"umeng"];
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
                if (str.length == 32) {
                    NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
                    NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                    if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, 32)] == 1 &&
                        [letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, 32)] > 0) {
                        gBdstoken = str;
                        DLog(@"Found bdstoken in '%@': %@...", key, [str substringToIndex:8]);
                        break;
                    }
                }
            }
        }
    }

    if (!gBdstoken) DLog(@"WARNING: No token detected");

    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) { gBDUSS = cookie.value; DLog(@"Got BDUSS from cookie"); break; }
    }
    if (!gBDUSS) { gBDUSS = [defaults objectForKey:@"BDUSS"]; if (gBDUSS) DLog(@"Got BDUSS from NSUserDefaults"); }

    NSString *tokenPreview = gBdstoken ? [gBdstoken substringToIndex:MIN(8, gBdstoken.length)] : @"missing";
    DLog(@"Path: %@ | Token: %@ | BDUSS: %@", gCurrentPath, tokenPreview, gBDUSS ? @"OK" : @"missing");
}

// ===== API CALLS =====

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
    DLog(@"RENAME: %@ -> %@", path, newName);
    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded; charset=UTF-8",
        @"X-Requested-With": @"XMLHttpRequest"
    };
    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) { DLog(@"RENAME error: %@", err); completion(NO, err); return; }
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

// ===== UI HELPERS =====

static void showToast(NSString *msg) {
    UIWindow *window = keyWindow();
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [toast removeFromSuperview];
    });
}

// ===== REFRESH SYSTEM =====

static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) { DLog(@"No top VC for refresh"); return; }
    DLog(@"Refreshing top VC: %@", NSStringFromClass([vc class]));

    // Try BaiduPan specific refresh methods first
    NSArray *baiduRefreshMethods = @[
        @"refreshFileList", @"reloadFileList", @"updateFileList",
        @"refreshData", @"reloadData", @"updateData",
        @"requestFileList", @"fetchFileList", @"loadFileList",
        @"refresh", @"reload", @"update",
        @"requestData", @"loadData", @"fetchData",
        @"beginRefreshing", @"beginRefresh:",
        @"refreshContent", @"reloadContent", @"updateContent"
    ];
    for (NSString *selName in baiduRefreshMethods) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC refresh method: %@", selName);
            _Pragma("clang diagnostic push")
            _Pragma("clang diagnostic ignored \"-Warc-performSelector-leaks\"")
            [vc performSelector:sel];
            _Pragma("clang diagnostic pop")
            return;
        }
    }

    // Try reloadData on table/collection view directly
    if ([vc.view isKindOfClass:[UITableView class]]) { [(UITableView *)vc.view reloadData]; return; }
    if ([vc.view isKindOfClass:[UICollectionView class]]) { [(UICollectionView *)vc.view reloadData]; return; }

    // Search subviews for list view
    UIScrollView *listView = findListViewGlobally();
    if ([listView isKindOfClass:[UITableView class]]) { [(UITableView *)listView reloadData]; return; }
    if ([listView isKindOfClass:[UICollectionView class]]) { [(UICollectionView *)listView reloadData]; return; }

    // Try UIRefreshControl
    if (listView && listView.refreshControl) {
        [listView.refreshControl beginRefreshing];
        listView.contentOffset = CGPointMake(listView.contentOffset.x, -listView.refreshControl.frame.size.height);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [listView.refreshControl endRefreshing];
        });
        return;
    }

    DLog(@"No refresh method found");
}

// ===== LIST VIEW OPERATIONS =====

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

static NSIndexPath * searchFileInListView(NSString *targetName, UIScrollView *listView) {
    if (!targetName || !listView) return nil;
    NSInteger totalSections = 1;

    if ([listView isKindOfClass:[UITableView class]]) {
        UITableView *tv = (UITableView *)listView;
        @try { totalSections = [tv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger section = 0; section < totalSections; section++) {
            NSInteger rows = 0;
            @try { rows = [tv numberOfRowsInSection:section]; } @catch (NSException *e) {}
            for (NSInteger row = rows - 1; row >= 0; row--) {
                NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
                @try {
                    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                    if (cell && viewContainsText(cell, targetName)) {
                        DLog(@"Found table cell [%ld,%ld]", (long)row, (long)section);
                        return ip;
                    }
                } @catch (NSException *e) {}
            }
        }
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)listView;
        @try { totalSections = [cv numberOfSections]; } @catch (NSException *e) {}
        for (NSInteger section = 0; section < totalSections; section++) {
            NSInteger items = 0;
            @try { items = [cv numberOfItemsInSection:section]; } @catch (NSException *e) {}
            for (NSInteger item = items - 1; item >= 0; item--) {
                NSIndexPath *ip = [NSIndexPath indexPathForItem:item inSection:section];
                // For UICollectionView, cellForItemAtIndexPath only returns VISIBLE cells
                // We need to check visible cells instead
                @try {
                    UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                    if (cell && viewContainsText(cell, targetName)) {
                        DLog(@"Found collection cell [%ld,%ld]", (long)item, (long)section);
                        return ip;
                    }
                } @catch (NSException *e) {}
            }
            // Also check all visible cells for this section
            for (UICollectionViewCell *cell in [cv visibleCells]) {
                NSIndexPath *vip = [cv indexPathForCell:cell];
                if (vip && vip.section == section && viewContainsText(cell, targetName)) {
                    DLog(@"Found visible collection cell [%ld,%ld]", (long)vip.item, (long)vip.section);
                    return vip;
                }
            }
        }
    }
    return nil;
}

static UIView * cellAtIndexPath(UIScrollView *listView, NSIndexPath *path) {
    if ([listView isKindOfClass:[UITableView class]]) {
        return [(UITableView *)listView cellForRowAtIndexPath:path];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)listView;
        // cellForItemAtIndexPath only returns visible cells for UICollectionView
        // We need to scroll first to make it visible
        return [cv cellForItemAtIndexPath:path];
    }
    return nil;
}

static void scrollToIndexPath(UIScrollView *listView, NSIndexPath *path) {
    if ([listView isKindOfClass:[UITableView class]]) {
        [(UITableView *)listView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)listView scrollToItemAtIndexPath:path atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
    }
}

static void selectIndexPath(UIScrollView *listView, NSIndexPath *path) {
    if ([listView isKindOfClass:[UITableView class]]) {
        id delegate = [(UITableView *)listView delegate];
        SEL didSelect = @selector(tableView:didSelectRowAtIndexPath:);
        if (delegate && [delegate respondsToSelector:didSelect]) {
            DLog(@"Calling tableView:didSelectRowAtIndexPath:");
            _Pragma("clang diagnostic push")
            _Pragma("clang diagnostic ignored \"-Warc-performSelector-leaks\"")
            [delegate performSelector:didSelect withObject:listView withObject:path];
            _Pragma("clang diagnostic pop")
        }
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        id delegate = [(UICollectionView *)listView delegate];
        SEL didSelect = @selector(collectionView:didSelectItemAtIndexPath:);
        if (delegate && [delegate respondsToSelector:didSelect]) {
            DLog(@"Calling collectionView:didSelectItemAtIndexPath:");
            _Pragma("clang diagnostic push")
            _Pragma("clang diagnostic ignored \"-Warc-performSelector-leaks\"")
            [delegate performSelector:didSelect withObject:listView withObject:path];
            _Pragma("clang diagnostic pop")
        }
    }
}

static void autoClickVisibleCell(NSString *ppName, UIScrollView *listView) {
    if (!ppName || !listView) return;

    // For UICollectionView, we need to check visible cells first
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)listView;
        for (UICollectionViewCell *cell in [cv visibleCells]) {
            if (viewContainsText(cell, ppName)) {
                foundPath = [cv indexPathForCell:cell];
                DLog(@"Found visible UICollectionViewCell at [%ld,%ld]", (long)foundPath.item, (long)foundPath.section);
                break;
            }
        }
    }

    if (!foundPath) {
        foundPath = searchFileInListView(ppName, listView);
    }

    if (!foundPath) { DLog(@"Cell not visible, will retry..."); return; }

    if (!gHasRestored && gPendingRestoreFileId && gPendingRestorePdfPath && gPendingRestoreOriginalName) {
        gHasRestored = YES;
        showToast(@"4. 恢复原名...");
        executeRestoreWithoutRefresh(^(BOOL success) {
            if (success) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    showToast(@"5. 自动打开文件...");
                    autoClickVisibleCell(ppName, listView);
                });
            } else {
                showToast(@"恢复原名失败，取消自动打开");
            }
        });
        return;
    }

    if (gHasClicked) { DLog(@"Already clicked, skipping"); return; }
    gHasClicked = YES;

    UIView *visibleCell = cellAtIndexPath(listView, foundPath);
    if (!visibleCell) { 
        DLog(@"Cell at %@ not visible yet, will retry", foundPath); 
        gHasClicked = NO; 
        return; 
    }

    DLog(@"Cell VISIBLE, auto-clicking...");
    showToast(@"正在自动打开文件...");
    selectIndexPath(listView, foundPath);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            [[UIApplication sharedApplication] sendAction:@selector(touchesEnded:withEvent:) to:visibleCell from:nil forEvent:nil];
            DLog(@"Sent action via UIApplication");
        } @catch (NSException *e) {}
    });
}

static void performScrollAttempt(NSString *ppName, UIScrollView *listView, NSInteger attempt, NSInteger maxAttempts, CGFloat scrollStep) {
    if (attempt >= maxAttempts) { DLog(@"Max scroll attempts reached"); showToast(@"未找到文件，请手动查找"); return; }
    CGFloat currentY = listView.contentOffset.y;
    CGFloat targetY = currentY + scrollStep;
    CGFloat maxY = listView.contentSize.height - listView.bounds.size.height;
    if (maxY < 0) maxY = 0;
    if (targetY > maxY) targetY = maxY;
    DLog(@"Scroll %ld: %.0f -> %.0f (max %.0f)", (long)attempt, currentY, targetY, maxY);
    if (targetY <= currentY && attempt > 0) { DLog(@"At bottom, stopping"); showToast(@"已滚动到底部，未找到文件"); return; }
    listView.contentOffset = CGPointMake(0, targetY);

    // Wait longer for UICollectionView to layout cells
    CGFloat delay = [listView isKindOfClass:[UICollectionView class]] ? 0.5 : 0.2;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoClickVisibleCell(ppName, listView);
        NSIndexPath *foundPath = nil;
        if ([listView isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)listView;
            for (UICollectionViewCell *cell in [cv visibleCells]) {
                if (viewContainsText(cell, ppName)) {
                    foundPath = [cv indexPathForCell:cell];
                    break;
                }
            }
        }
        if (!foundPath) foundPath = searchFileInListView(ppName, listView);
        if (foundPath) { DLog(@"File found at attempt %ld", (long)attempt); return; }
        if (targetY >= maxY && maxY >= 0) { showToast(@"已滚动到底部，未找到文件"); return; }
        showToast([NSString stringWithFormat:@"继续查找... (%ld/%ld)", (long)(attempt + 1), (long)maxAttempts]);
        performScrollAttempt(ppName, listView, attempt + 1, maxAttempts, scrollStep);
    });
}

static void scrollToRenamedFileAndAutoClick(NSString *ppName) {
    if (!ppName) return;
    DLog(@"v10.37 Scrolling to: %@", ppName);
    UIScrollView *listView = findListViewGlobally();
    if (!listView) { DLog(@"No list view found"); showToast(@"未找到文件列表"); return; }
    DLog(@"Found list: %@", NSStringFromClass([listView class]));

    // First try to find in visible cells (especially for UICollectionView)
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)listView;
        for (UICollectionViewCell *cell in [cv visibleCells]) {
            if (viewContainsText(cell, ppName)) {
                foundPath = [cv indexPathForCell:cell];
                DLog(@"Found in visible UICollectionViewCell at [%ld,%ld]", (long)foundPath.item, (long)foundPath.section);
                break;
            }
        }
    }

    if (!foundPath) {
        foundPath = searchFileInListView(ppName, listView);
    }

    if (foundPath) {
        DLog(@"File visible, scrolling to position...");
        scrollToIndexPath(listView, foundPath);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            autoClickVisibleCell(ppName, listView);
        });
        return;
    }
    DLog(@"File not visible, starting scroll search...");
    showToast(@"正在查找并自动打开文件...");
    listView.contentOffset = CGPointZero;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        performScrollAttempt(ppName, listView, 0, 20, MAX(listView.bounds.size.height * 0.5, 80));
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

// ===== RESTORE & DETECTION =====

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        stopTapDetection(); return;
    }
    DLog(@"Restoring: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) { showToast(@"✅ 已自动恢复原名"); forceRefreshFileList(); }
        else { showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]); }
        gPendingRestoreFileId = nil; gPendingRestorePdfPath = nil; gPendingRestoreOriginalName = nil;
        gIsWaitingForTap = NO; gHasOpenedFile = NO;
    });
}

static void executeRestoreWithoutRefresh(void (^completion)(BOOL success)) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        if (completion) completion(NO); return;
    }
    DLog(@"Restore (no refresh): %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) DLog(@"Restore success");
        else { DLog(@"Restore failed: %@", e); showToast([NSString stringWithFormat:@"恢复原名失败: %@", e.localizedDescription]); }
        if (completion) completion(ok);
    });
}

static void stopTapDetection(void) {
    if (gTapDetectionTimer) { [gTapDetectionTimer invalidate]; gTapDetectionTimer = nil; }
    gIsWaitingForTap = NO; gHasOpenedFile = NO;
}

static void checkIfFileOpened(void) {
    if (!gIsWaitingForTap) return;
    NSInteger currentCount = currentNavStackCount();
    NSString *currentClass = topVCClassName();
    NSString *currentTitle = topVCTitle();
    DLog(@"TapCheck: nav=%ld->%ld class=[%@]->[%@] title=[%@]->[%@] opened=%d",
         (long)gNavStackCount, (long)currentCount, gInitialTopVCClass, currentClass,
         gInitialTopVCTitle, currentTitle, gHasOpenedFile);
    if (!gHasOpenedFile) {
        BOOL opened = NO;
        if (currentCount > gNavStackCount) { DLog(@"Opened (nav increased)!"); opened = YES; }
        else if (gInitialTopVCClass && ![gInitialTopVCClass isEqualToString:currentClass]) { DLog(@"Opened (class changed)!"); opened = YES; }
        else if (currentTitle && ([currentTitle containsString:@"预览"] || [currentTitle containsString:@"下载"] || [currentTitle containsString:@"文件详情"])) { DLog(@"Opened (preview title)!"); opened = YES; }
        else if (gPendingRestoreOriginalName && currentTitle && [currentTitle containsString:gPendingRestoreOriginalName]) { DLog(@"Opened (title match)!"); opened = YES; }
        if (opened) {
            gHasOpenedFile = YES;
            showToast(@"已进入下载界面，马上恢复原名...");
            if (gTapDetectionTimer) { [gTapDetectionTimer invalidate]; gTapDetectionTimer = nil; }
            executeRestore();
        }
    }
}

static void startTapDetection(void) {
    stopTapDetection();
    gIsWaitingForTap = YES; gHasOpenedFile = NO;
    gNavStackCount = currentNavStackCount();
    gInitialTopVCClass = topVCClassName();
    gInitialTopVCTitle = topVCTitle();
    DLog(@"Tap detection started: nav=%ld class=%@ title=%@", (long)gNavStackCount, gInitialTopVCClass, gInitialTopVCTitle);
    gTapDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                            target:[NSBlockOperation blockOperationWithBlock:^{ checkIfFileOpened(); }]
                                                          selector:@selector(main)
                                                          userInfo:nil
                                                           repeats:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gIsWaitingForTap) {
            DLog(@"Tap detection timeout");
            stopTapDetection();
            showToast(@"等待超时，自动恢复原名");
            executeRestore();
        }
    });
}

// ===== MAIN FLOW =====

static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize) {
    stopTapDetection();
    gPendingRestoreFileId = nil; gPendingRestorePdfPath = nil; gPendingRestoreOriginalName = nil;
    gHasRestored = NO; gHasClicked = NO;
    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"88888888888888"]) { showToast(@"文件已是 .8888888888888888，无需处理"); return; }
    NSString *ppName = [fileName stringByAppendingString:@".8888888888888888"];
    NSString *ppPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName];
    showToast(@"1. 重命名...");
    renameFile(fileId, filePath, ppName, ^(BOOL success, NSError *err) {
        if (!success) { showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]); return; }
        gPendingRestoreFileId = fileId; gPendingRestorePdfPath = ppPath; gPendingRestoreOriginalName = fileName;
        showToast(@"2. 刷新列表...");
        forceRefreshFileList();

        // For UICollectionView, need longer wait for layout
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *listView = findListViewGlobally();
            if ([listView isKindOfClass:[UITableView class]]) {
                [(UITableView *)listView reloadData];
                DLog(@"reloadData on UITableView");
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                [(UICollectionView *)listView reloadData];
                DLog(@"reloadData on UICollectionView");
            }

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                showToast(@"3. 滚动到文件...");
                scrollToRenamedFileAndAutoClick(ppName);
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();
    if (!gBdstoken) { showToast(@"未检测到登录状态"); return; }
    showToast(@"正在获取文件列表...");
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err) { DLog(@"fetchFileList error: %@", err); showToast([NSString stringWithFormat:@"获取失败: %@", err.localizedDescription]); return; }
        if (!files || files.count == 0) { showToast(@"文件夹为空"); return; }
        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }
        if (fileItems.count == 0) { showToast(@"当前文件夹没有可下载的文件"); return; }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                       message:@"选择后自动重命名并快速打开"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *fid = [file[@"fs_id"] stringValue];
            NSString *path = file[@"path"];
            NSString *title = name;
            if (size) { double mb = [size doubleValue] / (1024.0 * 1024.0); title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb]; }
            BOOL isTooLarge = (size && [size doubleValue] >= 300.0 * 1024.0 * 1024.0);
            UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                runSmartFlow(name, path, fid, size);
            }];
            if (isTooLarge) [action setValue:@NO forKey:@"enabled"];
            [sheet addAction:action];
        }
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
        [sheet addAction:cancelAction];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = topViewController();
            if (vc) {
                if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                    sheet.popoverPresentationController.sourceView = vc.view;
                    sheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
                }
                [vc presentViewController:sheet animated:YES completion:nil];
            } else { DLog(@"No top VC for action sheet"); showToast(@"无法弹出选择界面"); }
        });
    });
}

// ===== LOG VIEWER =====

static void showLogViewer(void) {
    NSString *path = logFilePath();
    NSString *content = @"";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    }
    if (content.length == 0) content = @"暂无日志";

    // 创建自定义日志查看控制器（带导航栏，可滚动）
    BDTLogViewController *logVC = [[BDTLogViewController alloc] init];
    logVC.title = @"运行日志";
    logVC.logContent = content;

    // 包装在 UINavigationController 中
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];

    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:nav animated:YES completion:nil];
}

@interface BDTLogViewController : UIViewController
@property (nonatomic, copy) NSString *logContent;
@end

@implementation BDTLogViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];

    // 创建 UITextView 显示日志（可滚动）
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    textView.text = self.logContent;
    textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:textView];

    // 创建导航栏按钮
    UIBarButtonItem *copyItem = [[UIBarButtonItem alloc] initWithTitle:@"复制全部" style:UIBarButtonItemStylePlain target:self action:@selector(copyLogTapped:)];
    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearLogTapped:)];
    self.navigationItem.leftBarButtonItem = copyItem;
    self.navigationItem.rightBarButtonItems = @[clearItem];
}
- (void)copyLogTapped:(id)sender {
    NSString *path = logFilePath();
    NSString *full = @"";
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        full = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    }
    [[UIPasteboard generalPasteboard] setString:full];
    showToast(@"日志已复制到剪贴板");
}
- (void)clearLogTapped:(id)sender {
    NSString *path = logFilePath();
    [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    showToast(@"日志已清空");
    [self dismissViewControllerAnimated:YES completion:nil];
}
@end

// ===== FLOAT BUTTON =====

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = @"missing";
    if (gBdstoken) {
        NSUInteger len = gBdstoken.length, previewLen = MIN(8, len);
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v10.37"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n快速流程：改名->刷新->滚动->恢复原名->自动点击", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ triggerDownloadFlow(); });
    }];
    UIAlertAction *logAction = [UIAlertAction actionWithTitle:@"查看日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { showLogViewer(); }];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:downloadAction];
    [alert addAction:logAction];
    [alert addAction:okAction];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void showFloatButton(void) {
    if (gFloatButton) return;
    UIWindow *window = keyWindow();
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
    DLog(@"BaiduPan Troll v10.37 loaded - Path detection + UICollectionView fix");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
