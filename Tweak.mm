//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v6.3
//  Feature: Aggressive auto-detect via CFNetwork hook + runtime class scan
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <WebKit/WebKit.h>
#import <CFNetwork/CFNetwork.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

static const NSInteger kLargeFileThreshold = 30 * 1024 * 1024;
static const NSInteger kWaitTimeAfterRename = 4000;
static const NSInteger kLargeFileExtraWait = 10000;
static const NSInteger kDlinkRetryCount = 3;

static NSString *gManualToken = nil;
static NSString *gCurrentPath = nil;
static BOOL gPathAutoDetected = NO;
static BOOL gTokenAutoDetected = NO;

// ========== 前向声明 ==========
static UIViewController * topViewController(void);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static NSString * getBdstoken(void);
static NSString * getCurrentPath(void);
static void fetchFileList(NSString *path, void (^completion)(NSArray *files, NSError *err));
static NSString * digOutDlink(id obj);
static void fetchDlinkViaFilemetas(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err));
static void fetchDlinkViaLocateDownload(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err));
static void fetchDlinkPortal(NSString *filePath, void (^completion)(NSString *dlink, NSError *err));
static void refreshFileMeta(NSString *filePath, void (^completion)(void));
static void refreshFileListCache(NSString *path, void (^completion)(void));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void runPipeline(NSString *fileName, NSString *fileId, NSString *currentPath, NSInteger fileSize);
static NSString * strictEncodeURIComponent(NSString *str);
static NSString * extractPathFromViewController(UIViewController *vc);
static NSString * getPathFromNavStack(void);
static NSString * extractPathFromURL(NSString *urlString);
static NSString * autoDetectBdstoken(void);
static void autoDetectPathAndToken(void);
static NSString * extractTokenFromWebView(UIView *view);
static void scanAllClassesForToken(void);
static void scanAllClassesForPath(void);

// ========== 工具函数 ==========

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
        vc = [(UITabBarController *)vc selectedViewController];
    }
    return vc;
}

static NSString * strictEncodeURIComponent(NSString *str) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 20;
    [req setValue:@"https://pan.baidu.com/disk/main" forHTTPHeaderField:@"Referer"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [req setValue:@"application/json, text/javascript, */*; q=0.01" forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [cookieStorage cookiesForURL:[NSURL URLWithString:@"https://pan.baidu.com"]];
    if (cookies.count > 0) {
        NSMutableArray *cookieStrings = [NSMutableArray array];
        for (NSHTTPCookie *cookie in cookies) {
            [cookieStrings addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
        }
        [req setValue:[cookieStrings componentsJoinedByString:@"; "] forHTTPHeaderField:@"Cookie"];
    }

    if (headers) {
        [headers enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            [req setValue:obj forHTTPHeaderField:key];
        }];
    }
    if (body) {
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { handler(nil, error); return; }
            NSError *e = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&e];
            if (e) { handler(nil, e); return; }
            handler(json, nil);
        });
    }];
    [task resume];
}

// ========== 从 WebView 提取 Token ==========

static NSString * extractTokenFromWebView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[WKWebView class]]) {
        WKWebView *webView = (WKWebView *)view;
        __block NSString *result = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [webView evaluateJavaScript:@"localStorage.getItem('bdstoken') || document.cookie.match(/bdstoken=([^;]+)/)?.[1]" completionHandler:^(id _Nullable value, NSError * _Nullable error) {
            if ([value isKindOfClass:[NSString class]]) result = value;
            dispatch_semaphore_signal(semaphore);
        }];
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
        if (result && result.length > 0) {
            DLog(@"Auto-detected bdstoken from WKWebView");
            return result;
        }
    }
    for (UIView *subview in view.subviews) {
        NSString *token = extractTokenFromWebView(subview);
        if (token) return token;
    }
    return nil;
}

// ========== 运行时扫描所有类查找 token ==========

static void scanAllClassesForToken(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        
        // 跳过系统类
        if ([className hasPrefix:@"NS"] || [className hasPrefix:@"UI"] || [className hasPrefix:@"_"]) continue;
        
        // 查找包含 token 相关属性的类
        unsigned int propCount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &propCount);
        BOOL hasTokenProp = NO;
        for (unsigned int j = 0; j < propCount; j++) {
            NSString *propName = [NSString stringWithUTF8String:property_getName(props[j])];
            if ([propName containsString:@"token"] || [propName containsString:@"Token"] || 
                [propName containsString:@"bdstoken"] || [propName containsString:@"Bdstoken"]) {
                hasTokenProp = YES;
                break;
            }
        }
        free(props);
        
        if (!hasTokenProp) continue;
        
        // 尝试获取单例
        @try {
            id shared = nil;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                shared = [cls performSelector:@selector(sharedInstance)];
            } else if ([cls respondsToSelector:@selector(shared)]) {
                shared = [cls performSelector:@selector(shared)];
            } else if ([cls respondsToSelector:@selector(defaultManager)]) {
                shared = [cls performSelector:@selector(defaultManager)];
            }
            
            if (!shared) continue;
            
            // 遍历所有属性查找 token
            props = class_copyPropertyList(cls, &propCount);
            for (unsigned int j = 0; j < propCount; j++) {
                NSString *propName = [NSString stringWithUTF8String:property_getName(props[j])];
                if ([propName containsString:@"token"] || [propName containsString:@"Token"] ||
                    [propName containsString:@"bdstoken"] || [propName containsString:@"Bdstoken"]) {
                    id val = [shared valueForKey:propName];
                    if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                        DLog(@"Found token in %@.%@ = %@", className, propName, val);
                        free(props);
                        free(classes);
                        return;
                    }
                }
            }
            free(props);
        } @catch (NSException *e) { }
    }
    free(classes);
}

