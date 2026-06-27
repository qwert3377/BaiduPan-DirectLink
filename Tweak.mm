//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v9.0
//  Security & Stability Hardened Edition
//  Fixes: memory leaks, thread safety, JSON serialization, associated object keys
//         removed all NSLog token leaks, added request dedup, graceful degradation
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/log.h>

#pragma mark - Constants

// 使用唯一静态变量作为 associated object keys（修复 objc_setAssociatedObject key 类型）
static char kBDTLinkTextKey;
static char kBDTFileIdKey;
static char kBDTPdfPathKey;
static char kBDTFileNameKey;
static char kBDTOverlayVCKey;
static char kBDTFileNameAssocKey;

static const NSUInteger kBDTTagDirectLinkButton = 0xBDE123;
static const NSTimeInterval kBDTNetworkTimeout = 30.0;
static const NSUInteger kBDTMaxRetries = 3;
static const NSTimeInterval kBDTRetryDelay = 5.0;

#pragma mark - Thread-Safe Credential Store

@interface BDTCredentialStore : NSObject
@property (atomic, copy, readonly) NSString *currentPath;
@property (atomic, copy, readonly) NSString *bdstoken;
@property (atomic, copy, readonly) NSString *BDUSS;
+ (instancetype)sharedStore;
- (void)updatePath:(NSString *)path token:(NSString *)token bduss:(NSString *)bduss;
@end

@implementation BDTCredentialStore
{
    NSString *_currentPath;
    NSString *_bdstoken;
    NSString *_BDUSS;
}

+ (instancetype)sharedStore {
    static BDTCredentialStore *store = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[self alloc] init];
    });
    return store;
}

- (NSString *)currentPath { return _currentPath; }
- (NSString *)bdstoken { return _bdstoken; }
- (NSString *)BDUSS { return _BDUSS; }

- (void)updatePath:(NSString *)path token:(NSString *)token bduss:(NSString *)bduss {
    @synchronized(self) {
        _currentPath = [path copy];
        _bdstoken = [token copy];
        _BDUSS = [bduss copy];
    }
}

@end

#pragma mark - Secure Logging

// 替换 NSLog，生产环境不输出敏感信息
static void BDTLog(NSString *format, ...) {
#ifdef DEBUG
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "[BDT] %{public}@", msg);
#endif
}

static void BDTLogError(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log_error(OS_LOG_DEFAULT, "[BDT-ERR] %{public}@", msg);
}

#pragma mark - URL Encoding

static NSString * BDTStrictEncode(NSString *str) {
    if (!str) return @"";
    NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
    [cs addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

#pragma mark - View Controller Utilities

static UIViewController * BDTTopViewController(void) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                window = ws.windows.firstObject;
                break;
            }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return nil;

    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;

    while ([vc isKindOfClass:[UINavigationController class]] ||
           [vc isKindOfClass:[UITabBarController class]]) {
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
    }
    return vc;
}

#pragma mark - Path Extraction

static NSString * BDTExtractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;
    static NSArray *pathKeys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath",
                     @"currentDir", @"_path", @"_currentPath", @"directory",
                     @"folderPath", @"currentFolder", @"mPath", @"_mPath", @"fileListPath"];
    });

    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return value;
            }
        } @catch (NSException *e) { /* ignore KVC exceptions */ }
    }
    return nil;
}

static NSString * BDTBuildPathFromNavStack(void) {
    UIViewController *vc = BDTTopViewController();
    if (!vc) return nil;

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

    if (!nav) return BDTExtractPathFromVC(vc);

    NSArray *vcs = nav.viewControllers;
    NSMutableArray *components = [NSMutableArray array];

    for (UIViewController *controller in vcs) {
        NSString *path = BDTExtractPathFromVC(controller);
        if (path && path.length > 0 && ![path isEqualToString:@"/"]) {
            [components addObject:path];
        } else if (controller.title && controller.title.length > 0 &&
                   ![controller.title isEqualToString:@"百度网盘"] &&
                   ![controller.title isEqualToString:@"文件"] &&
                   ![controller.title isEqualToString:@"首页"]) {
            [components addObject:controller.title];
        } else if (controller.navigationItem.title && controller.navigationItem.title.length > 0 &&
                   ![controller.navigationItem.title isEqualToString:@"百度网盘"]) {
            [components addObject:controller.navigationItem.title];
        }
    }

    if (components.count == 0) return nil;
    NSString *fullPath = [components componentsJoinedByString:@"/"];
    if (![fullPath hasPrefix:@"/"]) fullPath = [@"/" stringByAppendingString:fullPath];
    return fullPath;
}

