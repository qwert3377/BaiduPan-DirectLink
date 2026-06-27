//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v9.0
//  Feature: Added internal app download trigger for large files (>50MB)
//  Fix: objc_setAssociatedObject key type (const void*), removed hardcoded fallback token
//  Fix v8.3: Replaced private API KVC with standard addTextFieldWithConfigurationHandler
//            Removed LinkCopyButton subclass to avoid UIButton class-cluster crash
//            Added __weak reference for progressAlert to prevent use-after-free
//  Fix v8.4: "再次复制" now also restores original filename in one step
//            Skip rename if file is already .pdf
//  Token source: auto-detected from app only (NSUserDefaults + memory scan)
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// ========== 文件大小阈值 ==========
static const long long kDirectLinkSizeLimit = 50 * 1024 * 1024; // 50MB

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

static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    NSArray *refreshSelectors = @[@"refreshData", @"reloadData", @"refreshFileList", @"loadData", @"requestData", @"fetchFileList", @"reloadFileList"];
    for (NSString *selName in refreshSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC refresh method: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            return;
        }
    }
    if ([vc.view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)vc.view;
        if (sv.refreshControl) {
            [sv.refreshControl beginRefreshing];
            sv.contentOffset = CGPointMake(0, -sv.refreshControl.frame.size.height);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [sv.refreshControl endRefreshing]; });
        }
    }
}

// ========== v9.0 新增：调用客户端内部下载 ==========

// 格式化文件大小
static NSString * formatFileSize(long long bytes) {
    if (bytes < 1024) return [NSString stringWithFormat:@"%lld B", bytes];
    if (bytes < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", bytes / 1024.0];
    if (bytes < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024.0 * 1024.0)];
}

// 在视图中查找并触发下载按钮（递归）
static void findAndTriggerDownloadButtonInView(UIView *view, NSString *targetFileName);

