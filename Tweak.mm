//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v6.3
//  Fix: Build error info[0][@"dlink"] on NSDictionary
//  Feature: Auto-detect path & token, trigger client download flow
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

static const NSInteger kLargeFileThreshold = 30 * 1024 * 1024;      // 30MB
static const NSInteger kWaitTimeAfterRename = 4000;                  // 4s
static const NSInteger kLargeFileExtraWait = 10000;                  // 10s
static const NSInteger kDlinkRetryCount = 3;
static const NSInteger kAutoDetectRetryCount = 5;

// ========== 全局状态 ==========
static NSString *gManualToken = nil;          // 手动设置的 token
static NSString *gCurrentPath = nil;          // 当前路径
static BOOL gPathAutoDetected = NO;
static NSString *gBdstoken = nil;             // 自动获取的 bdstoken
static NSString *gBDUSS = nil;                // BDUSS
static NSString *gCuid = nil;                 // cuid
static NSString *gAppUID = nil;               // app uid
static NSMutableDictionary *gInterceptedDlinks = nil;  // 拦截到的直链
static BOOL gIsIntercepting = NO;             // 是否正在拦截

// ========== 前向声明 ==========
static UIViewController * topViewController(void);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static NSString * getBdstoken(void);
static NSString * getBDUSS(void);
static NSString * getCuid(void);
static NSString * getAppUID(void);
static NSString * getCurrentPath(void);
static void autoDetectPathAndToken(void);
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
static void simulateTapFileNamed(NSString *fileName);
static void triggerClientDownload(NSString *fileId, NSString *path, NSString *fileName);
static void hookNetworkRequests(void);
static NSString * generateRandomSuffix(void);

// ========== 工具函数 ==========

static NSString * generateRandomSuffix(void) {
    NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
    NSInteger random = arc4random_uniform(10000);
    return [NSString stringWithFormat:@"_%.0f_%ld", ts * 1000, (long)random];
}

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
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

    // 处理导航控制器
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

// ========== 自动获取 Token ==========

static NSString * getBdstoken(void) {
    if (gBdstoken) return gBdstoken;

    // 方法1: 从 NSUserDefaults 获取
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBdstoken = [defaults objectForKey:@"bdstoken"];
    if (gBdstoken) {
        DLog(@"✅ Got bdstoken from NSUserDefaults");
        return gBdstoken;
    }

    // 方法2: 从 Keychain 获取
    NSArray *keychainKeys = @[
        @"com.baidu.netdisk.bdstoken",
        @"bdstoken",
        @"BDWallet_User_Id",
        @"token"
    ];

    for (NSString *key in keychainKeys) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: key,
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
        };
        CFDataRef dataRef = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataRef);
        if (status == errSecSuccess && dataRef) {
            NSData *data = (__bridge_transfer NSData *)dataRef;
            NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (value && value.length > 0) {
                gBdstoken = value;
                DLog(@"✅ Got bdstoken from Keychain key: %@", key);
                return gBdstoken;
            }
        }
    }

    // 方法3: 使用手动设置的 token
    if (gManualToken) {
        gBdstoken = gManualToken;
        DLog(@"⚠️ Using manual token");
        return gBdstoken;
    }

    return nil;
}

static NSString * getBDUSS(void) {
    if (gBDUSS) return gBDUSS;

    // 从 Cookie 获取
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) {
            gBDUSS = cookie.value;
            DLog(@"✅ Got BDUSS from cookie");
            return gBDUSS;
        }
    }

    // 从 NSUserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gBDUSS = [defaults objectForKey:@"BDUSS"];
    if (gBDUSS) {
        DLog(@"✅ Got BDUSS from NSUserDefaults");
        return gBDUSS;
    }

    return nil;
}

static NSString * getCuid(void) {
    if (gCuid) return gCuid;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gCuid = [defaults objectForKey:@"cuid"];
    if (!gCuid) {
        gCuid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    }
    return gCuid;
}

static NSString * getAppUID(void) {
    if (gAppUID) return gAppUID;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gAppUID = [defaults objectForKey:@"uid"];
    if (!gAppUID) {
        gAppUID = [defaults objectForKey:@"app_uid"];
    }
    return gAppUID;
}

// ========== 自动获取当前路径 ==========