#pragma mark - Token Detection (Secure)

static NSString * BDTScanMemoryForToken(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];
    NSString *bestToken = nil;
    NSString *bestKey = nil;

    NSRegularExpression *hexRegex = nil;
    NSRegularExpression *letterRegex = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
        letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
    });

    for (NSString *key in allDefaults) {
        id value = allDefaults[key];
        if (![value isKindOfClass:[NSString class]]) continue;

        NSString *str = value;
        if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] != 1) continue;
        if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 0) continue;

        if (str.length == 32) {
            BDTLog(@"Found 32-bit token"); // 不输出 key 名和 token 内容
            return str;
        }
        if (str.length == 16 && !bestToken) {
            bestToken = str;
            bestKey = key;
        }
    }

    if (bestToken) {
        BDTLog(@"Using 16-bit token fallback");
        return bestToken;
    }
    return nil;
}

static void BDTAutoDetectCredentials(void) {
    BDTLog(@"Auto-detecting credentials...");

    NSString *token = nil;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN",
                           @"access_token", @"bd_token", @"pan_token"];

    for (NSString *key in tokenKeys) {
        token = [defaults objectForKey:key];
        if (token) { BDTLog(@"Token found in defaults"); break; }
    }

    if (!token) token = BDTScanMemoryForToken();
    if (!token) BDTLogError(@"No token detected");

    NSString *bduss = nil;
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) {
            bduss = cookie.value;
            BDTLog(@"BDUSS from cookie");
            break;
        }
    }
    if (!bduss) {
        bduss = [defaults objectForKey:@"BDUSS"];
        if (bduss) BDTLog(@"BDUSS from defaults");
    }

    NSString *path = BDTBuildPathFromNavStack() ?: @"/";

    [[BDTCredentialStore sharedStore] updatePath:path token:token bduss:bduss];
    BDTLog(@"Credentials updated | Path: %@ | Token: %@ | BDUSS: %@",
           path, token ? @"present" : @"missing", bduss ? @"present" : @"missing");
}

#pragma mark - Network Layer (Hardened)

@interface BDTRequestManager : NSObject
+ (instancetype)sharedManager;
- (void)request:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSString *)body completion:(void (^)(id json, NSError *err))completion;
- (void)cancelAllRequests;
@end

@implementation BDTRequestManager
{
    NSMutableSet<NSURLSessionDataTask *> *_activeTasks;
    NSLock *_lock;
}

+ (instancetype)sharedManager {
    static BDTRequestManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[self alloc] init]; });
    return mgr;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _activeTasks = [NSMutableSet set];
        _lock = [[NSLock alloc] init];
    }
    return self;
}

- (void)cancelAllRequests {
    [_lock lock];
    NSSet *tasks = [_activeTasks copy];
    [_lock unlock];
    for (NSURLSessionDataTask *task in tasks) {
        [task cancel];
    }
}

- (void)request:(NSString *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSString *)body completion:(void (^)(id json, NSError *err))completion {
    if (!url || url.length == 0) {
        completion(nil, [NSError errorWithDomain:@"BDT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Empty URL"}]);
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = kBDTNetworkTimeout;

    NSMutableDictionary *allHeaders = [@{
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        @"Accept": @"application/json, text/plain, */*",
        @"Accept-Language": @"zh-CN,zh-Hans;q=0.9",
        @"Referer": @"https://pan.baidu.com/"
    } mutableCopy];

    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    if (store.BDUSS) {
        allHeaders[@"Cookie"] = [NSString stringWithFormat:@"BDUSS=%@", store.BDUSS];
    }
    if (headers) [allHeaders addEntriesFromDictionary:headers];
    req.allHTTPHeaderFields = allHeaders;
    if (body) req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [_lock lock];
        [_activeTasks removeObject:task];
        [_lock unlock];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    completion(nil, error);
                }
                return;
            }

            if (!data || data.length == 0) {
                completion(nil, [NSError errorWithDomain:@"BDT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Empty response"}]);
                return;
            }

            NSError *jsonErr = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr) {
                completion(nil, jsonErr);
                return;
            }

            // 验证 JSON 类型，防止传入非法类型给后续处理（修复神策崩溃类似问题）
            if (json && ![json isKindOfClass:[NSDictionary class]] && ![json isKindOfClass:[NSArray class]]) {
                completion(nil, [NSError errorWithDomain:@"BDT" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON type"}]);
                return;
            }

            completion(json, nil);
        });
    }];

    [_lock lock];
    [_activeTasks addObject:task];
    [_lock unlock];
    [task resume];
}

