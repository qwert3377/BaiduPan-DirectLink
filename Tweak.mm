//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v9.8
//  Fix: 移除未使用的 invokeMethodWithReturn，精简代码
//  核心：Hook 文件列表 Cell 点击事件，模拟用户点击触发 App 原生下载
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// ========== 前置声明 ==========
static UIViewController * topViewController(void);
static NSString * strictEncodeURIComponent(NSString *str);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static NSString * scanMemoryForBdstoken(void);
static NSString * extractPathFromVC(UIViewController *vc);
static NSString * buildPathFromNavStack(void);
static void autoDetectPathAndToken(void);
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void showToast(NSString *msg);
static void showAlert(NSString *title, NSString *msg);
static void invokeMethod(id target, SEL selector, NSArray *args);
static void triggerDownloadBySimulatingUserAction(NSDictionary *fileMeta);
static void fallbackDirectDownload(NSDictionary *fileMeta);
static void runDownloadFlow(NSDictionary *fileMeta);
static void triggerDownloadSheet(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

// ========== 实现 ==========

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
                        DLog(@"Found 32-bit token in key '%@': %@...", key, [str substringToIndex:16]);
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
        DLog(@"Only found 16-bit token in key '%@': %@...", bestKey, [bestToken substringToIndex:16]);
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
    DLog(@"Path: %@ | Token: %@ | BDUSS: %@", gCurrentPath, gBdstoken ? @"OK" : @"missing", gBDUSS ? @"OK" : @"missing");
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

static void showAlert(NSString *title, NSString *msg) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

static void invokeMethod(id target, SEL selector, NSArray *args) {
    NSMethodSignature *sig = [target methodSignatureForSelector:selector];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setSelector:selector];
    [inv setTarget:target];
    for (NSUInteger i = 0; i < args.count; i++) {
        id arg = args[i];
        [inv setArgument:&arg atIndex:i + 2];
    }
    [inv invoke];
}

// ========== v9.8 核心：模拟用户点击下载行为 ==========

static void triggerDownloadBySimulatingUserAction(NSDictionary *fileMeta) {
    UIViewController *vc = topViewController();
    if (!vc) {
        showToast(@"无法获取当前页面");
        return;
    }

    DLog(@"Trying to simulate user download action for: %@", fileMeta[@"server_filename"]);

    // 方法1: 找到 tableView 并模拟点击对应行
    UITableView *tableView = nil;
    for (UIView *subview in vc.view.subviews) {
        if ([subview isKindOfClass:[UITableView class]]) {
            tableView = (UITableView *)subview;
            break;
        }
    }

    if (!tableView) {
        for (UIView *v in vc.view.subviews) {
            for (UIView *vv in v.subviews) {
                if ([vv isKindOfClass:[UITableView class]]) {
                    tableView = (UITableView *)vv;
                    break;
                }
            }
            if (tableView) break;
        }
    }

    if (tableView) {
        DLog(@"Found tableView");
        id dataSource = tableView.dataSource;
        if (dataSource) {
            NSArray *fileList = nil;
            @try {
                fileList = [dataSource valueForKey:@"fileList"];
                if (!fileList) fileList = [dataSource valueForKey:@"dataList"];
                if (!fileList) fileList = [dataSource valueForKey:@"list"];
                if (!fileList) fileList = [dataSource valueForKey:@"files"];
                if (!fileList) fileList = [dataSource valueForKey:@"_fileList"];
                if (!fileList) fileList = [dataSource valueForKey:@"_dataList"];
            } @catch (NSException *e) {}

            if (fileList && [fileList isKindOfClass:[NSArray class]]) {
                DLog(@"Found file list with %lu items", (unsigned long)[(NSArray *)fileList count]);
                NSString *targetPath = fileMeta[@"path"];
                NSUInteger targetIndex = NSNotFound;
                for (NSUInteger i = 0; i < [(NSArray *)fileList count]; i++) {
                    id item = [(NSArray *)fileList objectAtIndex:i];
                    NSString *itemPath = nil;
                    @try {
                        itemPath = [item valueForKey:@"path"];
                    } @catch (NSException *e) {}
                    if ([itemPath isEqualToString:targetPath]) {
                        targetIndex = i;
                        break;
                    }
                }

                if (targetIndex != NSNotFound) {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:targetIndex inSection:0];
                    DLog(@"Found target at indexPath: %@", indexPath);

                    if ([vc respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        DLog(@"Calling tableView:didSelectRowAtIndexPath:");
                        invokeMethod(vc, @selector(tableView:didSelectRowAtIndexPath:), @[tableView, indexPath]);
                        showToast(@"已模拟点击文件");
                        return;
                    }

                    id delegate = tableView.delegate;
                    if (delegate && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        DLog(@"Calling delegate tableView:didSelectRowAtIndexPath:");
                        invokeMethod(delegate, @selector(tableView:didSelectRowAtIndexPath:), @[tableView, indexPath]);
                        showToast(@"已模拟点击文件");
                        return;
                    }
                }
            }
        }
    }

    // 方法2: 尝试直接调用 VC 的下载方法
    NSArray *vcSelectors = @[
        @"downloadFile:", @"downloadFileWithMeta:", @"startDownload:", @"addDownloadTask:",
        @"handleDownloadAction:", @"onDownloadButtonClick:", @"didClickDownload:",
        @"downloadSelectedFile:", @"beginDownload:", @"queueDownload:",
        @"addToDownloadList:", @"createDownloadTask:", @"submitDownloadTask:",
        @"enqueueDownload:", @"startDownloadFile:", @"performDownload:",
        @"triggerDownload:", @"executeDownload:",
    ];

    for (NSString *selName in vcSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC method: %@", selName);
            invokeMethod(vc, sel, @[fileMeta]);
            showToast(@"已触发下载");
            return;
        }
    }

    // 方法3: 尝试 navigationController 的 viewControllers
    if (vc.navigationController) {
        for (UIViewController *controller in vc.navigationController.viewControllers) {
            for (NSString *selName in vcSelectors) {
                SEL sel = NSSelectorFromString(selName);
                if ([controller respondsToSelector:sel]) {
                    DLog(@"Calling stack VC method: %@ on %@", selName, NSStringFromClass([controller class]));
                    invokeMethod(controller, sel, @[fileMeta]);
                    showToast(@"已触发下载");
                    return;
                }
            }
        }
    }

    // 方法4: 尝试 AppDelegate
    id appDelegate = [[UIApplication sharedApplication] delegate];
    if (appDelegate) {
        for (NSString *selName in vcSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([appDelegate respondsToSelector:sel]) {
                DLog(@"Calling AppDelegate method: %@", selName);
                invokeMethod(appDelegate, sel, @[fileMeta]);
                showToast(@"已触发下载");
                return;
            }
        }
    }

    DLog(@"All simulation methods failed, using fallback");
    fallbackDirectDownload(fileMeta);
}