// ========== 运行时扫描所有类查找路径 ==========

static void scanAllClassesForPath(void) {
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    numClasses = objc_getClassList(classes, numClasses);
    
    for (int i = 0; i < numClasses; i++) {
        Class cls = classes[i];
        NSString *className = NSStringFromClass(cls);
        
        if ([className hasPrefix:@"NS"] || [className hasPrefix:@"UI"] || [className hasPrefix:@"_"]) continue;
        
        unsigned int propCount = 0;
        objc_property_t *props = class_copyPropertyList(cls, &propCount);
        BOOL hasPathProp = NO;
        for (unsigned int j = 0; j < propCount; j++) {
            NSString *propName = [NSString stringWithUTF8String:property_getName(props[j])];
            if ([propName containsString:@"path"] || [propName containsString:@"Path"] ||
                [propName containsString:@"dir"] || [propName containsString:@"directory"] ||
                [propName containsString:@"currentDir"]) {
                hasPathProp = YES;
                break;
            }
        }
        free(props);
        
        if (!hasPathProp) continue;
        
        @try {
            id shared = nil;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                shared = [cls performSelector:@selector(sharedInstance)];
            } else if ([cls respondsToSelector:@selector(shared)]) {
                shared = [cls performSelector:@selector(shared)];
            } else if ([cls respondsToSelector:@selector(defaultManager)]) {
                shared = [cls performSelector:@selector(defaultManager)];
            }
            
            if (!shared) continue;
            
            props = class_copyPropertyList(cls, &propCount);
            for (unsigned int j = 0; j < propCount; j++) {
                NSString *propName = [NSString stringWithUTF8String:property_getName(props[j])];
                if ([propName containsString:@"path"] || [propName containsString:@"Path"] ||
                    [propName containsString:@"dir"] || [propName containsString:@"directory"] ||
                    [propName containsString:@"currentDir"]) {
                    id val = [shared valueForKey:propName];
                    if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                        NSString *pathVal = (NSString *)val;
                        if ([pathVal hasPrefix:@"/"] || [pathVal containsString:@"/"]) {
                            DLog(@"Found path in %@.%@ = %@", className, propName, pathVal);
                            gCurrentPath = pathVal;
                            gPathAutoDetected = YES;
                            free(props);
                            free(classes);
                            return;
                        }
                    }
                }
            }
            free(props);
        } @catch (NSException *e) { }
    }
    free(classes);
}

// ========== 自动检测 Token ==========