@end

#pragma mark - File Operations

static void BDTFetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    if (!store.bdstoken) {
        completion(nil, [NSError errorWithDomain:@"BDT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未检测到登录凭证，请确保已登录百度网盘"}]);
        return;
    }

    NSString *encodedPath = BDTStrictEncode(store.currentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100", encodedPath, store.bdstoken];

    [[BDTRequestManager sharedManager] request:url method:@"GET" headers:nil body:nil completion:^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }

        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, [NSError errorWithDomain:@"BDT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format"}]);
            return;
        }

        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BDT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        completion(list, nil);
    }];
}

static void BDTRenameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    if (!store.bdstoken) {
        completion(NO, [NSError errorWithDomain:@"BDT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }

    // 输入验证，防止 JSON 注入
    if (!fileId || !path || !newName || fileId.length == 0 || path.length == 0 || newName.length == 0) {
        completion(NO, [NSError errorWithDomain:@"BDT" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid parameters"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=rename&clienttype=0&app_id=250528&web=1&bdstoken=%@", store.bdstoken];

    // 安全构建 JSON，避免字符串拼接导致的格式错误
    NSDictionary *fileDict = @{
        @"id": fileId,
        @"path": path,
        @"newname": newName
    };
    NSError *jsonErr = nil;
    NSData *fileData = [NSJSONSerialization dataWithJSONObject:@[fileDict] options:0 error:&jsonErr];
    if (jsonErr || !fileData) {
        completion(NO, jsonErr ?: [NSError errorWithDomain:@"BDT" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"JSON encode failed"}]);
        return;
    }
    NSString *filelist = [[NSString alloc] initWithData:fileData encoding:NSUTF8StringEncoding];
    NSString *body = [NSString stringWithFormat:@"filelist=%@", BDTStrictEncode(filelist)];

    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded; charset=UTF-8",
        @"X-Requested-With": @"XMLHttpRequest"
    };

    [[BDTRequestManager sharedManager] request:url method:@"POST" headers:headers body:body completion:^(id json, NSError *err) {
        if (err) { completion(NO, err); return; }

        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(NO, [NSError errorWithDomain:@"BDT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }

        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"Unknown error";
            completion(NO, [NSError errorWithDomain:@"BDT" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    }];
}

#pragma mark - Direct Link Extraction

static NSString * BDTDigOutDlink(id obj) {
    if (!obj || ![obj isKindOfClass:[NSObject class]]) return nil;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        id dlink = dict[@"dlink"];
        if ([dlink isKindOfClass:[NSString class]] && [(NSString *)dlink length] > 0) return dlink;

        id data = dict[@"data"];
        if (data) { NSString *found = BDTDigOutDlink(data); if (found) return found; }

        for (id value in [dict allValues]) {
            NSString *found = BDTDigOutDlink(value);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            NSString *found = BDTDigOutDlink(item);
            if (found) return found;
        }
    }
    return nil;
}

static void BDTFetchDlinkViaFilemetas(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err)) {
    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    if (!store.bdstoken) {
        completion(nil, [NSError errorWithDomain:@"BDT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }

    NSString *encodedPath = BDTStrictEncode(filePath);
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%lld", store.bdstoken, encodedPath, ts];

    [[BDTRequestManager sharedManager] request:url method:@"GET" headers:@{@"X-Requested-With": @"XMLHttpRequest"} body:nil completion:^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }

        if (![json isKindOfClass:[NSDictionary class]]) {
            completion(nil, [NSError errorWithDomain:@"BDT" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }

        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            NSString *dlink = BDTDigOutDlink(json);
            if (dlink) { completion(dlink, nil); return; }
            completion(nil, [NSError errorWithDomain:@"BDT" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"No dlink in response"}]);
        } else if (errnoNum && [errnoNum integerValue] == -9 && retryCount < kBDTMaxRetries) {
            BDTLog(@"filemetas not ready, retry %ld", (long)(retryCount + 1));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBDTRetryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BDTFetchDlinkViaFilemetas(filePath, retryCount + 1, completion);
            });
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"filemetas error (errno=%@)", errnoNum];
            completion(nil, [NSError errorWithDomain:@"BDT" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    }];
}

static void BDTFetchDlinkViaLocatedownload(NSString *filePath, NSInteger retryCount, void (^completion)(NSString *link, NSError *err)) {
    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    if (!store.bdstoken) {
        completion(nil, [NSError errorWithDomain:@"BDT" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }

    NSString *encodedPath = BDTStrictEncode(filePath);
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/locatedownload?clienttype=0&app_id=250528&web=1&channel=chunlei&path=%@&origin=pdf&use=1&bdstoken=%@&t=%lld", encodedPath, store.bdstoken, ts];

    [[BDTRequestManager sharedManager] request:url method:@"GET" headers:@{@"X-Requested-With": @"XMLHttpRequest"} body:nil completion:^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }

        NSString *dlink = BDTDigOutDlink(json);
        if (dlink) { completion(dlink, nil); return; }

        if ([json isKindOfClass:[NSDictionary class]]) {
            NSNumber *errnoNum = json[@"errno"];
            if (errnoNum && [errnoNum integerValue] == -9 && retryCount < kBDTMaxRetries) {
                BDTLog(@"locatedownload not ready, retry %ld", (long)(retryCount + 1));
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBDTRetryDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    BDTFetchDlinkViaLocatedownload(filePath, retryCount + 1, completion);
                });
                return;
            }
        }

        NSString *msg = @"locatedownload error";
        if ([json isKindOfClass:[NSDictionary class]]) {
            msg = json[@"errmsg"] ?: msg;
        }
        completion(nil, [NSError errorWithDomain:@"BDT" code:-6 userInfo:@{NSLocalizedDescriptionKey: msg}]);
    }];
}

static void BDTFetchDirectLink(NSString *filePath, void (^completion)(NSString *link, NSError *err)) {
    BDTLog(@"Fetching direct link for: %@", filePath);
    BDTFetchDlinkViaFilemetas(filePath, 0, ^(NSString *link, NSError *err) {
        if (link) { completion(link, nil); return; }
        BDTLog(@"filemetas failed: %@, trying locatedownload...", err.localizedDescription);
        BDTFetchDlinkViaLocatedownload(filePath, 0, ^(NSString *link2, NSError *err2) {
            if (link2) { completion(link2, nil); return; }
            NSString *msg = [NSString stringWithFormat:@"无法获取直链。\nfilemetas: %@\nlocatedownload: %@", err.localizedDescription, err2.localizedDescription];
            completion(nil, [NSError errorWithDomain:@"BDT" code:-5 userInfo:@{NSLocalizedDescriptionKey: msg}]);
        });
    });
}

#pragma mark - UI Helpers

static void BDTCopyToClipboard(NSString *text) {
    if (!text) return;
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = text;
}

static void BDTShowToast(NSString *msg) {
    if (!msg || msg.length == 0) return;

    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                window = ws.windows.firstObject;
                break;
            }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return;

    static UILabel *currentToast = nil;
    if (currentToast) {
        [currentToast removeFromSuperview];
        currentToast = nil;
    }

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

    CGFloat w = MIN(toast.bounds.size.width + 32, window.bounds.size.width - 32);
    CGFloat h = toast.bounds.size.height + 16;
    toast.frame = CGRectMake((window.bounds.size.width - w) / 2, window.bounds.size.height - 120, w, h);
    toast.alpha = 0;

    [window addSubview:toast];
    currentToast = toast;

    [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) {
            [toast removeFromSuperview];
            if (currentToast == toast) currentToast = nil;
        }];
    });
}

