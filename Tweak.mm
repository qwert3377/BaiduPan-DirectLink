//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v8.3
//  Fix: block recursion retain cycles, missing __block specifiers
//  Token source: auto-detected from app only (NSUserDefaults + memory scan)
//  UI: Injected "直链" buttons + "直链已复制" dialog
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
    NSString *filelist = [NSString stringWithFormat:@"[{""id"":%@,""path"":""%@"",""newname"":""%@""}]", fileId, path, newName];
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

// ========== v8.3 UI Dialog (弹窗) ==========

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    UIViewController *vc = topViewController();
    if (!vc) return;

    UIViewController *overlayVC = [[UIViewController alloc] init];
    overlayVC.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    overlayVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
    overlayVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

    CGFloat cardW = MIN(vc.view.bounds.size.width - 32, 340);
    CGFloat margin = 20;
    CGFloat contentW = cardW - margin * 2;
    CGFloat y = 24;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;

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

    UILabel *hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(margin, y, contentW, 18)];
    hintLabel.text = @"提示：可使用 IDM、Aria2、Motrix 等工具粘贴下载";
    hintLabel.font = [UIFont systemFontOfSize:11];
    hintLabel.textColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    [card addSubview:hintLabel];

    y += 30;

    UIView *divider = [[UIView alloc] initWithFrame:CGRectMake(0, y, cardW, 0.5)];
    divider.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    [card addSubview:divider];

    y += 1;

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
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIActionStyleDefault handler:nil]];
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

// ========== UI Injection (File List "直链" Buttons) ==========

static BOOL isBaiduPanFileListPage(void) {
    UIViewController *vc = topViewController();
    if (!vc) return NO;
    NSString *title = vc.title ?: vc.navigationItem.title;
    if (title && ([title containsString:@"百度网盘"] || [title containsString:@"文件"] || [title containsString:@"全部文件"])) return YES;
    NSString *clsName = NSStringFromClass([vc class]);
    if (clsName && ([clsName containsString:@"File"] || [clsName containsString:@"List"] || [clsName containsString:@"Pan"] || [clsName containsString:@"Disk"])) return YES;
    return NO;
}

static BOOL isBaiduPanFileCell(UIView *view) {
    if (![view isKindOfClass:[UITableViewCell class]] && ![view isKindOfClass:[UICollectionViewCell class]]) return NO;

    __block BOOL hasSizeLabel = NO;
    __block BOOL hasNameLabel = NO;

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-retain-cycles"
    void (^__block search)(UIView *) = ^(UIView *v) {
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)sub;
                NSString *text = l.text;
                if (!text || text.length == 0) continue;
                if ([text rangeOfString:@"MB"].location != NSNotFound ||
                    [text rangeOfString:@"GB"].location != NSNotFound ||
                    [text rangeOfString:@"KB"].location != NSNotFound ||
                    [text rangeOfString:@"B"].location != NSNotFound) {
                    hasSizeLabel = YES;
                }
                if ([text isEqualToString:@"打开"] || [text isEqualToString:@"直链"] || [text isEqualToString:@"文件夹"] || [text rangeOfString:@"个文件"].location != NSNotFound) continue;
                if (text.length > 0) hasNameLabel = YES;
            }
            search(sub);
        }
    };
    #pragma clang diagnostic pop
    search(view);
    return hasSizeLabel && hasNameLabel;
}

static NSString * extractFileNameFromCell(UIView *cell) {
    __block UILabel *bestLabel = nil;
    __block CGFloat maxWidth = 0;

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-retain-cycles"
    void (^__block search)(UIView *) = ^(UIView *v) {
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:[UILabel class]]) {
                UILabel *l = (UILabel *)sub;
                NSString *text = l.text;
                if (!text || text.length == 0) continue;
                if ([text rangeOfString:@"MB"].location != NSNotFound ||
                    [text rangeOfString:@"GB"].location != NSNotFound ||
                    [text rangeOfString:@"KB"].location != NSNotFound ||
                    [text isEqualToString:@"打开"] ||
                    [text isEqualToString:@"直链"] ||
                    [text isEqualToString:@"文件夹"] ||
                    [text rangeOfString:@"个文件"].location != NSNotFound) {
                    continue;
                }
                if (l.frame.size.width > maxWidth) {
                    maxWidth = l.frame.size.width;
                    bestLabel = l;
                }
            }
            search(sub);
        }
    };
    #pragma clang diagnostic pop
    search(cell);
    return bestLabel.text;
}