static NSString * autoDetectBdstoken(void) {
    // 1. 从 NSUserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:@"bdstoken"];
    if (token && token.length > 0) {
        DLog(@"Auto-detected bdstoken from NSUserDefaults");
        gTokenAutoDetected = YES;
        return token;
    }
    
    // 2. 从 Cookie 中的 BDUSS 推导（如果有 BDUSS，说明已登录）
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [storage cookiesForURL:[NSURL URLWithString:@"https://pan.baidu.com"]];
    for (NSHTTPCookie *cookie in cookies) {
        if ([cookie.name isEqualToString:@"BDUSS"] || [cookie.name isEqualToString:@"STOKEN"]) {
            // 已登录，尝试其他方式获取 token
            DLog(@"Found login cookie: %@", cookie.name);
            break;
        }
    }
    
    // 3. 从 WebView
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        NSString *tokenFromWebView = extractTokenFromWebView(window);
        if (tokenFromWebView) {
            gTokenAutoDetected = YES;
            return tokenFromWebView;
        }
    }
    
    // 4. 运行时扫描所有类
    scanAllClassesForToken();
    
    // 5. 尝试常见的百度网盘内部类
    NSArray *possibleClasses = @[
        @"BaiduPanFileManager", @"PanFileManager", @"BDFileService",
        @"BaiduPanUserManager", @"PanUserManager", @"BDUserService",
        @"BaiduPanConfig", @"PanConfig", @"BDConfig",
        @"BaiduPanManager", @"PanManager", @"FileManager",
        @"BaiduPanAccount", @"PanAccount", @"BDAccount",
        @"BaiduPanAuth", @"PanAuth", @"BDAuth",
        @"NetdiskFileManager", @"NetdiskUserManager", @"NetdiskConfig",
        @"BaiduNetdiskManager", @"BaiduNetdiskConfig", @"BaiduNetdiskUser"
    ];
    for (NSString *className in possibleClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;
        @try {
            id shared = nil;
            if ([cls respondsToSelector:@selector(sharedInstance)]) {
                shared = [cls performSelector:@selector(sharedInstance)];
            } else if ([cls respondsToSelector:@selector(shared)]) {
                shared = [cls performSelector:@selector(shared)];
            } else if ([cls respondsToSelector:@selector(defaultManager)]) {
                shared = [cls performSelector:@selector(defaultManager)];
            } else if ([cls respondsToSelector:@selector(currentManager)]) {
                shared = [cls performSelector:@selector(currentManager)];
            }
            
            if (!shared) continue;
            
            // 尝试所有可能的方法
            NSArray *possibleMethods = @[
                @"bdstoken", @"token", @"_bdstoken", @"_token",
                @"accessToken", @"access_token", @"userToken",
                @"getBdstoken", @"getToken", @"fetchToken"
            ];
            for (NSString *methodName in possibleMethods) {
                SEL sel = NSSelectorFromString(methodName);
                if ([shared respondsToSelector:sel]) {
                    id val = [shared performSelector:sel];
                    if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                        DLog(@"Auto-detected bdstoken from %@.%@", className, methodName);
                        gTokenAutoDetected = YES;
                        return (NSString *)val;
                    }
                }
            }
            
            // 尝试 Ivar
            unsigned int ivarCount = 0;
            Ivar *ivars = class_copyIvarList(cls, &ivarCount);
            for (unsigned int k = 0; k < ivarCount; k++) {
                NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(ivars[k])];
                if ([ivarName containsString:@"token"] || [ivarName containsString:@"Token"]) {
                    id val = object_getIvar(shared, ivars[k]);
                    if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                        DLog(@"Auto-detected bdstoken from %@ ivar %@", className, ivarName);
                        gTokenAutoDetected = YES;
                        free(ivars);
                        return (NSString *)val;
                    }
                }
            }
            free(ivars);
        } @catch (NSException *e) { }
    }
    
    return nil;
}

static NSString * getBdstoken(void) {
    if (gManualToken && gManualToken.length > 0) return gManualToken;
    NSString *autoToken = autoDetectBdstoken();
    if (autoToken) return autoToken;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:@"bdstoken"];
    if (token.length > 0) return token;
    return nil;
}

// ========== 自动检测路径 ==========

static NSString * getCurrentPath(void) {
    if (gCurrentPath && gCurrentPath.length > 0) return gCurrentPath;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *path = [defaults stringForKey:@"currentPath"];
    if (path.length > 0) return path;
    return @"/";
}

static NSString * extractPathFromURL(NSString *urlString) {
    if (!urlString || urlString.length == 0) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    if ([url.path containsString:@"/api/list"]) {
        NSString *query = url.query;
        if (query) {
            NSArray *pairs = [query componentsSeparatedByString:@"&"];
            for (NSString *pair in pairs) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count == 2 && [kv[0] isEqualToString:@"dir"]) {
                    NSString *decoded = [kv[1] stringByRemovingPercentEncoding];
                    if (decoded && decoded.length > 0) {
                        DLog(@"[Hook] Extracted path from /api/list dir=%@", decoded);
                        return decoded;
                    }
                }
            }
        }
    }
    if ([url.path containsString:@"/api/filemetas"]) {
        NSString *query = url.query;
        if (query) {
            NSArray *pairs = [query componentsSeparatedByString:@"&"];
            for (NSString *pair in pairs) {
                NSArray *kv = [pair componentsSeparatedByString:@"="];
                if (kv.count == 2 && [kv[0] isEqualToString:@"path"]) {
                    NSString *decoded = [kv[1] stringByRemovingPercentEncoding];
                    if (decoded && decoded.length > 0) {
                        NSRange lastSlash = [decoded rangeOfString:@"/" options:NSBackwardsSearch];
                        if (lastSlash.location != NSNotFound && lastSlash.location > 0) {
                            NSString *dirPath = [decoded substringToIndex:lastSlash.location];
                            if (dirPath.length == 0) dirPath = @"/";
                            DLog(@"[Hook] Extracted path from /api/filemetas path=%@", dirPath);
                            return dirPath;
                        }
                    }
                }
            }
        }
    }
    return nil;
}

