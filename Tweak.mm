//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v7.8
//  Added: Fetch & copy direct download link to clipboard for testing
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

// ========== 全局状态 ==========
static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;
static NSMutableArray *gFileList = nil;

// ========== 前向声明 ==========
static UIViewController * topViewController(void);
static void showFloatButton(void);
static void autoDetectPathAndToken(void);
static NSString * strictEncodeURIComponent(NSString *str);
static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err));
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void fetchDirectLink(NSString *fsId, void (^completion)(NSString *link, NSError *err));
static void copyToClipboard(NSString *text);
static void copyDirectLink(NSString *fileId, NSString *fileName);
static void simulateTapFileNamed(NSString *fileName);
static void forceRefreshFileList(void);
static void downloadSingleFile(NSString *fileName, NSString *filePath, NSString *fileId);
static void triggerDownloadFlow(void);
static void autoNavigateBack(void);

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
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }

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

// ========== 网络请求 ==========

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

    if (gBDUSS) {
        allHeaders[@"Cookie"] = [NSString stringWithFormat:@"BDUSS=%@", gBDUSS];
    }
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

// ========== 自动获取 Token & Path ==========

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
                        DLog(@"🔍 Found 32-bit token in key '%@': %@...", key, [str substringToIndex:MIN(16, str.length)]);
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
        DLog(@"⚠️ Only found 16-bit token in key '%@': %@...", bestKey, [bestToken substringToIndex:MIN(16, bestToken.length)]);
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
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                DLog(@"✅ Found path from VC.%@ = %@", key, value);
                return value;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }

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
    if (![fullPath hasPrefix:@"/"]) {
        fullPath = [@"/" stringByAppendingString:fullPath];
    }
    return fullPath;
}

static void autoDetectPathAndToken(void) {
    DLog(@"🔍 Starting auto-detection...");

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN", @"access_token", @"bd_token", @"pan_token"];
    for (NSString *key in tokenKeys) {
        gBdstoken = [defaults objectForKey:key];
        if (gBdstoken) { DLog(@"✅ Got bdstoken from key: %@", key); break; }
    }
    if (!gBdstoken) gBdstoken = scanMemoryForBdstoken();

    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) {
            gBDUSS = cookie.value;
            DLog(@"✅ Got BDUSS from cookie");
            break;
        }
    }
    if (!gBDUSS) {
        gBDUSS = [defaults objectForKey:@"BDUSS"];
        if (gBDUSS) DLog(@"✅ Got BDUSS from NSUserDefaults");
    }

    gCurrentPath = buildPathFromNavStack();
    if (!gCurrentPath) gCurrentPath = @"/";

    DLog(@"📊 Path: %@ | Token: %@ | BDUSS: %@", 
         gCurrentPath, 
         gBdstoken ? [gBdstoken substringToIndex:MIN(16, gBdstoken.length)] : @"❌", 
         gBDUSS ? @"✅" : @"❌");
}

// ========== 文件列表获取 ==========

static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
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

// ========== 文件重命名 ==========

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!gBdstoken) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@", gBdstoken];
    NSString *body = [NSString stringWithFormat:@"filelist=[{\"path\":\"%@\",\"newname\":\"%@\"}]", path, newName];

    NSDictionary *headers = @{
        @"Content-Type": @"application/x-www-form-urlencoded",
        @"X-Requested-With": @"XMLHttpRequest"
    };

    bdAsyncRequest(url, @"POST", headers, body, ^(id json, NSError *err) {
        if (err) { completion(NO, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"errmsg"] ?: @"Unknown error";
            completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

// ========== 直链获取 & 剪贴板 ==========

static void fetchDirectLink(NSString *fsId, void (^completion)(NSString *link, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }

    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=1&web=1&app_id=250528&fsids=[%@]&dlink=1", gBdstoken, fsId];

    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] == 0) {
            NSArray *list = json[@"info"];
            if (list && [list isKindOfClass:[NSArray class]] && list.count > 0) {
                NSDictionary *fileInfo = list[0];
                NSString *dlink = fileInfo[@"dlink"];
                if (dlink && [dlink isKindOfClass:[NSString class]] && dlink.length > 0) {
                    completion(dlink, nil);
                } else {
                    completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"No dlink in response"}]);
                }
            } else {
                completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"No file info in response"}]);
            }
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"Unknown error (errno=%@)", errnoNum];
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static void copyToClipboard(NSString *text) {
    if (!text) return;
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = text;
    DLog(@"📋 Copied to clipboard: %@", text);
}