static NSString * extractPathFromViewController(UIViewController *vc) {
    if (!vc) return nil;

    NSString *path = nil;
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir", @"_path"];
    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                path = value;
                DLog(@"✅ Found path from VC.%@ = %@", key, path);
                break;
            }
        } @catch (NSException *e) {}
    }

    return path;
}

static NSString * getPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

    if (nav) {
        NSArray *vcs = nav.viewControllers;
        NSMutableArray *pathComponents = [NSMutableArray array];

        for (UIViewController *controller in vcs) {
            NSString *component = extractPathFromViewController(controller);
            if (component && ![component isEqualToString:@"/"] && component.length > 0) {
                [pathComponents addObject:component];
            }
        }

        if (pathComponents.count > 0) {
            NSString *fullPath = [pathComponents componentsJoinedByString:@"/"];
            if (![fullPath hasPrefix:@"/"]) {
                fullPath = [@"/" stringByAppendingString:fullPath];
            }
            return fullPath;
        }
    }

    return extractPathFromViewController(vc);
}

static NSString * extractPathFromURL(NSString *urlString) {
    if (!urlString) return nil;

    NSURL *url = [NSURL URLWithString:urlString];
    NSString *path = url.path;

    NSString *fragment = url.fragment;
    if (fragment) {
        NSRange pathRange = [fragment rangeOfString:@"path="];
        if (pathRange.location != NSNotFound) {
            NSString *pathParam = [fragment substringFromIndex:pathRange.location + 5];
            NSRange endRange = [pathParam rangeOfString:@"&"];
            if (endRange.location != NSNotFound) {
                pathParam = [pathParam substringToIndex:endRange.location];
            }
            pathParam = [pathParam stringByRemovingPercentEncoding];
            if (pathParam && pathParam.length > 0) {
                return pathParam;
            }
        }
    }

    return path;
}

static void autoDetectPathAndToken(void) {
    DLog(@"🔍 Starting auto-detection...");

    NSString *bdstoken = getBdstoken();
    NSString *bduss = getBDUSS();
    NSString *cuid = getCuid();

    DLog(@"bdstoken: %@", bdstoken ? @"✅ Found" : @"❌ Not found");
    DLog(@"BDUSS: %@", bduss ? @"✅ Found" : @"❌ Not found");
    DLog(@"cuid: %@", cuid ? @"✅ Found" : @"❌ Not found");

    NSString *path = getPathFromNavStack();
    if (!path) {
        UIViewController *vc = topViewController();
        path = extractPathFromViewController(vc);
    }

    if (path) {
        gCurrentPath = path;
        gPathAutoDetected = YES;
        DLog(@"✅ Auto-detected path: %@", path);
    } else {
        DLog(@"⚠️ Could not auto-detect path, using default: /");
        gCurrentPath = @"/";
    }
}

static NSString * getCurrentPath(void) {
    if (!gCurrentPath) {
        autoDetectPathAndToken();
    }
    return gCurrentPath ?: @"/";
}

// ========== 网络请求工具 ==========

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

    NSString *bduss = getBDUSS();
    if (bduss) {
        allHeaders[@"Cookie"] = [NSString stringWithFormat:@"BDUSS=%@", bduss];
    }

    if (headers) [allHeaders addEntriesFromDictionary:headers];
    req.allHTTPHeaderFields = allHeaders;

    if (body) req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                handler(nil, error);
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            handler(json, nil);
        });
    }];
    [task resume];
}

static NSString * strictEncodeURIComponent(NSString *str) {
    if (!str) return @"";
    NSMutableCharacterSet *cs = [NSMutableCharacterSet alphanumericCharacterSet];
    [cs addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:cs];
}

// ========== 文件列表获取 ==========

static void fetchFileList(NSString *path, void (^completion)(NSArray *files, NSError *err)) {
    NSString *encodedPath = strictEncodeURIComponent(path ?: @"/");
    NSString *bdstoken = getBdstoken();

    if (!bdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken available"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:
        @"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100",
        encodedPath, bdstoken];

    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            completion(nil, err);
            return;
        }

        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format"}]);
            return;
        }

        completion(list, nil);
    });
}

// ========== 直链获取（多种方式） ==========