// 尝试调用客户端内部下载方法
static void triggerInternalDownload(NSString *filePath, NSString *fileName, NSString *fileId, long long fileSize) {
    DLog(@"Triggering internal download for: %@ (size: %@)", fileName, formatFileSize(fileSize));

    // 方案1: 尝试发送内部通知触发下载
    @try {
        NSArray *possibleNotifs = @[
            @"BDPanFileDownloadStartNotification",
            @"BDPanDownloadTaskAddNotification",
            @"netdisk.download.start",
            @"com.baidu.netdisk.download.start",
            @"BDPanDownloadAddTask",
        ];

        NSMutableDictionary *userInfo = [@{
            @"path": filePath ?: @"",
            @"fileName": fileName ?: @"",
            @"fs_id": fileId ?: @"",
            @"size": @(fileSize),
            @"isInternal": @YES
        } mutableCopy];

        if (gBdstoken) userInfo[@"bdstoken"] = gBdstoken;
        if (gBDUSS) userInfo[@"BDUSS"] = gBDUSS;

        for (NSString *notifName in possibleNotifs) {
            [[NSNotificationCenter defaultCenter] postNotificationName:notifName object:nil userInfo:userInfo];
        }
        DLog(@"Posted internal download notifications");
    } @catch (NSException *e) {
        DLog(@"Notification post failed: %@", e);
    }

    // 方案2: 尝试通过 performSelector 调用 AppDelegate 或下载管理器的方法
    @try {
        id appDelegate = [[UIApplication sharedApplication] delegate];
        NSArray *possibleSelectors = @[
            @"startDownloadFile:",
            @"addDownloadTask:",
            @"downloadFileWithPath:",
            @"startDownloadWithInfo:",
            @"bdpan_startDownload:",
        ];

        for (NSString *selName in possibleSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([appDelegate respondsToSelector:sel]) {
                DLog(@"Found download selector on AppDelegate: %@", selName);
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [appDelegate performSelector:sel withObject:@{@"path": filePath, @"fileName": fileName, @"fs_id": fileId}];
                #pragma clang diagnostic pop
                showToast(@"已触发客户端下载！");
                return;
            }
        }
    } @catch (NSException *e) {
        DLog(@"AppDelegate download trigger failed: %@", e);
    }

    // 方案3: 尝试查找 BDPanDownloadManager 或类似类
    @try {
        NSArray *possibleClasses = @[@"BDPanDownloadManager", @"BDPanDownloadTaskManager", @"NetdiskDownloadManager", @"BDFileDownloadManager"];
        for (NSString *className in possibleClasses) {
            Class mgrClass = NSClassFromString(className);
            if (mgrClass) {
                DLog(@"Found download manager class: %@", className);
                id sharedInstance = nil;
                if ([mgrClass respondsToSelector:@selector(sharedManager)]) {
                    sharedInstance = [mgrClass performSelector:@selector(sharedManager)];
                } else if ([mgrClass respondsToSelector:@selector(sharedInstance)]) {
                    sharedInstance = [mgrClass performSelector:@selector(sharedInstance)];
                } else if ([mgrClass respondsToSelector:@selector(defaultManager)]) {
                    sharedInstance = [mgrClass performSelector:@selector(defaultManager)];
                }

                if (sharedInstance) {
                    NSArray *possibleMethods = @[
                        @"addDownloadTask:",
                        @"startDownload:",
                        @"downloadFile:",
                        @"addTaskWithPath:",
                    ];
                    for (NSString *methodName in possibleMethods) {
                        SEL sel = NSSelectorFromString(methodName);
                        if ([sharedInstance respondsToSelector:sel]) {
                            DLog(@"Calling %@.%@", className, methodName);
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [sharedInstance performSelector:sel withObject:@{@"path": filePath, @"fileName": fileName}];
                            #pragma clang diagnostic pop
                            showToast(@"已触发客户端下载！");
                            return;
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        DLog(@"Download manager trigger failed: %@", e);
    }

    // 方案4: 尝试通过 UI 模拟点击下载按钮
    @try {
        UIViewController *vc = topViewController();
        if (vc) {
            findAndTriggerDownloadButtonInView(vc.view, fileName);
        }
    } @catch (NSException *e) {
        DLog(@"UI simulation failed: %@", e);
    }

    showToast(@"已尝试触发客户端下载，请检查下载列表");
}

// 在视图中查找并触发下载按钮
static void findAndTriggerDownloadButtonInView(UIView *view, NSString *targetFileName) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            if (label.text && [label.text containsString:targetFileName]) {
                UIView *parent = label.superview;
                while (parent && parent != view) {
                    for (UIView *sibling in parent.subviews) {
                        if ([sibling isKindOfClass:[UIButton class]]) {
                            UIButton *btn = (UIButton *)sibling;
                            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                            DLog(@"Triggered download button for %@", targetFileName);
                            return;
                        }
                    }
                    parent = parent.superview;
                }
            }
        }
        findAndTriggerDownloadButtonInView(subview, targetFileName);
    }
}

// 恢复文件名并触发内部下载
static void restoreNameAndTriggerDownload(NSString *fileId, NSString *pdfPath, NSString *originalName) {
    renameFile(fileId, pdfPath, originalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            DLog(@"Restored name to %@, triggering internal download...", originalName);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                forceRefreshFileList();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    UIViewController *vc = topViewController();
                    if (vc) findAndTriggerDownloadButtonInView(vc.view, originalName);
                });
            });
        } else {
            DLog(@"Restore failed: %@", e.localizedDescription);
            showToast(@"恢复文件名失败");
        }
    });
}

