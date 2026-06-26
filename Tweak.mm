//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v4.6
//  Fix: add Cookie from NSHTTPCookieStorage + strict path encoding
//  Reference: working Tampermonkey script v3.5.0
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

static const NSInteger kLargeFileThreshold = 30 * 1024 * 1024;
static const NSInteger kWaitTimeAfterRename = 4000;
static const NSInteger kLargeFileExtraWait = 10000;
static const NSInteger kDlinkRetryCount = 3;

static NSString *gManualToken = nil;
static NSString *gCurrentPath = nil;

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

// ========== 【修改】bdAsyncRequest: 添加 Cookie 和 User-Agent ==========
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 20;

    // 模拟浏览器请求头
    [req setValue:@"https://pan.baidu.com/disk/main" forHTTPHeaderField:@"Referer"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
    [req setValue:@"application/json, text/javascript, */*; q=0.01" forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];

    // 尝试从 CookieStorage 获取百度网盘的 Cookie
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [cookieStorage cookiesForURL:[NSURL URLWithString:@"https://pan.baidu.com"]];
    if (cookies.count > 0) {
        NSMutableArray *cookieStrings = [NSMutableArray array];
        for (NSHTTPCookie *cookie in cookies) {
            [cookieStrings addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
        }
        NSString *cookieHeader = [cookieStrings componentsJoinedByString:@"; "];
        [req setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        DLog(@"Cookie added: %lu cookies", (unsigned long)cookies.count);
    } else {
        DLog(@"No cookies found for pan.baidu.com");
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

static NSString * getBdstoken(void) {
    if (gManualToken && gManualToken.length > 0) {
        return gManualToken;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:@"bdstoken"];
    if (token.length > 0) return token;
    return nil;
}

static NSString * getCurrentPath(void) {
    if (gCurrentPath && gCurrentPath.length > 0) {
        return gCurrentPath;
    }
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *path = [defaults stringForKey:@"currentPath"];
    if (path.length > 0) return path;
    return @"/";
}

static void showAlert(NSString *title, NSString *msg) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    if ([msg hasPrefix:@"http"]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIPasteboard generalPasteboard] setString:msg];
        }]];
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

static NSString * extractPathFromViewController(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *pathKeys = @[
        @"currentPath", @"path", @"dirPath", @"currentDir", 
        @"m_path", @"_currentPath", @"_path", @"directoryPath",
        @"currentDirectoryPath", @"m_directoryPath", @"folderPath",
        @"currentFolderPath", @"m_currentPath"
    ];
    for (NSString *key in pathKeys) {
        @try {
            id val = [vc valueForKey:key];
            if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                DLog(@"Path from VC(%@) [%@]: %@", NSStringFromClass([vc class]), key, val);
                return val;
            }
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

// ========== 【修改】严格编码 path 参数，模拟 JS encodeURIComponent ==========
static NSString * strictEncodeURIComponent(NSString *str) {
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_.!~*'()"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static void fetchFileList(NSString *path, void (^completion)(NSArray *files, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No bdstoken"}]);
        return;
    }
    NSString *encPath = strictEncodeURIComponent(path);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dir=%@&order=time&desc=1&showempty=0&page=1&num=100&t=%ld",
                     token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"Fetch list: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            NSArray *list = json[@"list"] ?: @[];
            completion(list, nil);
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
    if (![normalizedPath hasPrefix:@"/"]) {
        normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    }
    // 确保路径末尾没有 /
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) {
        normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    }
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%ld",
                     token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
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
        DLog(@"filemetas response: errno=%ld, json=%@", (long)errnoVal, json);
        if (errnoVal == 0) {
            NSArray *info = json[@"info"] ?: json[@"list"];
            if ([info count] > 0) {
                NSString *dlink = info[0][@"dlink"];
                if (dlink.length > 0) { completion(dlink, nil); return; }
            }
            NSString *dlink = digOutDlink(json);
            if (dlink) { completion(dlink, nil); return; }
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No dlink in response"}]);
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
    if (![normalizedPath hasPrefix:@"/"]) {
        normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    }
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) {
        normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    }
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/locatedownload?clienttype=0&app_id=250528&web=1&channel=chunlei&path=%@&origin=pdf&use=1&bdstoken=%@",
                     encPath, token];
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
        if (dlink) {
            completion(dlink, nil);
            return;
        }
        DLog(@"filemetas failed: %@, trying locatedownload...", err.localizedDescription);
        fetchDlinkViaLocateDownload(filePath, 0, ^(NSString *dlink2, NSError *err2) {
            if (dlink2) {
                completion(dlink2, nil);
                return;
            }
            NSString *combinedMsg = [NSString stringWithFormat:@"filemetas: %@\nlocatedownload: %@", err.localizedDescription, err2.localizedDescription];
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: combinedMsg}]);
        });
    });
}