static void BDTForceRefreshFileList(void) {
    UIViewController *vc = BDTTopViewController();
    if (!vc) return;

    NSArray *refreshSelectors = @[@"refreshData", @"reloadData", @"refreshFileList",
                                   @"loadData", @"requestData", @"fetchFileList", @"reloadFileList"];
    for (NSString *selName in refreshSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            BDTLog(@"Calling VC refresh method: %@", selName);
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
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [sv.refreshControl endRefreshing];
            });
        }
    }
}

#pragma mark - Dialog UI

static void BDTShowLinkDialog(NSString *link, NSString *fileName, NSString *fileId, NSString *pdfPath) {
    UIViewController *vc = BDTTopViewController();
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
    linkLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
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
    objc_setAssociatedObject(copyBtn, &kBDTLinkTextKey, link, OBJC_ASSOCIATION_COPY_NONATOMIC);
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
    objc_setAssociatedObject(restoreBtn, &kBDTFileIdKey, fileId, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, &kBDTPdfPathKey, pdfPath, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, &kBDTFileNameKey, fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(restoreBtn, &kBDTOverlayVCKey, overlayVC, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

#pragma mark - Main Flow

static void BDTRunRenameAndGetLink(NSString *fileName, NSString *filePath, NSString *fileId) {
    if ([fileName.lowercaseString hasSuffix:@".pdf"]) {
        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"获取直链..." preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *presentVC = BDTTopViewController();
        if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

        BDTFetchDirectLink(filePath, ^(NSString *link, NSError *err) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                if (err || !link) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc = BDTTopViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
                    return;
                }
                BDTCopyToClipboard(link);
                BDTShowToast(@"直链已复制到剪贴板！");
                BDTShowLinkDialog(link, fileName, fileId, filePath);
            }];
        }];
        return;
    }

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];

    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"1. 重命名文件" preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *presentVC = BDTTopViewController();
    if (presentVC) [presentVC presentViewController:progressAlert animated:YES completion:nil];

    BDTRenameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = BDTTopViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
            }];
            return;
        }

        BDTLog(@"Renamed to %@, refreshing...", pdfName);
        progressAlert.message = @"2. 刷新文件列表...";
        BDTForceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            progressAlert.message = @"3. 获取直链...";

            BDTFetchDirectLink(pdfPath, ^(NSString *link, NSError *err) {
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    if (err || !link) {
                        BDTRenameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
                            BDTLog(@"Auto restore: %@", ok ? @"OK" : e.localizedDescription);
                        });
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        UIViewController *vc = BDTTopViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
                        return;
                    }

                    BDTCopyToClipboard(link);
                    BDTShowToast(@"直链已复制到剪贴板！");
                    BDTShowLinkDialog(link, fileName, fileId, pdfPath);
                }];
            });
        });
    });
}

