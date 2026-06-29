//
//  Tweak.xm
//  BaiduPanTroll - TrollStore Edition v12.0
//  基于 v10.28 成熟逻辑，改为 Method Swizzling 无 substrate 依赖
//  核心改进：后台无感操作，用户看不到刷新和滚动
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define DLog(fmt, ...) NSLog(@"[BNDP] " fmt, ##__VA_ARGS__)

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;

// 状态机
static NSString *gPendingRestoreFileId = nil;
static NSString *gPendingRestorePdfPath = nil;
static NSString *gPendingRestoreOriginalName = nil;
static NSTimer *gTapDetectionTimer = nil;
static NSInteger gNavStackCount = 0;
static BOOL gIsWaitingForTap = NO;
static BOOL gHasOpenedFile = NO;
static NSString *gInitialTopVCClass = nil;
static NSString *gInitialTopVCTitle = nil;

// ========== Method Swizzling 工具 ==========
static void swizzleMethod(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// ========== 获取顶层 VC ==========
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

static NSInteger currentNavStackCount(void) {
    UIViewController *vc = topViewController();
    if (!vc) return 0;
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    } else {
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
        if (window && window.rootViewController) {
            UIViewController *root = window.rootViewController;
            while (root.presentedViewController) root = root.presentedViewController;
            if ([root isKindOfClass:[UINavigationController class]]) {
                nav = (UINavigationController *)root;
            } else if ([root isKindOfClass:[UITabBarController class]]) {
                UIViewController *sel = [(UITabBarController *)root selectedViewController];
                if ([sel isKindOfClass:[UINavigationController class]]) {
                    nav = (UINavigationController *)sel;
                }
            }
        }
    }
    if (nav) return nav.viewControllers.count;
    return 1;
}

static NSString * topVCClassName(void) {
    UIViewController *vc = topViewController();
    return vc ? NSStringFromClass([vc class]) : @"nil";
}

static NSString * topVCTitle(void) {
    UIViewController *vc = topViewController();
    if (!vc) return @"nil";
    NSString *title = vc.title;
    if (!title || title.length == 0) title = vc.navigationItem.title;
    return title ?: @"nil";
}

// ========== 编码工具 ==========
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

// ========== Token 检测 ==========
static NSString * scanMemoryForBdstoken(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *allDefaults = [defaults dictionaryRepresentation];

    NSArray *preferredKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN",
                                @"access_token", @"bd_token", @"pan_token", @"panToken",
                                @"user_token", @"auth_token"];
    for (NSString *key in preferredKeys) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            if (str.length == 32) {
                NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
                if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                    NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                    if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] > 0) {
                        return str;
                    }
                }
            }
        }
    }

    NSArray *blacklistKeys = @[@"password", @"passwd", @"secret", @"credit", @"card", @"phone", @"mobile", @"email", @"address"];
    for (NSString *key in allDefaults) {
        BOOL isBlacklisted = NO;
        NSString *lowKey = key.lowercaseString;
        for (NSString *bk in blacklistKeys) {
            if ([lowKey containsString:bk]) { isBlacklisted = YES; break; }
        }
        if (isBlacklisted) continue;

        id value = allDefaults[key];
        if ([value isKindOfClass:[NSString class]]) {
            NSString *str = value;
            NSRegularExpression *hexRegex = [NSRegularExpression regularExpressionWithPattern:@"^[a-fA-F0-9]+$" options:0 error:nil];
            if ([hexRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] == 1) {
                NSRegularExpression *letterRegex = [NSRegularExpression regularExpressionWithPattern:@"[a-fA-F]" options:0 error:nil];
                if ([letterRegex numberOfMatchesInString:str options:0 range:NSMakeRange(0, str.length)] > 0) {
                    if (str.length == 32) return str;
                }
            }
        }
    }
    return nil;
}