static void copyDirectLink(NSString *fileId, NSString *fileName) {
    DLog(@"🔗 Fetching direct link for: %@", fileName);

    UIAlertController *loadingAlert = [UIAlertController alertControllerWithTitle:@"获取直链中..." message:fileName preferredStyle:UIAlertControllerStyleAlert];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:loadingAlert animated:YES completion:nil];

    fetchDirectLink(fileId, ^(NSString *link, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loadingAlert dismissViewControllerAnimated:YES completion:^{
                if (err || !link) {
                    UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"获取直链失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
                    [errAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc2 = topViewController();
                    if (vc2) [vc2 presentViewController:errAlert animated:YES completion:nil];
                } else {
                    copyToClipboard(link);
                    NSString *msg = [NSString stringWithFormat:@"文件名: %@\n\n链接已复制到剪贴板，可用浏览器或下载工具测试。\n\n%@", fileName, link];
                    if (gBDUSS) {
                        msg = [NSString stringWithFormat:@"文件名: %@\n\n链接已复制到剪贴板，可用浏览器或下载工具测试。\n\n%@\n\n⚠️ 提示：若链接无法直接下载，尝试在请求头中添加 Cookie: BDUSS=%@", fileName, link, gBDUSS];
                    }
                    UIAlertController *succAlert = [UIAlertController alertControllerWithTitle:@"✅ 直链已复制" message:msg preferredStyle:UIAlertControllerStyleAlert];
                    [succAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    UIViewController *vc2 = topViewController();
                    if (vc2) [vc2 presentViewController:succAlert animated:YES completion:nil];
                }
            }];
        });
    });
}

// ========== 强制刷新文件列表 ==========

static void triggerRefreshControlInView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)view;
        if (scrollView.refreshControl) {
            DLog(@"✅ Triggering UIRefreshControl");
            [scrollView.refreshControl beginRefreshing];
            scrollView.contentOffset = CGPointMake(0, -scrollView.refreshControl.frame.size.height);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [scrollView.refreshControl endRefreshing];
            });
            return;
        }
    }
    for (UIView *subview in view.subviews) {
        triggerRefreshControlInView(subview);
    }
}

static void forceRefreshFileList(void) {
    DLog(@"🔄 Force refreshing file list...");

    UIViewController *vc = topViewController();
    if (!vc) return;

    NSArray *refreshSelectors = @[@"refreshData", @"reloadData", @"refreshFileList", @"loadData", @"requestData", @"fetchFileList", @"reloadFileList"];

    for (NSString *selName in refreshSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"✅ Calling VC refresh method: %@", selName);
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            return;
        }
    }

    triggerRefreshControlInView(vc.view);
}

// ========== 模拟点击 ==========