static NSString * extractPathFromViewController(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *pathKeys = @[@"currentPath", @"path", @"dirPath", @"currentDir", @"m_path", @"_currentPath", @"_path", @"directoryPath", @"currentDirectoryPath", @"m_directoryPath", @"folderPath", @"currentFolderPath", @"m_currentPath"];
    for (NSString *key in pathKeys) {
        @try {
            id val = [vc valueForKey:key];
            if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) return val;
        } @catch (NSException *e) { }
    }
    for (UIViewController *child in vc.childViewControllers) {
        NSString *p = extractPathFromViewController(child);
        if (p) return p;
    }
    return nil;
}

static NSString * getPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;
    NSString *path = extractPathFromViewController(vc);
    if (path) return path;
    if ([vc.navigationController isKindOfClass:[UINavigationController class]]) {
        NSArray *vcs = vc.navigationController.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            path = extractPathFromViewController(vcs[i]);
            if (path) return path;
        }
    }
    return nil;
}

static void autoDetectPathAndToken(void) {
    // 先尝试从 ViewController 获取路径
    NSString *autoPath = getPathFromNavStack();
    if (autoPath) {
        gCurrentPath = autoPath;
        gPathAutoDetected = YES;
        DLog(@"Auto path (VC): %@", autoPath);
    }
    
    // 如果失败，运行时扫描所有类
    if (!gPathAutoDetected || !gCurrentPath || gCurrentPath.length == 0) {
        scanAllClassesForPath();
    }
    
    // 如果还是失败，使用默认
    if (!gCurrentPath || gCurrentPath.length == 0) {
        gCurrentPath = @"/";
    }
    
    // 检测 token
    NSString *autoToken = autoDetectBdstoken();
    if (autoToken) {
        gManualToken = autoToken;
        DLog(@"Auto token: OK (length=%lu)", (unsigned long)autoToken.length);
    } else {
        DLog(@"Auto token failed, need manual input");
    }
}

// ========== UI 模拟点击辅助 ==========

static UIView *findSubviewWithText(UIView *view, NSString *text) {
    if (!view || !text) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if (label.text && [label.text containsString:text]) return label;
    }
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        if (tf.text && [tf.text containsString:text]) return tf;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *btnTitle = [btn titleForState:UIControlStateNormal];
        if (btnTitle && [btnTitle containsString:text]) return btn;
    }
    if (view.accessibilityLabel && [view.accessibilityLabel containsString:text]) return view;
    
    for (UIView *subview in view.subviews) {
        UIView *found = findSubviewWithText(subview, text);
        if (found) return found;
    }
    return nil;
}

static void performTapOnView(UIView *view) {
    if (!view) return;
    UIView *target = view;
    while (target) {
        if ([target isKindOfClass:[UIControl class]] && target.gestureRecognizers.count > 0) break;
        if ([target isKindOfClass:[UITableViewCell class]] || [target isKindOfClass:[UICollectionViewCell class]]) break;
        target = target.superview;
    }
    if (!target) target = view;

    if ([target isKindOfClass:[UIControl class]]) {
        [(UIControl *)target sendActionsForControlEvents:UIControlEventTouchUpInside];
        DLog(@"Simulated UIControl tap");
        return;
    }
    if ([target isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)target;
        UITableView *tableView = nil;
        UIView *parent = cell.superview;
        while (parent) {
            if ([parent isKindOfClass:[UITableView class]]) { tableView = (UITableView *)parent; break; }
            parent = parent.superview;
        }
        if (tableView) {
            NSIndexPath *indexPath = [tableView indexPathForCell:cell];
            if (indexPath) {
                [tableView selectRowAtIndexPath:indexPath animated:YES scrollPosition:UITableViewScrollPositionNone];
                if (tableView.delegate && [tableView.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                    [tableView.delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
                }
                DLog(@"Simulated UITableViewCell selection at %@", indexPath);
            }
        }
        return;
    }
    if ([target isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)target;
        UICollectionView *collectionView = nil;
        UIView *parent = cell.superview;
        while (parent) {
            if ([parent isKindOfClass:[UICollectionView class]]) { collectionView = (UICollectionView *)parent; break; }
            parent = parent.superview;
        }
        if (collectionView) {
            NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
            if (indexPath) {
                [collectionView selectItemAtIndexPath:indexPath animated:YES scrollPosition:UICollectionViewScrollPositionNone];
                if (collectionView.delegate && [collectionView.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                    [collectionView.delegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
                }
                DLog(@"Simulated UICollectionViewCell selection at %@", indexPath);
            }
        }
        return;
    }
}

static void simulateTapFileNamed(NSString *fileName) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *targetView = findSubviewWithText(vc.view, fileName);
        if (targetView) {
            DLog(@"Found view for '%@', performing tap", fileName);
            performTapOnView(targetView);
        } else {
            DLog(@"Could not find view for '%@', user manual tap needed", fileName);
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"请手动点击" message:[NSString stringWithFormat:@"未能在当前界面自动定位到 '%@'，请在文件列表中手动点击该文件以触发下载", fileName] preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:alert animated:YES completion:nil];
        }
    });
}

// ========== 核心 API ==========

