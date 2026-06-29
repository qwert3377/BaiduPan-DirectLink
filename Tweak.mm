//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v12.0
//  Strategy: Hook internal PriviewDownLoad -> previewDownloadFileMeta to intercept dlink
//  This bypasses the 50MB limit by capturing the server-signed dlink from app internals.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// Intercepted dlink storage
static NSString *gInterceptedDlink = nil;
static NSString *gInterceptedFileName = nil;
static NSString *gInterceptedFilePath = nil;
static NSString *gInterceptedFileId = nil;
static BOOL gShouldInterceptDlink = NO;
static BOOL gIsProcessingFile = NO;

// Forward declarations (functions must be defined before use)
static UIViewController * topViewController(void);
static NSString * strictEncodeURIComponent(NSString *str);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static NSString * scanMemoryForBdstoken(void);
static NSString * extractPathFromVC(UIViewController *vc);
static NSString * buildPathFromNavStack(void);
static void autoDetectPathAndToken(void);
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void copyToClipboard(NSString *text);
static void showToast(NSString *msg);
static void forceRefreshFileList(void);
static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath);
static void runRenameAndIntercept(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

// ========== UI Helpers ==========

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

// ========== v12.0 Link Dialog ==========

@interface LinkCopyButton : UIButton
@property (nonatomic, copy) NSString *linkText;
@end

@implementation LinkCopyButton
- (void)copyBtnTapped {
    if (self.linkText) {
        copyToClipboard(self.linkText);
        showToast(@"直链已复制到剪贴板！");
    }
}
@end

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"直链已复制" message:nil preferredStyle:UIAlertControllerStyleAlert];

    UIView *customView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 270, 120)];

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 270, 20)];
    nameLabel.text = [NSString stringWithFormat:@"%@ 的直链已成功复制到剪贴板。", fileName];
    nameLabel.font = [UIFont systemFontOfSize:13];
    nameLabel.textColor = [UIColor darkTextColor];
    nameLabel.numberOfLines = 0;
    [nameLabel sizeToFit];
    CGRect nameFrame = nameLabel.frame;
    nameFrame.size.width = 270;
    nameLabel.frame = nameFrame;
    [customView addSubview:nameLabel];

    CGFloat nameH = nameLabel.frame.size.height + 8;
    UITextField *linkField = [[UITextField alloc] initWithFrame:CGRectMake(0, nameH, 200, 36)];
    linkField.text = link;
    linkField.font = [UIFont fontWithName:@"Menlo" size:11];
    linkField.textColor = [UIColor colorWithRed:0.18 green:0.42 blue:1.0 alpha:1.0];
    linkField.backgroundColor = [UIColor colorWithRed:0.97 green:0.97 blue:1.0 alpha:1.0];
    linkField.layer.borderColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.85 alpha:1.0].CGColor;
    linkField.layer.borderWidth = 1.0;
    linkField.layer.cornerRadius = 6;
    linkField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 0)];
    linkField.leftViewMode = UITextFieldViewModeAlways;
    linkField.clearButtonMode = UITextFieldViewModeNever;
    [customView addSubview:linkField];

    LinkCopyButton *copyBtn = [LinkCopyButton buttonWithType:UIButtonTypeSystem];
    copyBtn.frame = CGRectMake(210, nameH, 60, 36);
    [copyBtn setTitle:@"再次复制" forState:UIControlStateNormal];
    copyBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    copyBtn.backgroundColor = [UIColor colorWithRed:0.18 green:0.42 blue:1.0 alpha:1.0];
    copyBtn.layer.cornerRadius = 6;
    copyBtn.layer.masksToBounds = YES;
    copyBtn.linkText = link;
    [copyBtn addTarget:copyBtn action:@selector(copyBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [customView addSubview:copyBtn];

    CGFloat hintY = nameH + 44;
    UILabel *hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, hintY, 270, 20)];
    hintLabel.text = @"提示：可使用 IDM、Aria2、Motrix 等工具粘贴下载";
    hintLabel.font = [UIFont systemFontOfSize:12];
    hintLabel.textColor = [UIColor grayColor];
    [customView addSubview:hintLabel];

    customView.frame = CGRectMake(0, 0, 270, hintY + 24);
    [alert setValue:customView forKey:@"contentViewController"];

    [alert addAction:[UIAlertAction actionWithTitle:@"已复制，恢复原名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        renameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) { DLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription); });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保持pdf后缀" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

// ========== v12.0 Core: Intercept internal download dlink ==========

static void handleInterceptedDlink(void) {
    if (!gInterceptedDlink) {
        DLog(@"No dlink intercepted!");
        showToast(@"未能拦截到直链，请重试");
        // Auto restore original name if interception failed
        if (gInterceptedFileId && gInterceptedFileName && gInterceptedFilePath) {
            NSString *pdfPath = [[gInterceptedFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[gInterceptedFileName stringByAppendingString:@".pdf"]];
            renameFile(gInterceptedFileId, pdfPath, gInterceptedFileName, ^(BOOL ok, NSError *e) {
                DLog(@"Auto restore after intercept fail: %@", ok ? @"OK" : e.localizedDescription);
            });
        }
        gIsProcessingFile = NO;
        return;
    }

    DLog(@"Intercepted dlink: %@...", [gInterceptedDlink substringToIndex:MIN(60, gInterceptedDlink.length)]);
    copyToClipboard(gInterceptedDlink);
    showToast(@"直链已拦截并复制到剪贴板！");

    NSString *pdfPath = [[gInterceptedFilePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:[gInterceptedFileName stringByAppendingString:@".pdf"]];
    showLinkDialog(gInterceptedDlink, gInterceptedFileName, gInterceptedFileId, pdfPath);

    gShouldInterceptDlink = NO;
    gIsProcessingFile = NO;
}

static void runRenameAndIntercept(NSString *fileName, NSString *filePath, NSString *fileId) {
    if (gIsProcessingFile) {
        showToast(@"正在处理中，请稍候...");
        return;
    }
    gIsProcessingFile = YES;

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    // Store for later use
    gInterceptedFileName = fileName;
    gInterceptedFilePath = filePath;
    gInterceptedFileId = fileId;
    gInterceptedDlink = nil;
    gShouldInterceptDlink = YES;

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"1. 重命名文件并启用拦截" preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presentVC = topViewController();
    if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = topViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            }];
            gIsProcessingFile = NO;
            gShouldInterceptDlink = NO;
            return;
        }

        DLog(@"Renamed to %@, refreshing and triggering preview download...", pdfName);
        progressAlert.message = @"2. 刷新文件列表...";
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            progressAlert.message = @"3. 等待拦截直链...";

            // The app should now call previewDownloadFileMeta internally
            // We hook that method to intercept the dlink
            // Wait for interception with timeout
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    handleInterceptedDlink();
                }];
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    DLog(@"Starting download flow (v12.0 intercept mode)...");
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
                runRenameAndIntercept(name, path, fileId);
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