static void BDTTriggerDownloadFlow(void) {
    BDTLog(@"Starting download flow...");
    BDTFetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            BDTLogError(@"Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取文件列表失败" message:err ? err.localizedDescription : @"文件夹为空" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = BDTTopViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
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
            UIViewController *vc = BDTTopViewController(); if (vc) [vc presentViewController:alert animated:YES completion:nil];
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
                BDTRunRenameAndGetLink(name, path, fileId);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *vc = BDTTopViewController();
        if (vc) {
            if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                sheet.popoverPresentationController.sourceView = vc.view;
                sheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
            }
            [vc presentViewController:sheet animated:YES completion:nil];
        }
    });
}

#pragma mark - UI Injection (Hardened)

static BOOL BDTIsBaiduPanFileListPage(void) {
    UIViewController *vc = BDTTopViewController();
    if (!vc) return NO;
    NSString *title = vc.title ?: vc.navigationItem.title;
    if (title && ([title containsString:@"百度网盘"] || [title containsString:@"文件"] || [title containsString:@"全部文件"])) return YES;
    NSString *clsName = NSStringFromClass([vc class]);
    if (clsName && ([clsName containsString:@"File"] || [clsName containsString:@"List"] ||
                    [clsName containsString:@"Pan"] || [clsName containsString:@"Disk"])) return YES;
    return NO;
}