static NSString * digOutDlink(id obj) {
    if (!obj) return nil;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *str = obj;
        if ([str hasPrefix:@"http"] && ([str containsString:@".baidupcs.com"] || [str containsString:@".bdstatic.com"])) {
            return str;
        }
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = obj;
        NSString *dlink = dict[@"dlink"];
        if (dlink) return dlink;

        NSArray *urls = dict[@"urls"];
        if ([urls isKindOfClass:[NSArray class]] && urls.count > 0) {
            for (id urlObj in urls) {
                NSString *found = digOutDlink(urlObj);
                if (found) return found;
            }
        }

        for (id key in dict) {
            NSString *found = digOutDlink(dict[key]);
            if (found) return found;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in obj) {
            NSString *found = digOutDlink(item);
            if (found) return found;
        }
    }

    return nil;
}

static void fetchDlinkViaFilemetas(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }

    fetchFileList(gCurrentPath, ^(NSArray *files, NSError *err) {
        if (err) {
            if (retry > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    fetchDlinkViaFilemetas(filePath, retry - 1, completion);
                });
            } else {
                completion(nil, err);
            }
            return;
        }

        NSNumber *targetFsId = nil;
        NSString *fileName = [filePath lastPathComponent];
        for (NSDictionary *file in files) {
            if ([file[@"server_filename"] isEqualToString:fileName] || 
                [file[@"path"] isEqualToString:filePath]) {
                targetFsId = file[@"fs_id"];
                break;
            }
        }

        if (!targetFsId) {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"File not found in list"}]);
            return;
        }

        NSString *fsids = [NSString stringWithFormat:@"[%@]", targetFsId];
        NSString *encodedFsids = strictEncodeURIComponent(fsids);
        NSString *url = [NSString stringWithFormat:
            @"https://pan.baidu.com/api/filemetas?dlink=1&fsids=%@&bdstoken=%@",
            encodedFsids, bdstoken];

        bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
            if (err) {
                completion(nil, err);
                return;
            }

            // FIX: 修复编译错误 - info 可能是字典或数组
            id info = json[@"info"];
            NSString *dlink = nil;

            if ([info isKindOfClass:[NSArray class]]) {
                NSArray *infoArray = (NSArray *)info;
                if (infoArray.count > 0) {
                    NSDictionary *firstItem = infoArray[0];
                    if ([firstItem isKindOfClass:[NSDictionary class]]) {
                        dlink = firstItem[@"dlink"];
                    }
                }
            } else if ([info isKindOfClass:[NSDictionary class]]) {
                dlink = info[@"dlink"];
            }

            if (dlink) {
                completion(dlink, nil);
                return;
            }

            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"No dlink in response"}]);
        });
    });
}

static void fetchDlinkViaLocateDownload(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *bdstoken = getBdstoken();
    NSString *encodedPath = strictEncodeURIComponent(filePath);

    NSString *url = [NSString stringWithFormat:
        @"https://pan.baidu.com/api/locateDownload?path=%@&bdstoken=%@&app_id=250528",
        encodedPath, bdstoken];

    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            if (retry > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    fetchDlinkViaLocateDownload(filePath, retry - 1, completion);
                });
            } else {
                completion(nil, err);
            }
            return;
        }

        NSString *dlink = digOutDlink(json);
        if (dlink) {
            completion(dlink, nil);
        } else {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"No dlink from locateDownload"}]);
        }
    });
}

static void fetchDlinkPortal(NSString *filePath, void (^completion)(NSString *dlink, NSError *err)) {
    fetchDlinkViaFilemetas(filePath, kDlinkRetryCount, ^(NSString *dlink, NSError *err) {
        if (dlink) {
            completion(dlink, nil);
        } else {
            DLog(@"⚠️ filemetas failed, trying locateDownload...");
            fetchDlinkViaLocateDownload(filePath, kDlinkRetryCount, completion);
        }
    });
}

// ========== 文件操作 ==========

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@", bdstoken];

    NSString *body = [NSString stringWithFormat:@"filelist=[{\"path\":\"%@\",\"newname\":\"%@\"}]", 
                      path, newName];

    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded",
        @"X-Requested-With": @"XMLHttpRequest"
    };

    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) {
            completion(NO, err);
            return;
        }

        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"errmsg"] ?: @"Unknown error";
            completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static void refreshFileMeta(NSString *filePath, void (^completion)(void)) {
    DLog(@"🔄 Refreshing file meta...");
    completion();
}