// ========== v12.0 Hook: PriviewDownLoad ==========

// Hook NSURLSession to intercept dlink URLs from internal download requests
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *urlString = request.URL.absoluteString;

    // Intercept d.pcs.baidu.com / d1.baidupcs.com etc download URLs
    if (gShouldInterceptDlink && urlString) {
        NSArray *dlinkHosts = @[@"d.pcs.baidu.com", @"d1.baidupcs.com", @"d2.baidupcs.com", @"d3.baidupcs.com", @"d4.baidupcs.com",
                                 @"pcs.baidu.com", @"bj.baidupcs.com", @"nj.baidupcs.com", @"gz.baidupcs.com"];
        BOOL isDlink = NO;
        for (NSString *host in dlinkHosts) {
            if ([urlString containsString:host]) {
                isDlink = YES;
                break;
            }
        }

        if (isDlink) {
            DLog(@"INTERCEPTED dlink URL: %@...", [urlString substringToIndex:MIN(80, urlString.length)]);
            gInterceptedDlink = urlString;
            gShouldInterceptDlink = NO; // Stop intercepting after first capture

            // Cancel this internal request so app doesn't actually download
            // Return a dummy task that does nothing
            NSURLSessionDataTask *dummyTask = %orig(request, ^(NSData *data, NSURLResponse *response, NSError *error) {
                // Swallow the response - don't actually download
                if (completionHandler) {
                    completionHandler(nil, nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-999 userInfo:@{NSLocalizedDescriptionKey: @"Intercepted by Troll"}]);
                }
            });
            [dummyTask cancel];
            return dummyTask;
        }
    }

    return %orig(request, completionHandler);
}

%end

// Also hook the specific PriviewDownLoad class if it exists
%hook PriviewDownLoad

- (void)previewDownloadFileMeta {
    DLog(@"Hook: previewDownloadFileMeta called, intercept enabled");
    gShouldInterceptDlink = YES;
    %orig;
}

- (void)downloadFileWithCDNModel:(id)cdnModel {
    DLog(@"Hook: downloadFileWithCDNModel called");
    gShouldInterceptDlink = YES;
    %orig;
}

- (void)PMallDownloadFile {
    DLog(@"Hook: PMallDownloadFile called");
    gShouldInterceptDlink = YES;
    %orig;
}

- (void)downloadShareDirFile {
    DLog(@"Hook: downloadShareDirFile called");
    gShouldInterceptDlink = YES;
    %orig;
}

%end

// Hook DownOperation to catch dlink generation
%hook DownOperation

- (void)downloadFromPCS {
    DLog(@"Hook: downloadFromPCS called");
    gShouldInterceptDlink = YES;
    %orig;
}

- (id)getDlinkDownloadPath {
    id result = %orig;
    if (result && [result isKindOfClass:[NSString class]] && gShouldInterceptDlink) {
        NSString *dlink = (NSString *)result;
        DLog(@"Hook: getDlinkDownloadPath returned: %@...", [dlink substringToIndex:MIN(80, dlink.length)]);
        gInterceptedDlink = dlink;
    }
    return result;
}

%end

// Hook BDPanFileDownloadEngine to catch download operations
%hook BDPanFileDownloadEngine

- (void)startDownloadTransFile {
    DLog(@"Hook: startDownloadTransFile called");
    gShouldInterceptDlink = YES;
    %orig;
}

- (void)startDownloadFolder {
    DLog(@"Hook: startDownloadFolder called");
    gShouldInterceptDlink = YES;
    %orig;
}

%end

// ========== Float Button ==========

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = @"missing";
    if (gBdstoken) {
        NSUInteger len = gBdstoken.length;
        NSUInteger previewLen = len > 16 ? 16 : len;
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", [gBdstoken substringToIndex:previewLen], (unsigned long)len];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v12.0"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n拦截模式: 启用\n状态: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing", gIsProcessingFile ? @"处理中" : @"就绪"]
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
    DLog(@"Float button shown (v12.0)");
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
    DLog(@"BaiduPan Troll v12.0 loaded - Dlink Intercept Mode");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