static void refreshFileMeta(NSString *filePath, void (^completion)(void)) {
    NSString *token = getBdstoken();
    if (!token) {
        if (completion) completion();
        return;
    }
    NSString *normalizedPath = filePath;
    if (![normalizedPath hasPrefix:@"/"]) {
        normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    }
    if ([normalizedPath length] > 1 && [normalizedPath hasSuffix:@"/"]) {
        normalizedPath = [normalizedPath substringToIndex:[normalizedPath length] - 1];
    }
    NSString *encPath = strictEncodeURIComponent(normalizedPath);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%ld",
                     token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"Refresh meta: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        DLog(@"Refresh meta result: errno=%@, err=%@", json[@"errno"], err);
        if (completion) completion();
    });
}

static void refreshFileListCache(NSString *path, void (^completion)(void)) {
    NSString *token = getBdstoken();
    if (!token) {
        if (completion) completion();
        return;
    }
    NSString *encPath = strictEncodeURIComponent(path);
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&clienttype=0&app_id=250528&web=1&channel=chunlei&desc=1&showempty=0&page=1&num=10&order=time&t=%ld",
                     encPath, token, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"Refresh list: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        DLog(@"Refresh list result: errno=%@, err=%@", json[@"errno"], err);
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

static void runPipeline(NSString *fileName, NSString *fileId, NSString *currentPath, NSInteger fileSize) {
    NSString *originalName = fileName;
    void (^finish)(NSString *, NSError *) = ^(NSString *dlink, NSError *err) {
        if (dlink) {
            [[UIPasteboard generalPasteboard] setString:dlink];
            showAlert(@"Link Copied", dlink);
        } else {
            showAlert(@"Failed", err.localizedDescription);
        }
    };
    NSString *fullPath;
    if ([currentPath isEqualToString:@"/"]) {
        fullPath = [NSString stringWithFormat:@"/%@", originalName];
    } else {
        fullPath = [NSString stringWithFormat:@"%@/%@", currentPath, originalName];
    }
    DLog(@"Final path: %@", fullPath);
    if (![originalName hasSuffix:@".pdf"]) {
        NSString *renamedName = [originalName stringByAppendingString:@".pdf"];
        DLog(@"Rename: %@ -> %@", fullPath, renamedName);
        renameFile(fileId, fullPath, renamedName, ^(BOOL success, NSError *err) {
            if (!success) {
                showAlert(@"Rename Failed", err.localizedDescription);
                return;
            }
            NSString *renamedPath = [currentPath isEqualToString:@"/"] ? [NSString stringWithFormat:@"/%@", renamedName] : [NSString stringWithFormat:@"%@/%@", currentPath, renamedName];

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWaitTimeAfterRename * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{

                void (^doFetch)(void) = ^{
                    fetchDlinkPortal(renamedPath, ^(NSString *dlink, NSError *err) {
                        renameFile(fileId, renamedPath, originalName, ^(BOOL s, NSError *e) {
                            if (!s) DLog(@"Restore name failed: %@", e.localizedDescription);
                            finish(dlink, err);
                        });
                    });
                };

                if (fileSize > kLargeFileThreshold) {
                    DLog(@"Large file (%ld MB), refresh cache + extra wait", (long)(fileSize/1024/1024));
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
    } else {
        fetchDlinkPortal(fullPath, finish);
    }
}

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
    UIAlertController *input = [UIAlertController alertControllerWithTitle:@"Direct Link" message:@"Enter filename and bdstoken" preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Filename, e.g. example.zip";
    }];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken (from pan.baidu.com)";
        tf.text = gManualToken ?: @"";
    }];
    [input addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *fileName = input.textFields[0].text;
        NSString *token = input.textFields[1].text;
        if (fileName.length == 0) return;
        if (token.length > 0) {
            gManualToken = token;
        }
        runPipeline(fileName, @"0", getCurrentPath(), 0);
    }]];
    [vc presentViewController:input animated:YES completion:nil];
}

- (void)showFilePicker:(UIViewController *)vc files:(NSArray *)files {
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Select File" message:[NSString stringWithFormat:@"Path: %@\nFiles: %lu", getCurrentPath(), (unsigned long)files.count] preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *file in files) {
        NSString *name = file[@"server_filename"] ?: file[@"path"];
        NSInteger size = [file[@"size"] integerValue];
        NSString *sizeStr = size > 1024*1024 ? [NSString stringWithFormat:@"%.1fMB", size/1024.0/1024.0] : [NSString stringWithFormat:@"%.1fKB", size/1024.0];
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, sizeStr];
        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *fileName = file[@"server_filename"];
            NSString *fileId = [NSString stringWithFormat:@"%@", file[@"fs_id"]];
            NSInteger fileSize = [file[@"size"] integerValue];
            [self showTokenConfirmDialog:vc fileName:fileName fileId:fileId fileSize:fileSize];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Manual Input" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showManualInputDialog:vc];
    }]];
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UIPopoverPresentationController *pop = picker.popoverPresentationController;
        if (pop) {
            pop.sourceView = vc.view;
            pop.sourceRect = CGRectMake(vc.view.bounds.size.width/2, vc.view.bounds.size.height/2, 1, 1);
            pop.permittedArrowDirections = 0;
        }
    }
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)showTokenConfirmDialog:(UIViewController *)vc fileName:(NSString *)fileName fileId:(NSString *)fileId fileSize:(NSInteger)fileSize {
    UIAlertController *input = [UIAlertController alertControllerWithTitle:@"Confirm" message:[NSString stringWithFormat:@"File: %@\nPath: %@\n\nYou can edit path below", fileName, getCurrentPath()] preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken";
        tf.text = gManualToken ?: @"";
    }];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Path (editable)";
        tf.text = getCurrentPath();
    }];
    [input addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *token = input.textFields[0].text;
        NSString *customPath = input.textFields[1].text;
        if (token.length > 0) {
            gManualToken = token;
        }
        if (customPath.length > 0) {
            gCurrentPath = customPath;
        }
        DLog(@"Path: %@, File: %@", getCurrentPath(), fileName);
        runPipeline(fileName, fileId, getCurrentPath(), fileSize);
    }]];
    [vc presentViewController:input animated:YES completion:nil];
}