static void autoDetectPathAndToken(void) {
    DLog(@"Starting auto-detection...");
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN", @"access_token", @"bd_token", @"pan_token"];
    for (NSString *key in tokenKeys) {
        gBdstoken = [defaults objectForKey:key];
        if (gBdstoken) break;
    }
    if (!gBdstoken) gBdstoken = scanMemoryForBdstoken();
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [cookieStorage cookies]) {
        if ([cookie.name isEqualToString:@"BDUSS"]) { gBDUSS = cookie.value; break; }
    }
    if (!gBDUSS) gBDUSS = [defaults objectForKey:@"BDUSS"];
    gCurrentPath = @"/";
    UIViewController *vc = topViewController();
    if (vc) {
        NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir",
                              @"_path", @"_currentPath", @"directory", @"folderPath", @"currentFolder"];
        for (NSString *key in pathKeys) {
            @try {
                id value = [vc valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    gCurrentPath = value;
                    if (![gCurrentPath hasPrefix:@"/"]) gCurrentPath = [@"/" stringByAppendingString:gCurrentPath];
                    break;
                }
            } @catch (NSException *e) {}
        }
    }
}

// ========== 文件列表 ==========
static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BNDP" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100", encodedPath, gBdstoken];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BNDP" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        completion(list, nil);
    });
}

// ========== 重命名 ==========
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!gBdstoken) {
        completion(NO, [NSError errorWithDomain:@"BNDP" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
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
            completion(NO, [NSError errorWithDomain:@"BNDP" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

// ========== Toast ==========
static void showToast(NSString *msg) {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
            if (scene.activationState == UISceneActivationStateForegroundActive) { window = scene.windows.firstObject; break; }
        }
    }
    if (!window) window = [[UIApplication sharedApplication] keyWindow];
    if (!window) return;
    for (UIView *sub in window.subviews) {
        if (sub.tag == 0xBDF0) [sub removeFromSuperview];
    }
    UILabel *toast = [[UILabel alloc] init];
    toast.tag = 0xBDF0;
    toast.text = msg;
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:14];
    toast.layer.cornerRadius = 16;
    toast.layer.masksToBounds = YES;
    toast.numberOfLines = 0;
    [toast sizeToFit];
    CGFloat w = MIN(toast.bounds.size.width + 32, window.bounds.size.width - 40);
    CGFloat h = toast.bounds.size.height + 16;
    toast.frame = CGRectMake((window.bounds.size.width - w) / 2, window.bounds.size.height - 140, w, h);
    [window addSubview:toast];
    toast.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL finished) { [toast removeFromSuperview]; }];
    });
}

// ========== 刷新文件列表（后台无感） ==========
static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) return;

    // 1. 尝试调用 VC 的刷新方法
    NSArray *refreshSelectors = @[
        @"refreshFileList", @"reloadFileList", @"updateFileList",
        @"refreshData", @"reloadData", @"updateData",
        @"requestFileList", @"fetchFileList", @"loadFileList",
        @"refresh", @"reload", @"update", @"requestData", @"loadData"
    ];
    for (NSString *selName in refreshSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            return;
        }
    }

    // 2. 查找 TableView/CollectionView 直接 reload
    UIScrollView *listView = nil;
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]] || [sub isKindOfClass:[UICollectionView class]]) {
            listView = (UIScrollView *)sub;
            break;
        }
    }
    if (!listView) {
        // 递归查找
        NSMutableArray *queue = [NSMutableArray arrayWithArray:vc.view.subviews];
        while ([queue count] > 0) {
            UIView *v = [queue objectAtIndex:0];
            [queue removeObjectAtIndex:0];
            if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
                listView = (UIScrollView *)v;
                break;
            }
            [queue addObjectsFromArray:v.subviews];
        }
    }
    if ([listView isKindOfClass:[UITableView class]]) {
        [(UITableView *)listView reloadData];
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)listView reloadData];
    }

    // 3. 发送通知作为兜底
    NSArray *notifNames = @[
        @"BDPanRefreshFileListNotification",
        @"BDPanReloadFileListNotification",
        @"kRefreshFileListNotification",
        @"RefreshFileListNotification"
    ];
    for (NSString *name in notifNames) {
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:@{@"path": gCurrentPath ?: @"/"}];
    }
}

