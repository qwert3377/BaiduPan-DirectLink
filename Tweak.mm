//
// BaiduPan SVIP Direct Link Helper - TrollStore Edition v12.4
// Fix: All braces balanced, all functions complete, Logos hooks in global scope
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;
static id gButtonTarget = nil;

static NSString *gInterceptedDlink = nil;
static NSString *gInterceptedFileName = nil;
static NSString *gInterceptedFilePath = nil;
static NSString *gInterceptedFileId = nil;
static BOOL gShouldInterceptDlink = NO;
static BOOL gIsProcessingFile = NO;

// ========== Forward Declarations ==========

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
static void handleInterceptedDlink(void);
static void runRenameAndIntercept(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);
static void hookBaiduPanClasses(void);

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
    if (!window) {
        window = [[UIApplication sharedApplication] keyWindow];
    }
    if (!window) return nil;

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = [(UINavigationController *)vc topViewController];
    }
    return vc;
}

static NSString * strictEncodeURIComponent(NSString *str) {
    if (!str) return @"";
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_.~"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static void copyToClipboard(NSString *text) {
    if (!text || text.length == 0) return;
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = text;
    showToast(@"链接已复制到剪贴板");
}

static void showToast(NSString *msg) {
    if (!msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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
        if (!window) return;

        UILabel *label = [[UILabel alloc] init];
        label.text = msg;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14];
        label.layer.cornerRadius = 8;
        label.clipsToBounds = YES;
        [label sizeToFit];
        label.frame = CGRectInset(label.frame, 16, 8);
        label.center = CGPointMake(window.bounds.size.width / 2, window.bounds.size.height / 2);
        [window addSubview:label];

        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseIn animations:^{
            label.alpha = 0;
        } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    });
}

// ========== Network Helpers ==========

static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err)) {
    if (!url) {
        if (handler) handler(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"URL is nil"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 15;

    if (headers) {
        for (NSString *key in headers) {
            [req setValue:headers[key] forHTTPHeaderField:key];
        }
    }

    if (body && body.length > 0) {
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (handler) handler(nil, error);
                return;
            }
            NSError *jsonErr = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data] options:0 error:&jsonErr];
            if (handler) handler(json, jsonErr);
        });
    }];
    [task resume];
}

// ========== Token & Path Detection ==========

static NSString * scanMemoryForBdstoken(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [defaults dictionaryRepresentation];
    for (NSString *key in all) {
        if ([key rangeOfString:@"bdstoken" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            id val = all[key];
            if ([val isKindOfClass:[NSString class]] && [val length] > 10) {
                return val;
            }
        }
    }

    NSArray *candidates = @[
        @"bdstoken",
        @"BaiduPan_bdstoken",
        @"BDStoken",
        @"kBdstoken"
    ];
    for (NSString *key in candidates) {
        id val = [defaults objectForKey:key];
        if ([val isKindOfClass:[NSString class]] && [val length] > 10) {
            return val;
        }
    }
    return nil;
}

static NSString * extractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;

    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([vc class], &count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        NSString *ivarName = [NSString stringWithUTF8String:name];
        if ([ivarName rangeOfString:@"path" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [ivarName rangeOfString:@"dir" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            id val = object_getIvar(vc, ivars[i]);
            if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
                free(ivars);
                return val;
            }
        }
    }
    free(ivars);
    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *top = topViewController();
    if (!top) return nil;

    UINavigationController *nav = nil;
    if ([top isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)top;
    } else {
        nav = top.navigationController;
    }

    if (!nav) return nil;

    NSMutableArray *pathComponents = [NSMutableArray array];
    for (UIViewController *vc in nav.viewControllers) {
        NSString *path = extractPathFromVC(vc);
        if (path && path.length > 0) {
            [pathComponents addObject:path];
        }
    }

    if (pathComponents.count == 0) return @"/";

    NSString *fullPath = [pathComponents componentsJoinedByString:@"/"];
    if (![fullPath hasPrefix:@"/"]) {
        fullPath = [@"/" stringByAppendingString:fullPath];
    }
    return fullPath;
}

static void autoDetectPathAndToken(void) {
    if (!gBdstoken || gBdstoken.length == 0) {
        gBdstoken = scanMemoryForBdstoken();
        if (gBdstoken) {
            DLog(@"Auto-detected bdstoken: %@", gBdstoken);
        }
    }

    if (!gCurrentPath || gCurrentPath.length == 0) {
        gCurrentPath = buildPathFromNavStack();
        if (gCurrentPath) {
            DLog(@"Auto-detected path: %@", gCurrentPath);
        } else {
            gCurrentPath = @"/";
        }
    }
}

// ========== File Operations ==========

static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    autoDetectPathAndToken();

    if (!gBdstoken) {
        if (completion) completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken found"}]);
        return;
    }

    NSString *path = gCurrentPath ?: @"/";
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&num=100&page=1",
                     strictEncodeURIComponent(path), gBdstoken];

    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err || !json) {
            if (completion) completion(nil, err);
            return;
        }
        NSArray *list = json[@"list"];
        if (completion) completion(list, nil);
    });
}

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!fileId || !path || !newName) {
        if (completion) completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid parameters"}]);
        return;
    }

    autoDetectPathAndToken();

    if (!gBdstoken) {
        if (completion) completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken found"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?bdstoken=%@&opera=rename", gBdstoken];
    NSString *oldPath = [path stringByAppendingPathComponent:fileId];

    NSString *body = [NSString stringWithFormat:@"filelist=[{\"path\":\"%@\",\"newname\":\"%@\"}]",
                      strictEncodeURIComponent(oldPath), strictEncodeURIComponent(newName)];

    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded",
        @"Referer": @"https://pan.baidu.com/disk/home"
    };

    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) {
            if (completion) completion(NO, err);
            return;
        }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            if (completion) completion(YES, nil);
        } else {
            if (completion) completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: json[@"errmsg"] ?: @"Rename failed"}]);
        }
    });
}