static void refreshFileListCache(NSString *path, void (^completion)(void)) {
    DLog(@"🔄 Refreshing file list cache...");
    fetchFileList(path, ^(NSArray *files, NSError *err) {
        completion();
    });
}

// ========== 模拟点击触发客户端下载 ==========

static void simulateTapFileNamed(NSString *fileName) {
    DLog(@"👆 Simulating tap on file: %@", fileName);

    UIViewController *vc = topViewController();
    if (!vc) {
        DLog(@"❌ No top view controller found");
        return;
    }

    __block UIScrollView *targetScrollView = nil;

    __block void (^findScrollView)(UIView *) = ^(UIView *view) {
        if (targetScrollView) return;

        if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
            targetScrollView = (UIScrollView *)view;
            return;
        }

        for (UIView *subview in view.subviews) {
            findScrollView(subview);
        }
    };

    findScrollView(vc.view);

    if (!targetScrollView) {
        DLog(@"❌ No UITableView/UICollectionView found");
        return;
    }

    DLog(@"✅ Found scroll view: %@", NSStringFromClass([targetScrollView class]));

    __block UIView *targetCell = nil;
    __block NSIndexPath *targetIndexPath = nil;

    if ([targetScrollView isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)targetScrollView;

        for (NSIndexPath *indexPath in [tableView indexPathsForVisibleRows]) {
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];

            BOOL found = NO;
            for (UIView *subview in cell.contentView.subviews) {
                if ([subview isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)subview;
                    if ([label.text containsString:fileName]) {
                        found = YES;
                        break;
                    }
                }
            }

            if (found) {
                targetCell = cell;
                targetIndexPath = indexPath;
                break;
            }
        }

        if (targetCell && targetIndexPath) {
            DLog(@"✅ Found cell at indexPath: %@", targetIndexPath);

            dispatch_async(dispatch_get_main_queue(), ^{
                [tableView.delegate tableView:tableView didSelectRowAtIndexPath:targetIndexPath];
                [tableView selectRowAtIndexPath:targetIndexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
            });
        } else {
            DLog(@"⚠️ Cell not found, may need to scroll");
        }
    } else if ([targetScrollView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collectionView = (UICollectionView *)targetScrollView;

        for (NSIndexPath *indexPath in [collectionView indexPathsForVisibleItems]) {
            UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];

            BOOL found = NO;
            for (UIView *subview in cell.contentView.subviews) {
                if ([subview isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)subview;
                    if ([label.text containsString:fileName]) {
                        found = YES;
                        break;
                    }
                }
            }

            if (found) {
                targetCell = cell;
                targetIndexPath = indexPath;
                break;
            }
        }

        if (targetCell && targetIndexPath) {
            DLog(@"✅ Found collection cell at indexPath: %@", targetIndexPath);
            dispatch_async(dispatch_get_main_queue(), ^{
                [collectionView.delegate collectionView:collectionView didSelectItemAtIndexPath:targetIndexPath];
            });
        }
    }
}

// ========== 触发客户端下载流程 ==========

static void triggerClientDownload(NSString *fileId, NSString *path, NSString *fileName) {
    DLog(@"🚀 Triggering client download flow for: %@", fileName);

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    NSString *originalPath = path;
    NSString *pdfPath = [path stringByAppendingString:@".pdf"];

    if ([path hasSuffix:fileName]) {
        originalPath = path;
        pdfPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];
    }

    DLog(@"📝 Renaming to: %@", pdfName);

    renameFile(fileId, originalPath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            DLog(@"❌ Rename failed: %@", err.localizedDescription);
            return;
        }

        DLog(@"✅ Renamed successfully, waiting for download trigger...");

        NSInteger waitTime = kWaitTimeAfterRename;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitTime * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{

            refreshFileListCache(gCurrentPath, ^{
                simulateTapFileNamed(pdfName);

                NSInteger restoreDelay = waitTime + 2000;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(restoreDelay * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{

                    DLog(@"🔄 Restoring original name...");
                    renameFile(fileId, pdfPath, fileName, ^(BOOL success, NSError *err) {
                        if (success) {
                            DLog(@"✅ Name restored");
                        } else {
                            DLog(@"⚠️ Failed to restore name: %@", err.localizedDescription);
                        }
                    });
                });
            });
        });
    });
}