// ========== v9.0 UI Dialog ==========

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath, BOOL needsRestore, long long fileSize) {
    NSString *sizeStr = formatFileSize(fileSize);
    BOOL isLargeFile = fileSize > kDirectLinkSizeLimit;

    NSString *title = isLargeFile ? @"文件较大，建议使用客户端下载" : @"直链已复制";
    NSString *message = [NSString stringWithFormat:@"%@ (%@)\n\n%@", fileName, sizeStr,
                         isLargeFile ? @"该文件超过50MB，直链可能无法下载。建议：\n1. 使用客户端下载（支持大文件、断点续传）\n2. 或复制直链到支持大文件的下载工具" : @"直链已复制到剪贴板。\n可使用 IDM、Aria2、Motrix 等工具粘贴下载。"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
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
        if (isLargeFile) {
            [alert addAction:[UIAlertAction actionWithTitle:@"📥 客户端下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                showToast(@"正在恢复文件名并触发下载...");
                restoreNameAndTriggerDownload(fileId, pdfPath, fileName);
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"📋 复制直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                copyToClipboard(link);
                showToast(@"直链已复制！");
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"保持pdf后缀" style:UIAlertActionStyleCancel handler:nil]];
        } else {
            [alert addAction:[UIAlertAction actionWithTitle:@"📋 再次复制并恢复原名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                copyToClipboard(link);
                showToast(@"直链已再次复制！");
                renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                    DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
                });
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"保持pdf后缀" style:UIAlertActionStyleCancel handler:nil]];
        }
    } else {
        if (isLargeFile) {
            [alert addAction:[UIAlertAction actionWithTitle:@"📥 客户端下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                triggerInternalDownload(pdfPath, fileName, fileId, fileSize);
            }]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:@"📋 再次复制" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            copyToClipboard(link);
            showToast(@"直链已再次复制！");
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    }

    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void runRenameAndGetLink(NSString *fileName, NSString *filePath, NSString *fileId, long long fileSize) {
    NSString *ext = fileName.pathExtension.lowercaseString;
    BOOL isAlreadyPDF = [ext isEqualToString:@"pdf"];
    NSString *sizeStr = formatFileSize(fileSize);

    if (isAlreadyPDF) {
        DLog(@"File is already PDF (%@), skipping rename...", sizeStr);
        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"获取直链..." preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *presentVC = topViewController();
        if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

        __weak UIAlertController *weakProgress = progressAlert;

        fetchDirectLink(filePath, ^(NSString *link, NSError *err) {
            [weakProgress dismissViewControllerAnimated:YES completion:^{
                if (err || !link) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
                    return;
                }
                copyToClipboard(link);
                showToast(@"直链已复制到剪贴板！");
                showLinkDialog(link, fileName, fileId, filePath, NO, fileSize);
            }];
        });
        return;
    }

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"1. 重命名文件" preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presentVC = topViewController();
    if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

    __weak UIAlertController *weakProgress = progressAlert;

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            [weakProgress dismissViewControllerAnimated:YES completion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            }];
            return;
        }

        DLog(@"Renamed to %@, refreshing...", pdfName);
        weakProgress.message = @"2. 刷新文件列表...";
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakProgress.message = @"3. 获取直链...";

            fetchDirectLink(pdfPath, ^(NSString *link, NSError *err) {
                [weakProgress dismissViewControllerAnimated:YES completion:^{
                    if (err || !link) {
                        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                            DLog(@"Auto restore: %@", ok ? @"OK" : e.localizedDescription);
                        });
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
                        return;
                    }

                    copyToClipboard(link);
                    showToast(@"直链已复制到剪贴板！");
                    showLinkDialog(link, fileName, fileId, pdfPath, YES, fileSize);
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

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件获取直链/下载" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *fileId = [file[@"fs_id"] stringValue];
            NSString *path = file[@"path"];
            long long fileSize = [size longLongValue];
            NSString *sizeStr = formatFileSize(fileSize);
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, sizeStr];

            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                if (fileSize > kDirectLinkSizeLimit) {
                    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"大文件提示" 
                                                                                     message:[NSString stringWithFormat:@"%@ (%@) 超过50MB，直链可能无法下载。是否直接调用客户端下载？", name, sizeStr]
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                    [confirm addAction:[UIAlertAction actionWithTitle:@"📥 客户端下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        runRenameAndGetLink(name, path, fileId, fileSize);
                    }]];
                    [confirm addAction:[UIAlertAction actionWithTitle:@"📋 仍然获取直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                        runRenameAndGetLink(name, path, fileId, fileSize);
                    }]];
                    [confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                    UIViewController *vc = topViewController();
                    if (vc) [vc presentViewController:confirm animated:YES completion:nil];
                } else {
                    runRenameAndGetLink(name, path, fileId, fileSize);
                }
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v9.0"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 获取直链/下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
    DLog(@"BaiduPan Troll v9.0 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