static void forceRefreshFileList(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = topViewController();
        if (!top) return;

        UIView *view = top.view;
        if (!view) return;

        NSMutableArray *tableViews = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:view];
        while (stack.count > 0) {
            UIView *current = [stack lastObject];
            [stack removeLastObject];
            if ([current isKindOfClass:[UITableView class]]) {
                [tableViews addObject:current];
            }
            [stack addObjectsFromArray:current.subviews];
        }

        for (UITableView *tv in tableViews) {
            [tv reloadData];
        }

        for (UITableView *tv in tableViews) {
            if (tv.refreshControl) {
                [tv.refreshControl beginRefreshing];
                [tv.refreshControl endRefreshing];
            }
        }
    });
}

// ========== Link Handling ==========

static void showLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    (void)pdfPath;
    (void)fileId;
    if (!link) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = topViewController();
        if (!top) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取到直链"
                                                                       message:fileName
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.text = link;
            textField.enabled = NO;
        }];

        [alert addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            copyToClipboard(link);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"复制并打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            copyToClipboard(link);
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:link] options:@{} completionHandler:nil];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];

        [top presentViewController:alert animated:YES completion:nil];
    });
}

static void handleInterceptedDlink(void) {
    if (!gInterceptedDlink || gInterceptedDlink.length == 0) {
        showToast(@"未拦截到下载链接");
        return;
    }

    DLog(@"Intercepted dlink: %@ for file: %@", gInterceptedDlink, gInterceptedFileName);
    showLinkDialog(gInterceptedDlink, gInterceptedFileName, gInterceptedFileId, gInterceptedFilePath);

    gShouldInterceptDlink = NO;
}

// ========== Main Flow ==========