// ========== 兜底：直链下载 ==========

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

static void startNSURLSessionDownload(NSString *urlString, NSString *fileName) {
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 30;
    NSMutableDictionary *headers = [@{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        @"Accept": @"*/*",
        @"Referer": @"https://pan.baidu.com/"
    } mutableCopy];
    if (gBDUSS) headers[@"Cookie"] = [NSString stringWithFormat:@"BDUSS=%@", gBDUSS];
    req.allHTTPHeaderFields = headers;

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                showToast(@"下载失败");
                return;
            }
            NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
            NSString *destPath = [docsPath stringByAppendingPathComponent:fileName];
            NSFileManager *fm = [NSFileManager defaultManager];
            if ([fm fileExistsAtPath:destPath]) [fm removeItemAtPath:destPath error:nil];
            [fm moveItemAtPath:location.path toPath:destPath error:nil];
            showToast([NSString stringWithFormat:@"已下载到: %@", fileName]);
        });
    }];
    [task resume];
    showToast(@"开始下载...");
}

static void fetchDlinkAndDownload(NSString *filePath, NSString *fileName) {
    if (!gBdstoken) { showToast(@"缺少 token"); return; }

    NSString *encodedPath = strictEncodeURIComponent(filePath);
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%lld", gBdstoken, encodedPath, ts];

    bdAsyncRequest(url, @"GET", @{@"X-Requested-With": @"XMLHttpRequest"}, nil, ^(id json, NSError *err) {
        if (err) { showToast(@"获取下载链接失败"); return; }
        NSString *dlink = digOutDlink(json);
        if (!dlink) {
            NSString *url2 = [NSString stringWithFormat:@"https://pan.baidu.com/api/locatedownload?clienttype=0&app_id=250528&web=1&channel=chunlei&path=%@&origin=pdf&use=1&bdstoken=%@&t=%lld", encodedPath, gBdstoken, ts];
            bdAsyncRequest(url2, @"GET", @{@"X-Requested-With": @"XMLHttpRequest"}, nil, ^(id json2, NSError *err2) {
                NSString *dlink2 = digOutDlink(json2);
                if (dlink2) {
                    startNSURLSessionDownload(dlink2, fileName);
                } else {
                    showToast(@"无法获取下载链接");
                }
            });
            return;
        }
        startNSURLSessionDownload(dlink, fileName);
    });
}

static void fallbackDirectDownload(NSDictionary *fileMeta) {
    NSString *path = fileMeta[@"path"];
    NSString *name = fileMeta[@"server_filename"];
    if (!path || !name) {
        showToast(@"文件信息不完整");
        return;
    }
    fetchDlinkAndDownload(path, name);
}

static void runDownloadFlow(NSDictionary *fileMeta) {
    NSString *name = fileMeta[@"server_filename"] ?: @"unknown";
    DLog(@"Starting download for: %@", name);
    triggerDownloadBySimulatingUserAction(fileMeta);
}

static void triggerDownloadSheet(void) {
    DLog(@"Starting download flow...");
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            DLog(@"Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            showAlert(@"获取文件列表失败", err ? err.localizedDescription : @"文件夹为空");
            return;
        }

        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }

        if (fileItems.count == 0) {
            showAlert(@"没有文件", @"当前文件夹没有可下载的文件");
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件下载" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *title = name;
            if (size) {
                double mb = [size doubleValue] / (1024.0 * 1024.0);
                title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb];
            }
            [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                runDownloadFlow(file);
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v9.8"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 下载文件" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        triggerDownloadSheet();
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
    DLog(@"BaiduPan Troll v9.8 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