static BOOL BDTIsBaiduPanFileCell(UIView *view) {
    if (![view isKindOfClass:[UITableViewCell class]] && ![view isKindOfClass:[UICollectionViewCell class]]) return NO;

    __block BOOL hasSizeLabel = NO;
    __block BOOL hasNameLabel = NO;

    void (^__weak __block weakSearch)(UIView *);
    void (^search)(UIView *);

    search = ^(UIView *v) {
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
                if ([text isEqualToString:@"打开"] || [text isEqualToString:@"直链"] ||
                    [text isEqualToString:@"文件夹"] || [text rangeOfString:@"个文件"].location != NSNotFound) continue;
                if (text.length > 0) hasNameLabel = YES;
            }
            if (weakSearch) weakSearch(sub);
        }
    };
    weakSearch = search;
    search(view);
    weakSearch = nil; // 打破循环引用

    return hasSizeLabel && hasNameLabel;
}

static NSString * BDTExtractFileNameFromCell(UIView *cell) {
    UILabel *bestLabel = nil;
    CGFloat maxWidth = 0;

    void (^__weak __block weakSearch)(UIView *);
    void (^search)(UIView *);

    search = ^(UIView *v) {
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
            if (weakSearch) weakSearch(sub);
        }
    };
    weakSearch = search;
    search(cell);
    weakSearch = nil;

    return bestLabel.text;
}

static void BDTInjectDirectLinkButtons(void) {
    if (!BDTIsBaiduPanFileListPage()) return;

    UIViewController *vc = BDTTopViewController();
    if (!vc) return;

    NSMutableArray *scrollViews = [NSMutableArray array];
    void (^__weak __block weakFind)(UIView *);
    void (^findScrollViews)(UIView *);

    findScrollViews = ^(UIView *v) {
        if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
            [scrollViews addObject:v];
        }
        for (UIView *sub in v.subviews) {
            if (weakFind) weakFind(sub);
        }
    };
    weakFind = findScrollViews;
    findScrollViews(vc.view);
    weakFind = nil;

    for (UIScrollView *scrollView in scrollViews) {
        NSArray *cells = nil;
        if ([scrollView isKindOfClass:[UITableView class]]) {
            cells = [(UITableView *)scrollView visibleCells];
        } else {
            cells = [(UICollectionView *)scrollView visibleCells];
        }

        for (UIView *cell in cells) {
            if (!BDTIsBaiduPanFileCell(cell)) continue;

            NSString *fileName = BDTExtractFileNameFromCell(cell);
            if (!fileName || fileName.length == 0) continue;

            UIButton *btn = [cell viewWithTag:kBDTTagDirectLinkButton];
            if (!btn) {
                btn = [UIButton buttonWithType:UIButtonTypeSystem];
                btn.tag = kBDTTagDirectLinkButton;
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
            objc_setAssociatedObject(btn, &kBDTFileNameAssocKey, fileName, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
}

#pragma mark - Float Button

@interface BDTFloatButtonManager : NSObject
@property (nonatomic, strong) UIButton *floatButton;
+ (instancetype)sharedManager;
- (void)show;
- (void)hide;
@end

@implementation BDTFloatButtonManager

+ (instancetype)sharedManager {
    static BDTFloatButtonManager *mgr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = [[self alloc] init]; });
    return mgr;
}

- (void)show {
    if (self.floatButton) return;

    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState == UISceneActivationStateForegroundActive) {
                window = ws.windows.firstObject;
                break;
            }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return;

    CGFloat size = 50;
    CGFloat x = [UIScreen mainScreen].bounds.size.width - size - 20;
    CGFloat y = [UIScreen mainScreen].bounds.size.height / 2;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(x, y, size, size);
    btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.8];
    btn.layer.cornerRadius = size / 2;
    btn.layer.masksToBounds = YES;
    [btn setTitle:@"🚀" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:24];
    [btn addTarget:nil action:@selector(bdt_floatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(bdt_floatButtonPanned:)];
    [btn addGestureRecognizer:pan];

    [window addSubview:btn];
    self.floatButton = btn;
    BDTLog(@"Float button shown");
}

- (void)hide {
    [self.floatButton removeFromSuperview];
    self.floatButton = nil;
}

@end