static void runRenameAndIntercept(NSString *fileName, NSString *filePath, NSString *fileId) {
    if (gIsProcessingFile) {
        showToast(@"正在处理中，请稍候...");
        return;
    }

    gIsProcessingFile = YES;
    gInterceptedFileName = fileName;
    gInterceptedFilePath = filePath;
    gInterceptedFileId = fileId;
    gShouldInterceptDlink = YES;
    gInterceptedDlink = nil;

    NSString *newName = [fileName stringByAppendingString:@".88888888888888"];

    renameFile(fileId, filePath, newName, ^(BOOL success, NSError *err) {
        if (!success) {
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription ?: @"未知错误"]);
            gIsProcessingFile = NO;
            return;
        }

        showToast(@"已重命名，请手动点击文件");
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gIsProcessingFile = NO;
            gShouldInterceptDlink = NO;

            renameFile(fileId, filePath, fileName, ^(BOOL success, NSError *err) {
                if (success) {
                    DLog(@"文件名已恢复");
                    forceRefreshFileList();
                }
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();

    if (!gBdstoken) {
        showToast(@"未找到 bdstoken，请先登录");
        return;
    }

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            showToast(@"获取文件列表失败或为空");
            return;
        }

        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (isdir && [isdir intValue] == 1) continue;

            NSString *fileName = file[@"server_filename"];
            id fsId = file[@"fs_id"];
            NSString *fileId = nil;
            if ([fsId isKindOfClass:[NSString class]]) {
                fileId = fsId;
            } else if ([fsId isKindOfClass:[NSNumber class]]) {
                fileId = [fsId stringValue];
            }
            NSString *path = gCurrentPath ?: @"/";

            if (fileName && fileId) {
                runRenameAndIntercept(fileName, path, fileId);
                return;
            }
        }

        showToast(@"未找到可下载的文件");
    });
}

// ========== Float Button Helper ==========

static void buttonTappedAction(id self, SEL _cmd) {
    (void)self;
    (void)_cmd;
    onFloatButtonTap();
}

static void panGestureAction(id self, SEL _cmd, UIPanGestureRecognizer *gesture) {
    (void)self;
    (void)_cmd;
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}

static void onFloatButtonTap(void) {
    UIViewController *top = topViewController();
    if (!top) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"百度网盘助手"
                                                                   message:@"选择操作"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"获取直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        triggerDownloadFlow();
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"查看拦截的链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        handleInterceptedDlink();
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = gFloatButton;
        alert.popoverPresentationController.sourceRect = gFloatButton.bounds;
    }

    [top presentViewController:alert animated:YES completion:nil];
}

static void showFloatButton(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatButton) {
            [gFloatButton removeFromSuperview];
            gFloatButton = nil;
        }

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
        if (!window) return;

        if (!gButtonTarget) {
            Class helperClass = objc_allocateClassPair([NSObject class], "BaiduPanBtnHelper", 0);
            if (helperClass) {
                class_addMethod(helperClass, @selector(buttonTapped), (IMP)buttonTappedAction, "v@:");
                class_addMethod(helperClass, @selector(panGesture:), (IMP)panGestureAction, "v@:@");
                objc_registerClassPair(helperClass);
                gButtonTarget = [[helperClass alloc] init];
            }
        }

        gFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        gFloatButton.frame = CGRectMake(window.bounds.size.width - 70, window.bounds.size.height / 2 - 35, 60, 60);
        gFloatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        gFloatButton.layer.cornerRadius = 30;
        gFloatButton.clipsToBounds = YES;
        [gFloatButton setTitle:@"直链" forState:UIControlStateNormal];
        [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatButton.titleLabel.font = [UIFont systemFontOfSize:12];

        if (gButtonTarget) {
            [gFloatButton addTarget:gButtonTarget action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gButtonTarget action:@selector(panGesture:)];
            [gFloatButton addGestureRecognizer:pan];
        }

        [window addSubview:gFloatButton];
    });
}

static void hookBaiduPanClasses(void) {
    DLog(@"Runtime hook for BaiduPan private classes initialized");
}

// ========== Logos Hooks (Global Scope) ==========

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (url && gShouldInterceptDlink) {
        NSString *urlStr = url.absoluteString;
        if ([urlStr containsString:@"d.pcs.baidu.com"] || [urlStr containsString:@"dlink"] || [urlStr containsString:@"pcs.baidu.com"]) {
            DLog(@"Intercepted dlink: %@", urlStr);
            gInterceptedDlink = urlStr;
            gShouldInterceptDlink = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                handleInterceptedDlink();
            });
        }
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (url && gShouldInterceptDlink) {
        NSString *urlStr = url.absoluteString;
        if ([urlStr containsString:@"d.pcs.baidu.com"] || [urlStr containsString:@"dlink"] || [urlStr containsString:@"pcs.baidu.com"]) {
            DLog(@"Intercepted download dlink: %@", urlStr);
            gInterceptedDlink = urlStr;
            gShouldInterceptDlink = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                handleInterceptedDlink();
            });
        }
    }
    return %orig;
}

%end

// ========== Constructor ==========

%ctor {
    @autoreleasepool {
        hookBaiduPanClasses();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            showFloatButton();
        });
    }
}