static void fetchFileList(NSString *path, void (^completion)(NSArray *files, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }
    NSString *encPath = strictEncodeURIComponent(path);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dir=%@&order=time&desc=1&showempty=0&page=1&num=100&t=%ld", token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"Fetch list: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            completion(json[@"list"] ?: @[], nil);
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"Error: %ld", (long)errnoVal];
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static NSString * digOutDlink(id obj) {
    if (!obj || ![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = obj;
    NSString *dlink = dict[@"dlink"];
    if ([dlink isKindOfClass:[NSString class]] && dlink.length > 0) return dlink;
    id data = dict[@"data"];
    if ([data isKindOfClass:[NSDictionary class]]) {
        dlink = data[@"dlink"];
        if ([dlink isKindOfClass:[NSString class]] && dlink.length > 0) return dlink;
    }
    for (id value in dict.allValues) {
        if ([value isKindOfClass:[NSDictionary class]]) {
            NSString *found = digOutDlink(value);
            if (found) return found;
        }
    }
    return nil;
}

static void fetchDlinkViaFilemetas(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }
    NSString *normalizedPath = filePath;
    if (![normalizedPath hasPrefix:@"/"]) normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%ld", token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"Fetch filemetas: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            if (retry < kDlinkRetryCount) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    fetchDlinkViaFilemetas(filePath, retry + 1, completion);
                });
                return;
            }
            completion(nil, err);
            return;
        }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        DLog(@"filemetas response: errno=%ld", (long)errnoVal);
        if (errnoVal == 0) {
            NSArray *info = json[@"info"] ?: json[@"list"];
            if ([info count] > 0) {
                NSString *dlink = info[0][@"dlink"];
                if (dlink.length > 0) { completion(dlink, nil); return; }
            }
            NSString *dlink = digOutDlink(json);
            if (dlink) { completion(dlink, nil); return; }
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No dlink"}]);
        } else if (errnoVal == -9 && retry < kDlinkRetryCount) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fetchDlinkViaFilemetas(filePath, retry + 1, completion);
            });
            return;
        }
        NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"filemetas Error: %ld", (long)errnoVal];
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
    });
}

static void fetchDlinkViaLocateDownload(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }
    NSString *normalizedPath = filePath;
    if (![normalizedPath hasPrefix:@"/"]) normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/locatedownload?clienttype=0&app_id=250528&web=1&channel=chunlei&path=%@&origin=pdf&use=1&bdstoken=%@", encPath, token];
    DLog(@"Fetch locatedownload: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            if (retry < kDlinkRetryCount) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    fetchDlinkViaLocateDownload(filePath, retry + 1, completion);
                });
                return;
            }
            completion(nil, err);
            return;
        }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        DLog(@"locatedownload response: errno=%ld", (long)errnoVal);
        if (errnoVal == 0 || errnoVal == 1) {
            NSString *dlink = digOutDlink(json);
            if (dlink) { completion(dlink, nil); return; }
        }
        if (errnoVal == -9 && retry < kDlinkRetryCount) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fetchDlinkViaLocateDownload(filePath, retry + 1, completion);
            });
            return;
        }
        NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"locatedownload Error: %ld", (long)errnoVal];
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
    });
}

static void fetchDlinkPortal(NSString *filePath, void (^completion)(NSString *dlink, NSError *err)) {
    fetchDlinkViaFilemetas(filePath, 0, ^(NSString *dlink, NSError *err) {
        if (dlink) { completion(dlink, nil); return; }
        DLog(@"filemetas failed: %@, trying locatedownload...", err.localizedDescription);
        fetchDlinkViaLocateDownload(filePath, 0, ^(NSString *dlink2, NSError *err2) {
            if (dlink2) { completion(dlink2, nil); return; }
            NSString *combinedMsg = [NSString stringWithFormat:@"filemetas: %@\nlocatedownload: %@", err.localizedDescription, err2.localizedDescription];
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: combinedMsg}]);
        });
    });
}

static void refreshFileMeta(NSString *filePath, void (^completion)(void)) {
    NSString *token = getBdstoken();
    if (!token) { if (completion) completion(); return; }
    NSString *normalizedPath = filePath;
    if (![normalizedPath hasPrefix:@"/"]) normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%ld", token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (completion) completion();
    });
}