// ========== 主流程 ==========

static void runPipeline(NSString *fileName, NSString *fileId, NSString *currentPath, NSInteger fileSize) {
    DLog(@"🎯 Starting pipeline for: %@ (size: %ld)", fileName, (long)fileSize);

    if (!gPathAutoDetected || !gBdstoken) {
        autoDetectPathAndToken();
    }

    NSString *path = currentPath ?: gCurrentPath;
    if (!path) {
        DLog(@"❌ No path available");
        return;
    }

    NSString *fullPath = path;
    if (![path hasSuffix:fileName]) {
        fullPath = [path stringByAppendingPathComponent:fileName];
    }

    NSInteger extraWait = (fileSize > kLargeFileThreshold) ? kLargeFileExtraWait : 0;

    fetchDlinkPortal(fullPath, ^(NSString *dlink, NSError *err) {
        if (dlink) {
            DLog(@"✅ Got direct link via API: %@", dlink);
            UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
            pasteboard.string = dlink;
            DLog(@"📋 Link copied to clipboard!");
            return;
        }

        DLog(@"⚠️ API method failed: %@", err.localizedDescription);
        DLog(@"🔄 Falling back to client download flow...");

        triggerClientDownload(fileId, fullPath, fileName);
    });
}

// ========== 网络请求 Hook ==========

@interface NSURLSession (BaiduPanTroll)
- (NSURLSessionDataTask *)bdt_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler;
@end

@implementation NSURLSession (BaiduPanTroll)

- (NSURLSessionDataTask *)bdt_dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {

    NSString *urlString = request.URL.absoluteString;

    if ([urlString containsString:@"pan.baidu.com"] || [urlString containsString:@".baidupcs.com"]) {

        void (^interceptedHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {

            if (completionHandler) {
                completionHandler(data, response, error);
            }

            if (data) {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *dlink = digOutDlink(json);

                if (dlink && gIsIntercepting) {
                    DLog(@"🔥 Intercepted dlink: %@", dlink);
                    [gInterceptedDlinks setObject:dlink forKey:urlString];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
                        pasteboard.string = dlink;
                    });
                }
            }
        };

        return [self bdt_dataTaskWithRequest:request completionHandler:interceptedHandler];
    }

    return [self bdt_dataTaskWithRequest:request completionHandler:completionHandler];
}

@end

static void hookNetworkRequests(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gInterceptedDlinks = [NSMutableDictionary dictionary];

        Class cls = [NSURLSession class];
        SEL originalSelector = @selector(dataTaskWithRequest:completionHandler:);
        SEL swizzledSelector = @selector(bdt_dataTaskWithRequest:completionHandler:);

        Method originalMethod = class_getInstanceMethod(cls, originalSelector);
        Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);

        BOOL didAddMethod = class_addMethod(cls, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod));

        if (didAddMethod) {
            class_replaceMethod(cls, swizzledSelector, method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod));
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod);
        }

        DLog(@"✅ Network hook installed");
    });
}

// ========== 初始化 ==========

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"🚀 BaiduPan SVIP Direct Link Helper v6.3 loaded");
    DLog(@"📱 Device: %@", [[UIDevice currentDevice] model]);

    gInterceptedDlinks = [NSMutableDictionary dictionary];

    hookNetworkRequests();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        autoDetectPathAndToken();
    });

    DLog(@"✅ Initialization complete");
}

// ========== 对外接口 ==========

void BDTSetManualToken(NSString *token) {
    gManualToken = token;
    gBdstoken = token;
    DLog(@"📝 Manual token set");
}

void BDTSetCurrentPath(NSString *path) {
    gCurrentPath = path;
    gPathAutoDetected = YES;
    DLog(@"📝 Manual path set: %@", path);
}

void BDTFetchDirectLink(NSString *fileName, NSString *fileId, NSInteger fileSize) {
    gIsIntercepting = YES;
    runPipeline(fileName, fileId, gCurrentPath, fileSize);
}

NSString * BDTGetInterceptedLink(NSString *key) {
    return gInterceptedDlinks[key];
}

void BDTTriggerClientDownload(NSString *fileName, NSString *fileId) {
    triggerClientDownload(fileId, [gCurrentPath stringByAppendingPathComponent:fileName], fileName);
}
