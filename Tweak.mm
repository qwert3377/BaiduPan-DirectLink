//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v8.2
//  Fix: objc_setAssociatedObject key type (const void*), removed hardcoded fallback token
//  Token source: auto-detected from app only (NSUserDefaults + memory scan)
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

// ========== v8.2 UI Dialog (Fixed) ==========


// ========== PDF Open Test Methods ==========

static void openPDFWithDocumentInteraction(NSString *filePath) {
    NSURL *fileURL = [NSURL fileURLWithPath:filePath];
    if (!fileURL) {
        showToast(@"文件路径无效");
        return;
    }

    UIViewController *vc = topViewController();
    if (!vc) return;

    UIDocumentInteractionController *docController = [UIDocumentInteractionController interactionControllerWithURL:fileURL];
    docController.delegate = (id<UIDocumentInteractionControllerDelegate>)vc;

    // Try to present preview
    BOOL previewOpened = [docController presentPreviewAnimated:YES];
    if (!previewOpened) {
        // Fallback to open in menu
        CGRect rect = CGRectMake(vc.view.bounds.size.width/2 - 150, vc.view.bounds.size.height/2 - 150, 300, 300);
        [docController presentOpenInMenuFromRect:rect inView:vc.view animated:YES];
    }
}

static void openPDFWithQuickLook(NSString *filePath) {
    // This requires importing QuickLook framework
    // For now, just show a toast indicating we need to test this
    showToast(@"QLPreviewController 需要 QuickLook.framework");
}

static void triggerBaiduPanInternalOpen(NSString *filePath, NSString *fileName, NSString *fileId) {
    // Method 1: Try to find and call BaiduPan's internal file open method
    // This is a guess based on common Baidu naming conventions

    // Try to get the current file list VC
    UIViewController *vc = topViewController();
    if (!vc) return;

    // Look for BaiduPan's file list view controller in the hierarchy
    UIViewController *targetVC = nil;
    for (UIViewController *child in vc.childViewControllers) {
        NSString *className = NSStringFromClass([child class]);
        if ([className containsString:@"File"] || [className containsString:@"List"] || 
            [className containsString:@"Pan"] || [className containsString:@"Disk"]) {
            targetVC = child;
            break;
        }
    }

    if (targetVC) {
        DLog(@"Found potential file VC: %@", NSStringFromClass([targetVC class]));

        // Try to call a method that might open the file
        // Common patterns: openFile:, previewFile:, didSelectFile:, etc.
        SEL selectors[] = {
            NSSelectorFromString(@"openFile:"),
            NSSelectorFromString(@"previewFile:"),
            NSSelectorFromString(@"didSelectFile:"),
            NSSelectorFromString(@"showFilePreview:"),
            NSSelectorFromString(@"openDocument:"),
            NSSelectorFromString(@"previewDocumentWithPath:"),
            NSSelectorFromString(@"handleFileTap:"),
            NSSelectorFromString(@"onFileSelected:"),
            NSSelectorFromString(@"openFileWithId:path:name:"),
            NSSelectorFromString(@"downloadAndOpenFile:"),
        };

        for (int i = 0; i < sizeof(selectors)/sizeof(SEL); i++) {
            if ([targetVC respondsToSelector:selectors[i]]) {
                DLog(@"Found selector: %@", NSStringFromSelector(selectors[i]));
                // Don't actually call it yet, just log it
                showToast([NSString stringWithFormat:@"找到方法: %@", NSStringFromSelector(selectors[i])]);
                return;
            }
        }
    }

    // Fallback: Use UIDocumentInteractionController
    openPDFWithDocumentInteraction(filePath);
}