static void refreshFileListCache(NSString *path, void (^completion)(void)) {
    NSString *token = getBdstoken();
    if (!token) { if (completion) completion(); return; }
    NSString *encPath = strictEncodeURIComponent(path);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&clienttype=0&app_id=250528&web=1&channel=chunlei&desc=1&showempty=0&page=1&num=10&order=time&t=%ld", encPath, token, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (completion) completion();
    });
}

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(NO, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=rename&clienttype=0&app_id=250528&web=1&bdstoken=%@", token];
    NSArray *list = @[@{@"id": @([fileId integerValue]), @"path": path, @"newname": newName}];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    NSString *listStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *body = [NSString stringWithFormat:@"filelist=%@", strictEncodeURIComponent(listStr)];
    bdAsyncRequest(url, @"POST", nil, body, ^(id json, NSError *err) {
        if (err) { completion(NO, err); return; }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"Rename failed";
            completion(NO, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

// ========== 弹窗 UI ==========

static void showErrorPopup(NSString *message) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"失败" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void showRestorePopup(NSString *originalName, NSString *renamedName, NSString *renamedPath, NSString *fileId, NSString *dlink) {
    UIViewController *vc = topViewController();
    if (!vc) return;

    if (dlink && dlink.length > 0) {
        [[UIPasteboard generalPasteboard] setString:dlink];
    }

    NSString *msg = [NSString stringWithFormat:
        @"文件已临时重命名为：%@\n\n已尝试触发百度网盘 App 内预览/下载（利用 SVIP 通道）。\n\n直链已复制到剪贴板（备用）。\n\n⚠️ 下载完成后，请点击「恢复文件名」改回原名，否则文件将一直保持 .pdf 后缀。",
        renamedName];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"下载已触发" message:msg preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"✅ 恢复文件名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        renameFile(fileId, renamedPath, originalName, ^(BOOL success, NSError *err) {
            if (success) {
                UIAlertController *ok = [UIAlertController alertControllerWithTitle:@"完成" message:@"文件名已恢复" preferredStyle:UIAlertControllerStyleAlert];
                [ok addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [vc presentViewController:ok animated:YES completion:nil];
            } else {
                showErrorPopup(err.localizedDescription);
            }
        });
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"稍后再恢复" style:UIAlertActionStyleCancel handler:nil]];

    [vc presentViewController:alert animated:YES completion:nil];
}

// ========== 主流程 ==========

static void runPipeline(NSString *fileName, NSString *fileId, NSString *currentPath, NSInteger fileSize) {
    NSString *originalName = fileName;

    NSString *fullPath;
    if ([currentPath isEqualToString:@"/"]) {
        fullPath = [NSString stringWithFormat:@"/%@", originalName];
    } else {
        fullPath = [NSString stringWithFormat:@"%@/%@", currentPath, originalName];
    }
    DLog(@"Final path: %@", fullPath);

    if ([originalName hasSuffix:@".pdf"]) {
        fetchDlinkPortal(fullPath, ^(NSString *dlink, NSError *err) {
            if (dlink) {
                [[UIPasteboard generalPasteboard] setString:dlink];
                showRestorePopup(originalName, originalName, fullPath, fileId, dlink);
            } else {
                showErrorPopup(err.localizedDescription);
            }
        });
        return;
    }

    NSString *renamedName = [originalName stringByAppendingString:@".pdf"];
    DLog(@"Rename: %@ -> %@", fullPath, renamedName);

    renameFile(fileId, fullPath, renamedName, ^(BOOL success, NSError *err) {
        if (!success) {
            showErrorPopup(err.localizedDescription);
            return;
        }

        NSString *renamedPath = [currentPath isEqualToString:@"/"] ? [NSString stringWithFormat:@"/%@", renamedName] : [NSString stringWithFormat:@"%@/%@", currentPath, renamedName];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWaitTimeAfterRename * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{

            void (^doFetch)(void) = ^{
                fetchDlinkPortal(renamedPath, ^(NSString *dlink, NSError *err) {
                    if (!dlink) {
                        renameFile(fileId, renamedPath, originalName, ^(BOOL s, NSError *e) {
                            if (!s) DLog(@"Restore failed: %@", e.localizedDescription);
                            showErrorPopup(err.localizedDescription);
                        });
                        return;
                    }

                    refreshFileListCache(currentPath, ^{
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            simulateTapFileNamed(renamedName);
                            showRestorePopup(originalName, renamedName, renamedPath, fileId, dlink);
                        });
                    });
                });
            };

            if (fileSize > kLargeFileThreshold) {
                DLog(@"Large file (%ld MB), extra wait", (long)(fileSize/1024/1024));
                refreshFileListCache(currentPath, ^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        refreshFileMeta(renamedPath, ^{
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLargeFileExtraWait * NSEC_PER_MSEC)), dispatch_get_main_queue(), doFetch);
                        });
                    });
                });
            } else {
                doFetch();
            }
        });
    });
}

// ========== NSURLSession Hook ==========

@interface NSURLSession (HKCHook)
@end

@implementation NSURLSession (HKCHook)

- (NSURLSessionDataTask *)hkc_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *urlString = request.URL.absoluteString;
    if ([urlString containsString:@"pan.baidu.com"]) {
        NSString *path = extractPathFromURL(urlString);
        if (path && path.length > 0) {
            gCurrentPath = path;
            gPathAutoDetected = YES;
        }
        if ([urlString containsString:@"bdstoken="]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"bdstoken=([^&]+)" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
            if (match && match.numberOfRanges > 1) {
                NSString *token = [urlString substringWithRange:[match rangeAtIndex:1]];
                if (token && token.length > 0) {
                    gManualToken = token;
                    gTokenAutoDetected = YES;
                    DLog(@"Auto-captured bdstoken from URL");
                }
            }
        }
    }
    return [self hkc_dataTaskWithRequest:request completionHandler:completionHandler];
}