static void injectDirectLinkButtons(void) {
    if (!isBaiduPanFileListPage()) return;

    UIViewController *vc = topViewController();
    if (!vc) return;

    NSMutableArray *scrollViews = [NSMutableArray array];

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-retain-cycles"
    void (^__block findScrollViews)(UIView *) = ^(UIView *v) {
        if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
            [scrollViews addObject:v];
        }
        for (UIView *sub in v.subviews) {
            findScrollViews(sub);
        }
    };
    #pragma clang diagnostic pop
    findScrollViews(vc.view);

    for (UIScrollView *scrollView in scrollViews) {
        NSArray *cells = nil;
        if ([scrollView isKindOfClass:[UITableView class]]) {
            cells = [(UITableView *)scrollView visibleCells];
        } else {
            cells = [(UICollectionView *)scrollView visibleCells];
        }

        for (UIView *cell in cells) {
            if (!isBaiduPanFileCell(cell)) continue;

            NSString *fileName = extractFileNameFromCell(cell);
            if (!fileName || fileName.length == 0) continue;

            UIButton *btn = [cell viewWithTag:0xBDE123];
            if (!btn) {
                btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.tag = 0xBDE123;
                btn.frame = CGRectMake(cell.bounds.size.width - 70, (cell.bounds.size.height - 28) / 2, 60, 28);
                btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
                [btn setTitle:@"直链" forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont systemFontOfSize:13];
                [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.48 blue:1.0 alpha:1.0];
                btn.layer.cornerRadius = 14;
                btn.layer.masksToBounds = YES;
                [btn addTarget:nil action:@selector(bdt_cellLinkTapped:) forControlEvents:UIControlEventTouchUpInside];
                [cell addSubview:btn];
            }
            objc_setAssociatedObject(btn, "fileName", fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v8.3"
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
- (void)bdt_cellLinkTapped:(id)sender;
@end

@implementation NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender { onFloatButtonTap(); }
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}
- (void)bdt_cellLinkTapped:(UIButton *)sender {
    NSString *fileName = objc_getAssociatedObject(sender, "fileName");
    if (!fileName) {
        showToast(@"无法获取文件名");
        return;
    }

    autoDetectPathAndToken();

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"获取文件信息..." preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:progress animated:YES completion:nil];

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files) {
            [progress dismissViewControllerAnimated:YES completion:^{
                showToast(@"获取文件列表失败");
            }];
            return;
        }

        NSDictionary *targetFile = nil;
        for (NSDictionary *file in files) {
            NSString *name = file[@"server_filename"];
            if ([name isEqualToString:fileName]) {
                targetFile = file;
                break;
            }
        }

        if (!targetFile) {
            [progress dismissViewControllerAnimated:YES completion:^{
                showToast(@"未找到文件");
            }];
            return;
        }

        [progress dismissViewControllerAnimated:YES completion:^{
            NSString *name = targetFile[@"server_filename"];
            NSString *path = targetFile[@"path"];
            NSString *fileId = [targetFile[@"fs_id"] stringValue];
            runRenameAndGetLink(name, path, fileId);
        }];
    });
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
    UIViewController *overlayVC = objc_getAssociatedObject(sender, "overlayVC");
    if (overlayVC) {
        [overlayVC dismissViewControllerAnimated:YES completion:^{
            renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
            });
        }];
    } else {
        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
            DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
        });
    }
}
- (void)bdt_dismissDialog:(id)sender {
    UIView *overlay = nil;
    if ([sender isKindOfClass:[UITapGestureRecognizer class]]) {
        overlay = ((UITapGestureRecognizer *)sender).view;
    } else if ([sender isKindOfClass:[UIButton class]]) {
        overlay = objc_getAssociatedObject(sender, "overlayVC");
    }
    if (!overlay) {
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
    DLog(@"BaiduPan Troll v8.3 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();

        [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
            injectDirectLinkButtons();
        }];
    });
}