static UIScrollView * findScrollViewInView(UIView *view) {
    if ([view isKindOfClass:[UITableView class]] || [view isKindOfClass:[UICollectionView class]]) {
        return (UIScrollView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIScrollView *found = findScrollViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static void simulateRealTapOnView(UIView *targetView) {
    if (!targetView) return;
    CGPoint center = CGPointMake(targetView.bounds.size.width / 2, targetView.bounds.size.height / 2);

    UITouch *touch = [[UITouch alloc] init];
    @try {
        [touch setValue:targetView forKey:@"view"];
        [touch setValue:[NSNumber numberWithInteger:1] forKey:@"phase"];
        [touch setValue:[NSNumber numberWithBool:NO] forKey:@"isTap"];
        [touch setValue:[NSNumber numberWithInteger:1] forKey:@"tapCount"];
    } @catch (NSException *e) {}

    UIEvent *event = [[UIApplication sharedApplication] performSelector:@selector(_touchesEvent)];
    [targetView touchesBegan:[NSSet setWithObject:touch] withEvent:event];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [targetView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
    });

    DLog(@"👆 Simulated real tap on view");
}

static void simulateTapFileNamed(NSString *fileName) {
    DLog(@"👆 Simulating tap on file: %@", fileName);

    UIViewController *vc = topViewController();
    if (!vc) { DLog(@"❌ No top VC"); return; }

    UIScrollView *targetScrollView = findScrollViewInView(vc.view);
    if (!targetScrollView) { DLog(@"❌ No scroll view found"); return; }

    DLog(@"✅ Found scroll view: %@", NSStringFromClass([targetScrollView class]));

    if ([targetScrollView isKindOfClass:[UITableView class]]) {
        UITableView *tableView = (UITableView *)targetScrollView;
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            DLog(@"🔍 Searching for cell with name: %@", fileName);

            for (NSIndexPath *indexPath in [tableView indexPathsForVisibleRows]) {
                UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                if (!cell) continue;

                BOOL found = NO;
                for (UIView *subview in cell.contentView.subviews) {
                    if ([subview isKindOfClass:[UILabel class]]) {
                        UILabel *label = (UILabel *)subview;
                        if (label.text && ([label.text isEqualToString:fileName] || [label.text containsString:fileName])) {
                            found = YES;
                            break;
                        }
                    }
                }

                if (found) {
                    DLog(@"✅ Found cell at indexPath: %@", indexPath);

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [tableView.delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
                        [tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
                    });

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        simulateRealTapOnView(cell);
                    });

                    return;
                }
            }
            DLog(@"⚠️ Cell not found for: %@", fileName);

            NSArray *visibleRows = [tableView indexPathsForVisibleRows];
            if (visibleRows.count > 0) {
                NSIndexPath *firstPath = visibleRows[0];
                UITableViewCell *firstCell = [tableView cellForRowAtIndexPath:firstPath];
                DLog(@"⚠️ Trying first visible cell as fallback");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [tableView.delegate tableView:tableView didSelectRowAtIndexPath:firstPath];
                    simulateRealTapOnView(firstCell);
                });
            }
        });

    } else if ([targetScrollView isKindOfClass:[UICollectionView class]]) {
        UICollectionView *collectionView = (UICollectionView *)targetScrollView;
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            for (NSIndexPath *indexPath in [collectionView indexPathsForVisibleItems]) {
                UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
                if (!cell) continue;

                BOOL found = NO;
                for (UIView *subview in cell.contentView.subviews) {
                    if ([subview isKindOfClass:[UILabel class]]) {
                        UILabel *label = (UILabel *)subview;
                        if (label.text && ([label.text isEqualToString:fileName] || [label.text containsString:fileName])) {
                            found = YES;
                            break;
                        }
                    }
                }

                if (found) {
                    DLog(@"✅ Found collection cell at indexPath: %@", indexPath);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [collectionView.delegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
                    });
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        simulateRealTapOnView(cell);
                    });
                    return;
                }
            }
            DLog(@"⚠️ Collection cell not found for: %@", fileName);
        });
    }
}

// ========== 自动返回上一页 ==========

static void autoNavigateBack(void) {
    DLog(@"🔙 Auto navigating back...");

    UIViewController *vc = topViewController();
    if (!vc) return;

    if (vc.navigationController && vc.navigationController.viewControllers.count > 1) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [vc.navigationController popViewControllerAnimated:YES];
            DLog(@"✅ Popped view controller");
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [vc dismissViewControllerAnimated:YES completion:nil];
            DLog(@"✅ Dismissed modal");
        });
    }
}

// ========== 触发下载流程（改进版） ==========