// ========== 查找列表视图 ==========
static UIScrollView * findListViewInVC(UIViewController *vc) {
    if (!vc) return nil;
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]] || [sub isKindOfClass:[UICollectionView class]]) {
            return (UIScrollView *)sub;
        }
    }
    NSMutableArray *queue = [NSMutableArray arrayWithArray:vc.view.subviews];
    while ([queue count] > 0) {
        UIView *v = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITableView class]] || [v isKindOfClass:[UICollectionView class]]) {
            return (UIScrollView *)v;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// ========== 查找 cell 包含指定文本 ==========
static BOOL viewContainsText(UIView *view, NSString *text) {
    if (!view || !text) return NO;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (lbl.text && [lbl.text containsString:text]) return YES;
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        if (btn.currentTitle && [btn.currentTitle containsString:text]) return YES;
    }
    for (UIView *sub in view.subviews) {
        if (viewContainsText(sub, text)) return YES;
    }
    return NO;
}

// ========== 在 TableView 中搜索文件 ==========
static NSIndexPath * searchFileInTableView(NSString *targetName, UITableView *tv) {
    if (!targetName || !tv) return nil;
    NSInteger totalSections = 1;
    @try { totalSections = [tv numberOfSections]; } @catch (NSException *e) {}
    for (NSInteger section = 0; section < totalSections; section++) {
        NSInteger rows = 0;
        @try { rows = [tv numberOfRowsInSection:section]; } @catch (NSException *e) {}
        for (NSInteger row = rows - 1; row >= 0; row--) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
            @try {
                UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                if (cell && viewContainsText(cell, targetName)) return ip;
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

// ========== 在 CollectionView 中搜索文件 ==========
static NSIndexPath * searchFileInCollectionView(NSString *targetName, UICollectionView *cv) {
    if (!targetName || !cv) return nil;
    NSInteger totalSections = 1;
    @try { totalSections = [cv numberOfSections]; } @catch (NSException *e) {}
    for (NSInteger section = 0; section < totalSections; section++) {
        NSInteger items = 0;
        @try { items = [cv numberOfItemsInSection:section]; } @catch (NSException *e) {}
        for (NSInteger item = items - 1; item >= 0; item--) {
            NSIndexPath *ip = [NSIndexPath indexPathForItem:item inSection:section];
            @try {
                UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                if (cell && viewContainsText(cell, targetName)) return ip;
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

// ========== 核心：后台无感打开文件 ==========
static void openFileWithoutUserSeeing(NSString *targetName) {
    if (!targetName) return;
    DLog(@"Opening file without user seeing: %@", targetName);

    UIViewController *vc = topViewController();
    if (!vc) { DLog(@"No top VC"); return; }

    UIScrollView *listView = findListViewInVC(vc);
    if (!listView) { DLog(@"No list view found"); return; }

    // 1. 先尝试直接查找（文件可能已在可见区域）
    NSIndexPath *foundPath = nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        foundPath = searchFileInTableView(targetName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        foundPath = searchFileInCollectionView(targetName, (UICollectionView *)listView);
    }

    // 2. 如果没找到，瞬间滚动到顶部再查找
    if (!foundPath) {
        DLog(@"File not visible, instant scroll to top");
        [listView setContentOffset:CGPointZero animated:NO];

        // 强制刷新数据
        if ([listView isKindOfClass:[UITableView class]]) {
            [(UITableView *)listView reloadData];
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)listView reloadData];
        }

        // 等待一帧让 cell 渲染
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSIndexPath *ip = nil;
            if ([listView isKindOfClass:[UITableView class]]) {
                ip = searchFileInTableView(targetName, (UITableView *)listView);
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                ip = searchFileInCollectionView(targetName, (UICollectionView *)listView);
            }

            if (ip) {
                DLog(@"Found after reload, selecting...");
                // 瞬间滚动到该位置（无动画）
                if ([listView isKindOfClass:[UITableView class]]) {
                    [(UITableView *)listView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                    // 直接调用 delegate
                    id delegate = [(UITableView *)listView delegate];
                    SEL sel = @selector(tableView:didSelectRowAtIndexPath:);
                    if (delegate && [delegate respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [delegate performSelector:sel withObject:listView withObject:ip];
                        #pragma clang diagnostic pop
                    }
                } else if ([listView isKindOfClass:[UICollectionView class]]) {
                    [(UICollectionView *)listView scrollToItemAtIndexPath:ip atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
                    id delegate = [(UICollectionView *)listView delegate];
                    SEL sel = @selector(collectionView:didSelectItemAtIndexPath:);
                    if (delegate && [delegate respondsToSelector:sel]) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [delegate performSelector:sel withObject:listView withObject:ip];
                        #pragma clang diagnostic pop
                    }
                }
            } else {
                // 3. 如果还是没找到，逐个区域滚动查找（仍然无动画）
                DLog(@"Not found after reload, scanning all sections...");
                scanAllSectionsAndOpen(targetName, listView, 0);
            }
        });
        return;
    }

    // 文件已可见，直接打开
    DLog(@"File already visible, selecting directly");
    if ([listView isKindOfClass:[UITableView class]]) {
        [(UITableView *)listView scrollToRowAtIndexPath:foundPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        id delegate = [(UITableView *)listView delegate];
        SEL sel = @selector(tableView:didSelectRowAtIndexPath:);
        if (delegate && [delegate respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:sel withObject:listView withObject:foundPath];
            #pragma clang diagnostic pop
        }
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        [(UICollectionView *)listView scrollToItemAtIndexPath:foundPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
        id delegate = [(UICollectionView *)listView delegate];
        SEL sel = @selector(collectionView:didSelectItemAtIndexPath:);
        if (delegate && [delegate respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [delegate performSelector:sel withObject:listView withObject:foundPath];
            #pragma clang diagnostic pop
        }
    }
}

// 逐个区域扫描（无动画）
static void scanAllSectionsAndOpen(NSString *targetName, UIScrollView *listView, NSInteger section) {
    if (!targetName || !listView) return;

    NSInteger totalSections = 1;
    if ([listView isKindOfClass:[UITableView class]]) {
        @try { totalSections = [(UITableView *)listView numberOfSections]; } @catch (NSException *e) {}
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        @try { totalSections = [(UICollectionView *)listView numberOfSections]; } @catch (NSException *e) {}
    }

    if (section >= totalSections) {
        DLog(@"Scanned all sections, file not found");
        showToast(@"未找到文件，请手动打开");
        return;
    }

    NSInteger totalItems = 0;
    if ([listView isKindOfClass:[UITableView class]]) {
        @try { totalItems = [(UITableView *)listView numberOfRowsInSection:section]; } @catch (NSException *e) {}
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        @try { totalItems = [(UICollectionView *)listView numberOfItemsInSection:section]; } @catch (NSException *e) {}
    }

    // 计算该 section 的滚动位置
    CGFloat scrollY = 0;
    if ([listView isKindOfClass:[UITableView class]]) {
        @try {
            NSIndexPath *firstIP = [NSIndexPath indexPathForRow:0 inSection:section];
            scrollY = [(UITableView *)listView rectForRowAtIndexPath:firstIP].origin.y;
        } @catch (NSException *e) {}
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        @try {
            NSIndexPath *firstIP = [NSIndexPath indexPathForItem:0 inSection:section];
            scrollY = [(UICollectionView *)listView layoutAttributesForItemAtIndexPath:firstIP].frame.origin.y;
        } @catch (NSException *e) {}
    }

    [listView setContentOffset:CGPointMake(0, scrollY) animated:NO];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSIndexPath *ip = nil;
        if ([listView isKindOfClass:[UITableView class]]) {
            ip = searchFileInTableView(targetName, (UITableView *)listView);
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            ip = searchFileInCollectionView(targetName, (UICollectionView *)listView);
        }

        if (ip) {
            DLog(@"Found in section %ld, opening...", (long)section);
            if ([listView isKindOfClass:[UITableView class]]) {
                [(UITableView *)listView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                id delegate = [(UITableView *)listView delegate];
                SEL sel = @selector(tableView:didSelectRowAtIndexPath:);
                if (delegate && [delegate respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [delegate performSelector:sel withObject:listView withObject:ip];
                    #pragma clang diagnostic pop
                }
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                [(UICollectionView *)listView scrollToItemAtIndexPath:ip atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
                id delegate = [(UICollectionView *)listView delegate];
                SEL sel = @selector(collectionView:didSelectItemAtIndexPath:);
                if (delegate && [delegate respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [delegate performSelector:sel withObject:listView withObject:ip];
                    #pragma clang diagnostic pop
                }
            }
            return;
        }

        scanAllSectionsAndOpen(targetName, listView, section + 1);
    });
}

// ========== 检测文件是否已打开 ==========
static void checkIfFileOpened(void) {
    if (!gIsWaitingForTap) return;

    NSInteger currentCount = currentNavStackCount();
    NSString *currentClass = topVCClassName();
    NSString *currentTitle = topVCTitle();

    if (!gHasOpenedFile) {
        BOOL opened = NO;
        if (currentCount > gNavStackCount) {
            opened = YES;
        } else if (gInitialTopVCClass && ![gInitialTopVCClass isEqualToString:currentClass]) {
            opened = YES;
        } else if (currentTitle && ([currentTitle containsString:@"预览"] || [currentTitle containsString:@"下载"] || [currentTitle containsString:@"文件详情"])) {
            opened = YES;
        }

        if (opened) {
            gHasOpenedFile = YES;
            showToast(@"已进入下载界面，恢复原名...");
            if (gTapDetectionTimer) {
                [gTapDetectionTimer invalidate];
                gTapDetectionTimer = nil;
            }
            executeRestore();
        }
    }
}

static void executeRestore(void) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        stopTapDetection();
        return;
    }
    DLog(@"Restoring: %@ -> %@", gPendingRestorePdfPath, gPendingRestoreOriginalName);
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        if (ok) {
            showToast(@"已恢复原名");
            forceRefreshFileList();
        } else {
            showToast([NSString stringWithFormat:@"恢复失败: %@", e.localizedDescription]);
        }
        gPendingRestoreFileId = nil;
        gPendingRestorePdfPath = nil;
        gPendingRestoreOriginalName = nil;
        gIsWaitingForTap = NO;
        gHasOpenedFile = NO;
    });
}

static void stopTapDetection(void) {
    if (gTapDetectionTimer) {
        [gTapDetectionTimer invalidate];
        gTapDetectionTimer = nil;
    }
    gIsWaitingForTap = NO;
    gHasOpenedFile = NO;
}

static void startTapDetection(void) {
    stopTapDetection();
    gIsWaitingForTap = YES;
    gHasOpenedFile = NO;
    gNavStackCount = currentNavStackCount();
    gInitialTopVCClass = topVCClassName();
    gInitialTopVCTitle = topVCTitle();

    gTapDetectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                            target:[NSBlockOperation blockOperationWithBlock:^{ checkIfFileOpened(); }]
                                                          selector:@selector(main)
                                                          userInfo:nil
                                                           repeats:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gIsWaitingForTap) {
            stopTapDetection();
            showToast(@"等待超时，恢复原名");
            executeRestore();
        }
    });
}

// ========== 核心流程 ==========
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize) {
    if (fileSize && [fileSize doubleValue] >= 300.0 * 1024.0 * 1024.0) {
        showToast(@"该文件超过300MB，无法下载");
        return;
    }
    stopTapDetection();
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;

    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"88888888888888"]) {
        showToast(@"文件已是 .88888888888888，无需处理");
        return;
    }

    NSString *ppName = [fileName stringByAppendingString:@".88888888888888"];
    NSString *ppPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName];

    showToast(@"正在处理...");
    renameFile(fileId, filePath, ppName, ^(BOOL success, NSError *err) {
        if (!success) {
            showToast([NSString stringWithFormat:@"重命名失败: %@", err.localizedDescription]);
            return;
        }

        gPendingRestoreFileId = fileId;
        gPendingRestorePdfPath = ppPath;
        gPendingRestoreOriginalName = fileName;

        // 后台刷新（无感）
        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            forceRefreshFileList();

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // 启动检测
                startTapDetection();
                // 后台无感打开文件
                openFileWithoutUserSeeing(ppName);
            });
        });
    });
}