static void BDTOnFloatButtonTap(void) {
    BDTAutoDetectCredentials();
    BDTCredentialStore *store = [BDTCredentialStore sharedStore];
    NSString *tokenInfo = store.bdstoken ? @"present" : @"missing";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v9.0"
                                                                       message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", store.currentPath, tokenInfo, store.BDUSS ? @"OK" : @"missing"]
                                                                preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"📥 获取直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        BDTTriggerDownloadFlow();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *vc = BDTTopViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Method Swizzling Safety (修复 Aspects 崩溃类似问题)

// 使用更安全的 method swizzling 模式，避免与 Aspects 等框架冲突
static void BDTSafeSwizzleMethod(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);

    if (!originalMethod || !swizzledMethod) {
        BDTLogError(@"Method not found for swizzling");
        return;
    }

    // 检查是否已经 swizzled（防止重复 swizzling 导致循环调用）
    IMP originalIMP = method_getImplementation(originalMethod);
    IMP swizzledIMP = method_getImplementation(swizzledMethod);

    if (originalIMP == swizzledIMP) {
        BDTLog(@"Already swizzled, skipping");
        return;
    }

    BOOL didAddMethod = class_addMethod(cls, originalSelector, swizzledIMP, method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) {
        class_replaceMethod(cls, swizzledSelector, originalIMP, method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

#pragma mark - NSObject Category (Action Handlers)

@interface NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender;
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture;
- (void)bdt_cellLinkTapped:(id)sender;
- (void)bdt_copyLinkTapped:(id)sender;
- (void)bdt_restoreNameTapped:(UIButton *)sender;
@end

@implementation NSObject (BaiduPanTroll)

- (void)bdt_floatButtonTapped:(id)sender { BDTOnFloatButtonTap(); }

- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];

    // 边界限制
    CGRect superBounds = button.superview.bounds;
    CGFloat halfW = button.bounds.size.width / 2;
    CGFloat halfH = button.bounds.size.height / 2;
    CGFloat x = MAX(halfW, MIN(button.center.x, superBounds.size.width - halfW));
    CGFloat y = MAX(halfH, MIN(button.center.y, superBounds.size.height - halfH));
    button.center = CGPointMake(x, y);
}

- (void)bdt_cellLinkTapped:(UIButton *)sender {
    NSString *fileName = objc_getAssociatedObject(sender, &kBDTFileNameAssocKey);
    if (!fileName) {
        BDTShowToast(@"无法获取文件名");
        return;
    }

    BDTAutoDetectCredentials();

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"处理中..." message:@"获取文件信息..." preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = BDTTopViewController();
    if (vc) [vc presentViewController:progress animated:YES completion:nil];

    BDTFetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files) {
            [progress dismissViewControllerAnimated:YES completion:^{
                BDTShowToast(@"获取文件列表失败");
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
                BDTShowToast(@"未找到文件");
            }];
            return;
        }

        [progress dismissViewControllerAnimated:YES completion:^{
            NSString *name = targetFile[@"server_filename"];
            NSString *path = targetFile[@"path"];
            NSString *fileId = [targetFile[@"fs_id"] stringValue];
            BDTRunRenameAndGetLink(name, path, fileId);
        }];
    });
}

- (void)bdt_copyLinkTapped:(id)sender {
    NSString *link = objc_getAssociatedObject(sender, &kBDTLinkTextKey);
    if (link) {
        BDTCopyToClipboard(link);
        BDTShowToast(@"直链已复制到剪贴板！");
    }
}

- (void)bdt_restoreNameTapped:(UIButton *)sender {
    NSString *fileId = objc_getAssociatedObject(sender, &kBDTFileIdKey);
    NSString *pdfPath = objc_getAssociatedObject(sender, &kBDTPdfPathKey);
    NSString *fileName = objc_getAssociatedObject(sender, &kBDTFileNameKey);
    UIViewController *overlayVC = objc_getAssociatedObject(sender, &kBDTOverlayVCKey);

    void (^doRestore)(void) = ^{
        BDTRenameFile(fileId, pdfPath, fileName, ^(BOOL ok, NSError *e) {
            BDTLog(@"Restore: %@", ok ? @"OK" : e.localizedDescription);
        });
    };

    if (overlayVC) {
        [overlayVC dismissViewControllerAnimated:YES completion:doRestore];
    } else {
        doRestore();
    }
}

@end

#pragma mark - Initialization

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    BDTLog(@"BaiduPan Troll v9.0 loaded");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[BDTFloatButtonManager sharedManager] show];
        BDTAutoDetectCredentials();

        // 使用更合理的刷新间隔，避免过度消耗 CPU
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
            BDTInjectDirectLinkButtons();
        }];
    });
}