- (NSURLSessionDataTask *)hkc_dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *urlString = url.absoluteString;
    if ([urlString containsString:@"pan.baidu.com"]) {
        NSString *path = extractPathFromURL(urlString);
        if (path && path.length > 0) {
            gCurrentPath = path;
            gPathAutoDetected = YES;
        }
        if ([urlString containsString:@"bdstoken="]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"bdstoken=([^&]+)" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:urlString options:0 range:NSMakeRange(0, urlString.length)];
            if (match && match.numberOfRanges > 1) {
                NSString *token = [urlString substringWithRange:[match rangeAtIndex:1]];
                if (token && token.length > 0) {
                    gManualToken = token;
                    gTokenAutoDetected = YES;
                }
            }
        }
    }
    return [self hkc_dataTaskWithURL:url completionHandler:completionHandler];
}

@end

// ========== 悬浮按钮 ==========

@interface HKCButtonHelper : NSObject
+ (instancetype)shared;
- (void)buttonTapped:(UIButton *)sender;
- (void)pan:(UIPanGestureRecognizer *)pan;
@end

@implementation HKCButtonHelper

+ (instancetype)shared {
    static HKCButtonHelper *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[HKCButtonHelper alloc] init]; });
    return instance;
}

- (void)showManualInputDialog:(UIViewController *)vc {
    UIAlertController *input = [UIAlertController alertControllerWithTitle:@"手动输入" message:@"自动检测失败，请手动输入" preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Filename"; }];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"bdstoken"; tf.text = gManualToken ?: @""; }];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Path"; tf.text = getCurrentPath(); }];
    [input addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *fileName = input.textFields[0].text;
        NSString *token = input.textFields[1].text;
        NSString *path = input.textFields[2].text;
        if (fileName.length == 0) return;
        if (token.length > 0) gManualToken = token;
        if (path.length > 0) gCurrentPath = path;
        runPipeline(fileName, @"0", getCurrentPath(), 0);
    }]];
    [vc presentViewController:input animated:YES completion:nil];
}

- (void)showFilePicker:(UIViewController *)vc files:(NSArray *)files {
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择文件" message:[NSString stringWithFormat:@"路径: %@\n文件数: %lu", getCurrentPath(), (unsigned long)files.count] preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *file in files) {
        NSString *name = file[@"server_filename"] ?: file[@"path"];
        NSInteger size = [file[@"size"] integerValue];
        NSString *sizeStr = size > 1024*1024 ? [NSString stringWithFormat:@"%.1fMB", size/1024.0/1024.0] : [NSString stringWithFormat:@"%.1fKB", size/1024.0];
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, sizeStr];
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *fileName = file[@"server_filename"];
            NSString *fileId = [NSString stringWithFormat:@"%@", file[@"fs_id"]];
            NSInteger fileSize = [file[@"size"] integerValue];
            runPipeline(fileName, fileId, getCurrentPath(), fileSize);
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"手动输入" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [self showManualInputDialog:vc]; }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UIPopoverPresentationController *pop = picker.popoverPresentationController;
        if (pop) { pop.sourceView = vc.view; pop.sourceRect = CGRectMake(vc.view.bounds.size.width/2, vc.view.bounds.size.height/2, 1, 1); pop.permittedArrowDirections = 0; }
    }
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)buttonTapped:(UIButton *)sender {
    @try {
        UIViewController *vc = topViewController();
        if (!vc) return;

        // 重置检测状态
        gPathAutoDetected = NO;
        gTokenAutoDetected = NO;
        
        // 执行自动检测
        autoDetectPathAndToken();

        BOOL needToken = !getBdstoken();
        BOOL needPath = !gCurrentPath || gCurrentPath.length == 0 || [gCurrentPath isEqualToString:@"/"];

        if (needToken || needPath) {
            [self showSetupDialog:vc];
        } else {
            DLog(@"Auto-detect success, path=%@, token=%@", getCurrentPath(), getBdstoken() ? @"OK" : @"FAIL");
            [self proceedWithFileList:vc];
        }
    } @catch (NSException *e) {
        DLog(@"Button tap error: %@", e.reason);
    }
}