- (void)buttonTapped:(UIButton *)sender {
    @try {
        UIViewController *vc = topViewController();
        if (!vc) return;

        NSString *autoPath = getPathFromNavStack();
        if (autoPath) {
            gCurrentPath = autoPath;
            DLog(@"Auto path: %@", autoPath);
        } else {
            DLog(@"Auto path failed");
            if (!gCurrentPath || gCurrentPath.length == 0) {
                gCurrentPath = @"/";
            }
        }

        [self showSetupDialog:vc];

    } @catch (NSException *e) {
        DLog(@"Button tap error: %@", e.reason);
    }
}

- (void)showSetupDialog:(UIViewController *)vc {
    NSString *detectedPath = getCurrentPath();
    NSString *pathStatus = [detectedPath isEqualToString:@"/"] ? @"Auto-detect failed, please enter path" : @"Auto-detected OK";

    UIAlertController *setup = [UIAlertController alertControllerWithTitle:@"Setup" message:[NSString stringWithFormat:@"%@\n\nEnter path and bdstoken", pathStatus] preferredStyle:UIAlertControllerStyleAlert];

    [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Path, e.g. /foldername";
        tf.text = detectedPath;
    }];

    [setup addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken (from pan.baidu.com)";
        tf.text = gManualToken ?: @"";
    }];

    [setup addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [setup addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *userPath = setup.textFields[0].text;
        NSString *token = setup.textFields[1].text;

        if (userPath.length > 0) {
            gCurrentPath = userPath;
        }
        if (token.length > 0) {
            gManualToken = token;
        }

        if (!getBdstoken()) {
            showAlert(@"Error", @"Please enter bdstoken first");
            return;
        }

        DLog(@"Setup path: %@, token len: %lu", getCurrentPath(), (unsigned long)gManualToken.length);
        [self proceedWithFileList:vc];
    }]];

    [vc presentViewController:setup animated:YES completion:nil];
}

- (void)proceedWithFileList:(UIViewController *)vc {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Loading" message:@"Fetching file list..." preferredStyle:UIAlertControllerStyleAlert];
    [vc presentViewController:loading animated:YES completion:nil];

    fetchFileList(getCurrentPath(), ^(NSArray *files, NSError *err) {
        [loading dismissViewControllerAnimated:YES completion:^{
            if (err) {
                showAlert(@"List Failed", err.localizedDescription);
                return;
            }
            if (files.count == 0) {
                showAlert(@"Info", @"No files in this directory");
                return;
            }
            NSMutableArray *fileItems = [NSMutableArray array];
            for (NSDictionary *f in files) {
                if ([f[@"isdir"] integerValue] == 0) {
                    [fileItems addObject:f];
                }
            }
            if (fileItems.count == 0) {
                showAlert(@"Info", @"No files, only folders");
                return;
            }
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
    BOOL didAddMethod = class_addMethod(cls, originalSelector,
                                        method_getImplementation(swizzledMethod),
                                        method_getTypeEncoding(swizzledMethod));
    if (didAddMethod) {
        class_replaceMethod(cls, swizzledSelector,
                           method_getImplementation(originalMethod),
                           method_getTypeEncoding(originalMethod));
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
        DLog(@"[Swizzle] Path: %@ from %@", path, NSStringFromClass([self class]));
    }
}

@end

__attribute__((constructor)) static void init() {
    DLog(@"Loaded v4.6 (arm64)");
    static dispatch_once_t swizzleOnce;
    dispatch_once(&swizzleOnce, ^{
        swizzleInstanceMethod([UIViewController class], @selector(viewDidAppear:), @selector(hkc_viewDidAppear:));
        DLog(@"Swizzle registered");
    });
    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:[NSOperationQueue mainQueue]
                                                        usingBlock:^(NSNotification *note) {
            DLog(@"App active, add button");
            addFloatingButton();
        }];
        DLog(@"Notification set");
    } @catch (NSException *e) {
        DLog(@"Init error: %@", e.reason);
    }
}