static void bdtRestoreName(NSString *fileId, NSString *pdfPath, NSString *fileName, UIViewController *overlayVC);

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    UIViewController *vc = topViewController();
    if (!vc) return;

    // Full-screen overlay
    UIViewController *overlayVC = [[UIViewController alloc] init];
    overlayVC.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    overlayVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    overlayVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    // Card container
    CGFloat cardW = MIN(vc.view.bounds.size.width - 32, 340);
    CGFloat margin = 20;
    CGFloat contentW = cardW - margin * 2;
    CGFloat y = 24;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;

    // Title row with close button
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, contentW - 32, 22)];
    titleLabel.text = @"直链已复制";
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.textColor = [UIColor blackColor];
    [card addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(cardW - margin - 24, y - 2, 24, 24);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.4 alpha:1.0] forState:UIControlStateNormal];
    [closeBtn addTarget:overlayVC action:@selector(dismissViewControllerAnimated:completion:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];

    y += 36;

    // File name
    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, contentW, 20)];
    nameLabel.text = [NSString stringWithFormat:@"%@ 的直链已成功复制到剪贴板。", fileName];
    nameLabel.font = [UIFont systemFontOfSize:13];
    nameLabel.textColor = [UIColor darkTextColor];
    nameLabel.numberOfLines = 0;
    [nameLabel sizeToFit];
    CGRect nf = nameLabel.frame;
    nf.size.width = contentW;
    nameLabel.frame = nf;
    [card addSubview:nameLabel];

    y = CGRectGetMaxY(nameLabel.frame) + 16;

    // Link row
    CGFloat linkH = 40;
    CGFloat btnW = 80;
    CGFloat linkW = contentW - btnW - 10;

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(margin, y, linkW, linkH)];
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.layer.borderColor = [UIColor colorWithRed:0.88 green:0.88 blue:0.90 alpha:1.0].CGColor;
    scrollView.layer.borderWidth = 0.5;
    scrollView.layer.cornerRadius = 8;
    scrollView.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:0.99 alpha:1.0];

    UILabel *linkLabel = [[UILabel alloc] init];
    linkLabel.text = link;
    linkLabel.font = [UIFont fontWithName:@"Menlo" size:11];
    linkLabel.textColor = [UIColor colorWithRed:0.20 green:0.40 blue:0.90 alpha:1.0];
    [linkLabel sizeToFit];
    linkLabel.frame = CGRectMake(10, (linkH - linkLabel.frame.size.height) / 2, linkLabel.frame.size.width, linkLabel.frame.size.height);
    scrollView.contentSize = CGSizeMake(linkLabel.frame.size.width + 20, linkH);
    [scrollView addSubview:linkLabel];
    [card addSubview:scrollView];

    // Copy button
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(margin + linkW + 10, y, btnW, linkH);
    [copyBtn setTitle:@"再次复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.48 blue:1.0 alpha:1.0];
    copyBtn.layer.cornerRadius = 8;
    copyBtn.layer.masksToBounds = YES;
    [copyBtn addTarget:nil action:@selector(bdt_copyLinkTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(copyBtn, "linkText", link, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [card addSubview:copyBtn];

    y += linkH + 12;

    // Hint
    UILabel *hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, contentW, 18)];
    hintLabel.text = @"提示：可使用 IDM、Aria2、Motrix 等工具粘贴下载";
    hintLabel.font = [UIFont systemFontOfSize:11];
    hintLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    [card addSubview:hintLabel];

    y += 30;

    // Divider
    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, y, cardW, 0.5)];
    divider.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [card addSubview:divider];

    y += 1;

    // Action buttons row
    CGFloat btnH = 48;

    UIButton *restoreBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    restoreBtn.frame = CGRectMake(0, y, cardW / 2, btnH);
    [restoreBtn setTitle:@"已复制，恢复原名" forState:UIControlStateNormal];
    restoreBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [restoreBtn setTitleColor:[UIColor colorWithRed:0.20 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [restoreBtn addTarget:nil action:@selector(bdt_restoreNameTapped:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(restoreBtn, "fileId", fileId, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, "pdfPath", pdfPath, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, "fileName", fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, "overlayVC", overlayVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [card addSubview:restoreBtn];

    UIView *vDivider = [[UIView alloc] initWithFrame:CGRectMake(cardW / 2, y + 8, 0.5, btnH - 16)];
    vDivider.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [card addSubview:vDivider];

    UIButton *keepBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    keepBtn.frame = CGRectMake(cardW / 2, y, cardW / 2, btnH);
    [keepBtn setTitle:@"保持pdf后缀" forState:UIControlStateNormal];
    keepBtn.titleLabel.font = [UIFont systemFontOfSize:15];
    [keepBtn setTitleColor:[UIColor colorWithRed:0.20 green:0.48 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
    [keepBtn addTarget:overlayVC action:@selector(dismissViewControllerAnimated:completion:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:keepBtn];

    y += btnH;

    card.frame = CGRectMake((vc.view.bounds.size.width - cardW) / 2, (vc.view.bounds.size.height - y) / 2, cardW, y);
    [overlayVC.view addSubview:card];

    // Tap background to dismiss
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:overlayVC action:@selector(dismissViewControllerAnimated:completion:)];
    tap.cancelsTouchesInView = NO;
    [overlayVC.view addGestureRecognizer:tap];

    [vc presentViewController:overlayVC animated:YES completion:nil];
}

static void bdtRestoreName(NSString *fileId, NSString *pdfPath, NSString *fileName, UIViewController *overlayVC) {
    [overlayVC dismissViewControllerAnimated:YES completion:^{
        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
            DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
        });
    }];
}
static void runRenameAndGetLink(NSString *fileName, NSString *filePath, NSString *fileId) {
    // 如果已经是 pdf，跳过改名直接获取直链
    if ([fileName.lowercaseString hasSuffix:@".pdf"]) {
        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"获取直链..." preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *presentVC = topViewController();
        if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

        fetchDirectLink(filePath, ^(NSString *link, NSError *err) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                if (err || !link) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
                    return;
                }
                copyToClipboard(link);
                showToast(@"直链已复制到剪贴板！");
                showLinkDialog(link, fileName, fileId, filePath);
            }];
        });
        return;
    }

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"1. 重命名文件" preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presentVC = topViewController();
    if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            }];
            return;
        }

        DLog(@"Renamed to %@, refreshing...", pdfName);
        progressAlert.message = @"2. 刷新文件列表...";
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            progressAlert.message = @"3. 获取直链...";

            fetchDirectLink(pdfPath, ^(NSString *link, NSError *err) {
                [progressAlert dismissViewControllerAnimated:YES completion:^{
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
                    showLinkDialog(link, fileName, fileId, pdfPath);
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

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件获取直链" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *fileId = [file[@"fs_id"] stringValue];
            NSString *path = file[@"path"];
            NSString *title = name;
            if (size) {
                double mb = [size doubleValue] / (1024.0 * 1024.0);
                title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                runRenameAndGetLink(name, path, fileId);
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v8.2"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 获取直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
- (void)bdt_copyLinkTapped:(id)sender {
    NSString *link = objc_getAssociatedObject(sender, "linkText");
    if (link) {
        copyToClipboard(link);
        showToast(@"直链已复制到剪贴板！");
    }
}
- (void)bdt_restoreNameTapped:(UIButton *)sender {
    NSString *fileId = objc_getAssociatedObject(sender, "fileId");
    NSString *pdfPath = objc_getAssociatedObject(sender, "pdfPath");
    NSString *fileName = objc_getAssociatedObject(sender, "fileName");
    UIView *overlay = objc_getAssociatedObject(sender, "overlay");
    if (overlay) {
        [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 0; } completion:^(BOOL finished) { [overlay removeFromSuperview]; }];
    }
    renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
        DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
    });
}
- (void)bdt_dismissDialog:(id)sender {
    UIView *overlay = nil;
    if ([sender isKindOfClass:[UITapGestureRecognizer class]]) {
        overlay = ((UITapGestureRecognizer *)sender).view;
    } else if ([sender isKindOfClass:[UIButton class]]) {
        overlay = objc_getAssociatedObject(sender, "overlay");
    }
    if (!overlay) {
        // Try to find overlay by looking for the associated object
        if ([sender isKindOfClass:[UIView class]]) {
            overlay = (UIView *)sender;
        }
    }
    if (overlay) {
        [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 0; } completion:^(BOOL finished) { [overlay removeFromSuperview]; }];
    }
}
@end


__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"BaiduPan Troll v8.2 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