static void downloadSingleFile(NSString *fileName, NSString *filePath, NSString *fileId) {
    DLog(@"🎯 Target file: %@ at %@", fileName, filePath);

    NSString *pdfName = [fileName stringByAppendingString:@".pdf"];
    DLog(@"📝 Renaming to: %@", pdfName);

    renameFile(fileId, filePath, pdfName, ^(BOOL success, NSError *err) {
        if (!success) {
            DLog(@"❌ Rename failed: %@", err.localizedDescription);
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名失败" message:err.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        DLog(@"✅ Renamed successfully!");

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已重命名"
                                                                       message:[NSString stringWithFormat:@"%@ -> %@\n\n正在打开文件刷新状态...", fileName, pdfName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        UIViewController *vc = topViewController();
        if (vc) [vc presentViewController:alert animated:YES completion:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

            simulateTapFileNamed(pdfName);

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                autoNavigateBack();

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DLog(@"🎯 Second tap to trigger download...");
                    simulateTapFileNamed(pdfName);

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        DLog(@"🔄 Restoring original name...");
                        NSString *pdfPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:pdfName];
                        renameFile(fileId, pdfPath, fileName, ^(BOOL success, NSError *err) {
                            DLog(@"%@ Restore name: %@", success ? @"✅" : @"❌", err ? err.localizedDescription : @"");
                        });
                    });
                });
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    DLog(@"🚀 Starting download flow...");

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            DLog(@"❌ Failed to get file list: %@", err ? err.localizedDescription : @"No files");
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"获取文件列表失败" message:err ? err.localizedDescription : @"文件夹为空" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        gFileList = [files mutableCopy];
        DLog(@"✅ Got %lu files", (unsigned long)files.count);

        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) {
                [fileItems addObject:file];
            }
        }

        if (fileItems.count == 0) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"没有文件" message:@"当前文件夹没有可下载的文件" preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:alert animated:YES completion:nil];
            return;
        }

        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件" message:nil preferredStyle:UIAlertControllerStyleActionSheet];

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
                UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:name message:@"选择操作方式" preferredStyle:UIAlertControllerStyleAlert];

                [actionSheet addAction:[UIAlertAction actionWithTitle:@"📥 触发下载(重命名法)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    downloadSingleFile(name, path, fileId);
                }]];

                [actionSheet addAction:[UIAlertAction actionWithTitle:@"🔗 复制直链到剪贴板" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                    copyDirectLink(fileId, name);
                }]];

                [actionSheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

                UIViewController *vc = topViewController();
                if (vc) {
                    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                        actionSheet.popoverPresentationController.sourceView = vc.view;
                        actionSheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
                    }
                    [vc presentViewController:actionSheet animated:YES completion:nil];
                }
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

    NSString *tokenInfo = @"❌";
    if (gBdstoken) {
        tokenInfo = [NSString stringWithFormat:@"%@ (%lu位)", 
                     [gBdstoken substringToIndex:MIN(16, gBdstoken.length)], 
                     (unsigned long)gBdstoken.length];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v7.8"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@", gCurrentPath, tokenInfo, gBDUSS ? @"✅" : @"❌"]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"📥 触发下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        triggerDownloadFlow();
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"🔗 复制首个直链" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        fetchFileList(^(NSArray *files, NSError *err) {
            if (err || !files || files.count == 0) {
                UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"失败" message:@"无法获取文件列表" preferredStyle:UIAlertControllerStyleAlert];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *vc = topViewController();
                if (vc) [vc presentViewController:errAlert animated:YES completion:nil];
                return;
            }
            for (NSDictionary *file in files) {
                NSNumber *isdir = file[@"isdir"];
                if (!isdir || [isdir integerValue] == 0) {
                    NSString *fid = [file[@"fs_id"] stringValue];
                    NSString *fname = file[@"server_filename"];
                    copyDirectLink(fid, fname);
                    return;
                }
            }
            UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"失败" message:@"当前文件夹没有文件" preferredStyle:UIAlertControllerStyleAlert];
            [errAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *vc = topViewController();
            if (vc) [vc presentViewController:errAlert animated:YES completion:nil];
        });
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
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = scene.windows.firstObject;
                break;
            }
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
    DLog(@"✅ Float button shown");
}

@interface NSObject (BaiduPanTroll)
- (void)bdt_floatButtonTapped:(id)sender;
- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture;
@end

@implementation NSObject (BaiduPanTroll)

- (void)bdt_floatButtonTapped:(id)sender {
    onFloatButtonTap();
}

- (void)bdt_floatButtonPanned:(UIPanGestureRecognizer *)gesture {
    UIView *button = gesture.view;
    CGPoint translation = [gesture translationInView:button.superview];
    button.center = CGPointMake(button.center.x + translation.x, button.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:button.superview];
}

@end

// ========== 初始化 ==========

__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"🚀 BaiduPan Troll v7.8 loaded");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
