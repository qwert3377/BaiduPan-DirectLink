//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v12.2
//  Fix: Completed truncated functions, fixed Logos hook placement
//  Strategy: Hook NSURLSession to intercept dlink, runtime hook for private classes
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
    // Try to find bdstoken from NSUserDefaults
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
    
    // Try common keys
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
    
    // Try to extract path from navigation item title or internal properties
    NSString *title = vc.navigationItem.title;
    if (title && title.length > 0) {
        // This might be a folder name, build full path from stack
    }
    
    // Use reflection to find path properties
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
    
    // If it's a UINavigationController, get the top vc
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
    NSString *newPath = [path stringByAppendingPathComponent:newName];
    
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
        
        // Try to find table view and reload
        UIView *view = top.view;
        if (!view) return;
        
        // Find UITableView recursively
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
        
        // Try to trigger pull-to-refresh
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
    
    // Reset interception flag
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
    gInterceptedDlink = nil;
    gShouldInterceptDlink = YES;
    
    NSString *renamedName = [fileName stringByAppendingString:@".88888888888888"];
    
    showToast(@"正在重命名文件...");
    
    renameFile(fileId, gCurrentPath ?: @"/", renamedName, ^(BOOL success, NSError *err) {
        if (!success) {
            gIsProcessingFile = NO;
            gShouldInterceptDlink = NO;
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }
        
        showToast(@"重命名成功，刷新列表...");
        forceRefreshFileList();
        
        // Wait for refresh and let user tap the file
        // The NSURLSession hook will intercept the dlink when user opens the file
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gIsProcessingFile = NO;
            showToast(@"请点击重命名后的文件以获取直链");
        });
    });
}

static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();
    
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            showToast(@"无法获取文件列表");
            return;
        }
        
        // Show file picker
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *top = topViewController();
            if (!top) return;
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                           message:nil
                                                                    preferredStyle:UIAlertControllerStyleActionSheet];
            
            for (NSDictionary *file in files) {
                NSString *name = file[@"server_filename"] ?: file[@"filename"];
                NSString *fileId = [NSString stringWithFormat:@"%@", file[@"fs_id"] ?: @""];
                if (!name || name.length == 0) continue;
                
                [alert addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    runRenameAndIntercept(name, gCurrentPath ?: @"/", fileId);
                }]];
            }
            
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            
            if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                alert.popoverPresentationController.sourceView = top.view;
                alert.popoverPresentationController.sourceRect = CGRectMake(top.view.bounds.size.width/2, top.view.bounds.size.height/2, 1, 1);
            }
            
            [top presentViewController:alert animated:YES completion:nil];
        });
    });
}

// ========== Float Button ==========

static void onFloatButtonTap(void) {
    triggerDownloadFlow();
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
        
        gFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
        gFloatButton.frame = CGRectMake(window.bounds.size.width - 70, window.bounds.size.height / 2 - 30, 60, 60);
        gFloatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        gFloatButton.layer.cornerRadius = 30;
        gFloatButton.layer.shadowColor = [UIColor blackColor].CGColor;
        gFloatButton.layer.shadowOffset = CGSizeMake(0, 2);
        gFloatButton.layer.shadowOpacity = 0.3;
        gFloatButton.layer.shadowRadius = 4;
        [gFloatButton setTitle:@"BD" forState:UIControlStateNormal];
        [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [gFloatButton addTarget:gFloatButton action:@selector(onFloatButtonTap) forControlEvents:UIControlEventTouchUpInside];
        
        // Make button draggable
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gFloatButton action:@selector(handlePan:)];
        [gFloatButton addGestureRecognizer:pan];
        
        [window addSubview:gFloatButton];
        
        DLog(@"Float button shown");
    });
}

// ========== Runtime Hook for Private Classes ==========

static void hookBaiduPanClasses(void) {
    // Hook PriviewDownLoad to intercept dlink
    Class previewClass = NSClassFromString(@"PriviewDownLoad");
    if (previewClass) {
        SEL originalSEL = NSSelectorFromString(@"previewDownloadFileMeta:");
        Method originalMethod = class_getInstanceMethod(previewClass, originalSEL);
        if (originalMethod) {
            IMP originalIMP = method_getImplementation(originalMethod);
            
            IMP newIMP = imp_implementationWithBlock(^(id self, id arg1) {
                // Call original
                ((void (*)(id, SEL, id))originalIMP)(self, originalSEL, arg1);
                
                // Try to extract dlink from arg1 or self
                if (gShouldInterceptDlink && arg1) {
                    // arg1 might be a dictionary with dlink
                    if ([arg1 isKindOfClass:[NSDictionary class]]) {
                        NSString *dlink = arg1[@"dlink"];
                        if (dlink && dlink.length > 0) {
                            gInterceptedDlink = dlink;
                            handleInterceptedDlink();
                        }
                    }
                }
            });
            
            method_setImplementation(originalMethod, newIMP);
            DLog(@"Hooked PriviewDownLoad previewDownloadFileMeta:");
        }
    }
    
    // Hook DownOperation if exists
    Class downOpClass = NSClassFromString(@"DownOperation");
    if (downOpClass) {
        SEL originalSEL = NSSelectorFromString(@"startDownload:");
        Method originalMethod = class_getInstanceMethod(downOpClass, originalSEL);
        if (originalMethod) {
            IMP originalIMP = method_getImplementation(originalMethod);
            IMP newIMP = imp_implementationWithBlock(^(id self, id arg1) {
                if (gShouldInterceptDlink && arg1) {
                    if ([arg1 isKindOfClass:[NSString class]]) {
                        NSString *url = (NSString *)arg1;
                        if ([url rangeOfString:@"d.pcs.baidu.com"].location != NSNotFound ||
                            [url rangeOfString:@"pcs.baidu.com"].location != NSNotFound) {
                            gInterceptedDlink = url;
                            handleInterceptedDlink();
                        }
                    }
                }
                ((void (*)(id, SEL, id))originalIMP)(self, originalSEL, arg1);
            });
            method_setImplementation(originalMethod, newIMP);
            DLog(@"Hooked DownOperation startDownload:");
        }
    }
}

// ========== Logos Hooks ==========

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSURL *url = request.URL;
    if (url && gShouldInterceptDlink) {
        NSString *urlString = url.absoluteString;
        if ([urlString rangeOfString:@"d.pcs.baidu.com"].location != NSNotFound ||
            [urlString rangeOfString:@"pcs.baidu.com"].location != NSNotFound ||
            [urlString rangeOfString:@"dlink"].location != NSNotFound) {
            gInterceptedDlink = urlString;
            DLog(@"Intercepted dlink from NSURLSession: %@", urlString);
            dispatch_async(dispatch_get_main_queue(), ^{
                handleInterceptedDlink();
            });
        }
    }
    
    return %orig;
}

%end

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        hookBaiduPanClasses();
    });
    return result;
}

%end

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // Auto-detect path when navigating
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoDetectPathAndToken();
    });
}

%end