- (void)showSetupDialog:(UIViewController *)vc {
    NSString *detectedPath = getCurrentPath();
    NSString *pathStatus = gPathAutoDetected ? @"✅ 路径自动检测成功" : @"❌ 路径自动检测失败";
    NSString *tokenStatus = gTokenAutoDetected ? @"✅ Token 自动检测成功" : @"❌ Token 自动检测失败";

    UIAlertController *setup = [UIAlertController alertControllerWithTitle:@"设置" message:[NSString stringWithFormat:@"%@\n%@\n\n请补充或修改", pathStatus, tokenStatus] preferredStyle:UIAlertControllerStyleAlert];

    [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"路径, e.g. /foldername";
        tf.text = detectedPath;
    }];
    [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken";
        tf.text = gManualToken ?: @"";
    }];

    [setup addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [setup addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *userPath = setup.textFields[0].text;
        NSString *token = setup.textFields[1].text;
        if (userPath.length > 0) gCurrentPath = userPath;
        if (token.length > 0) gManualToken = token;
        
        // 保存到 NSUserDefaults 供下次使用
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (userPath.length > 0) [defaults setObject:userPath forKey:@"currentPath"];
        if (token.length > 0) [defaults setObject:token forKey:@"bdstoken"];
        [defaults synchronize];
        
        if (!getBdstoken()) {
            showErrorPopup(@"请输入 bdstoken");
            return;
        }
        DLog(@"Setup path: %@, token len: %lu", getCurrentPath(), (unsigned long)gManualToken.length);
        [self proceedWithFileList:vc];
    }]];

    [vc presentViewController:setup animated:YES completion:nil];
}

- (void)proceedWithFileList:(UIViewController *)vc {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"加载中" message:@"正在获取文件列表..." preferredStyle:UIAlertControllerStyleAlert];
    [vc presentViewController:loading animated:YES completion:nil];

    fetchFileList(getCurrentPath(), ^(NSArray *files, NSError *err) {
        [loading dismissViewControllerAnimated:YES completion:^{
            if (err) { showErrorPopup(err.localizedDescription); return; }
            if (files.count == 0) { showErrorPopup(@"该目录没有文件"); return; }
            NSMutableArray *fileItems = [NSMutableArray array];
            for (NSDictionary *f in files) { if ([f[@"isdir"] integerValue] == 0) [fileItems addObject:f]; }
            if (fileItems.count == 0) { showErrorPopup(@"该目录只有文件夹"); return; }
            [self showFilePicker:vc files:fileItems];
        }];
    });
}

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

@end

static void addFloatingButton(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
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
                UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
                btn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 70, 250, 56, 56);
                btn.backgroundColor = [UIColor colorWithRed:0.4 green:0.48 blue:0.92 alpha:0.95];
                btn.layer.cornerRadius = 28;
                btn.layer.shadowColor = [UIColor blackColor].CGColor;
                btn.layer.shadowOffset = CGSizeMake(0, 2);
                btn.layer.shadowOpacity = 0.3;
                btn.layer.shadowRadius = 4;
                [btn setTitle:@"Link" forState:UIControlStateNormal];
                [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
                btn.alpha = 0.9;
                [btn addTarget:[HKCButtonHelper shared] action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[HKCButtonHelper shared] action:@selector(pan:)];
                [btn addGestureRecognizer:pan];
                [window addSubview:btn];
                DLog(@"Button added");
            } @catch (NSException *e) {
                DLog(@"Add button error: %@", e.reason);
            }
        });
    });
}

static void swizzleInstanceMethod(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (!originalMethod || !swizzledMethod) return;
    BOOL didAddMethod = class_addMethod(cls, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) {
        class_replaceMethod(cls, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

@interface UIViewController (HKCPathHook)
@end

@implementation UIViewController (HKCPathHook)

- (void)hkc_viewDidAppear:(BOOL)animated {
    [self hkc_viewDidAppear:animated];
    NSString *path = extractPathFromViewController(self);
    if (path && path.length > 0) {
        gCurrentPath = path;
        gPathAutoDetected = YES;
        DLog(@"[Swizzle] Path: %@ from %@", path, NSStringFromClass([self class]));
    }
}

@end

__attribute__((constructor)) static void init() {
    DLog(@"Loaded v6.3 (arm64) - Aggressive Auto Detect");

    static dispatch_once_t sessionOnce;
    dispatch_once(&sessionOnce, ^{
        swizzleInstanceMethod([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:), @selector(hkc_dataTaskWithRequest:completionHandler:));
        swizzleInstanceMethod([NSURLSession class], @selector(dataTaskWithURL:completionHandler:), @selector(hkc_dataTaskWithURL:completionHandler:));
        DLog(@"NSURLSession hook registered");
    });

    static dispatch_once_t swizzleOnce;
    dispatch_once(&swizzleOnce, ^{
        swizzleInstanceMethod([UIViewController class], @selector(viewDidAppear:), @selector(hkc_viewDidAppear:));
        DLog(@"UIViewController swizzle registered");
    });

    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            DLog(@"App active, add button");
            addFloatingButton();
        }];
        DLog(@"Notification set");
    } @catch (NSException *e) {
        DLog(@"Init error: %@", e.reason);
    }
}