// ========== 浮球点击 ==========
static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();
    if (!gBdstoken) {
        showToast(@"未检测到登录状态");
        return;
    }

    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) {
            showToast(err ? err.localizedDescription : @"文件夹为空");
            return;
        }
        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }
        if (fileItems.count == 0) {
            showToast(@"当前文件夹没有可下载的文件");
            return;
        }
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                       message:@"选择后自动处理"
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *file in fileItems) {
            NSString *name = file[@"server_filename"];
            NSNumber *size = file[@"size"];
            NSString *fid = [file[@"fs_id"] stringValue];
            NSString *path = file[@"path"];
            NSString *title = name;
            if (size) {
                double mb = [size doubleValue] / (1024.0 * 1024.0);
                title = [NSString stringWithFormat:@"%@ (%.1f MB)", name, mb];
            }
            BOOL isTooLarge = (size && [size doubleValue] >= 300.0 * 1024.0 * 1024.0);
            UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                               style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction *action) {
                if (isTooLarge) {
                    showToast(@"该文件超过300MB，无法下载");
                    return;
                }
                runSmartFlow(name, path, fid, size);
            }];
            if (isTooLarge) {
                [action setValue:@NO forKey:@"enabled"];
            }
            [sheet addAction:action];
        }
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        [sheet addAction:cancelAction];
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

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    NSString *tokenInfo = gBdstoken ? [NSString stringWithFormat:@"%@... (%lu位)", [gBdstoken substringToIndex:MIN(8, gBdstoken.length)], (unsigned long)gBdstoken.length] : @"missing";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v12.0"
                                                                   message:[NSString stringWithFormat:@"Path: %@\nToken: %@\nBDUSS: %@\n\n选择文件后自动改名并打开", gCurrentPath, tokenInfo, gBDUSS ? @"OK" : @"missing"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
        triggerDownloadFlow();
    }];
    [alert addAction:downloadAction];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                         style:UIAlertActionStyleCancel
                                                       handler:nil];
    [alert addAction:okAction];
    UIViewController *vc = topViewController();
    if (vc) [vc presentViewController:alert animated:YES completion:nil];
}

// ========== 浮球 ==========
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
    [gFloatButton setTitle:@"BD" forState:UIControlStateNormal];
    [gFloatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [gFloatButton addTarget:nil action:@selector(bdt_floatButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:@selector(bdt_floatButtonPanned:)];
    [gFloatButton addGestureRecognizer:pan];
    [window addSubview:gFloatButton];
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

// ========== 构造函数 ==========
__attribute__((constructor))
static void baiduPanTrollInit(void) {
    DLog(@"BaiduPan Troll v12.0 loaded - Invisible Operation Edition");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
