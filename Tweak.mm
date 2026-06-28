//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v10.0
//  Fix: 修复自动点击逻辑，利用类清单精确定位下载链路
//  核心：Hook 文件列表 Cell 点击事件，多维度匹配 + 深度视图搜索 + 下载管理器直接调用
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

// ========== v10.0 新增：自动点击修复 ==========
static UIView * findViewRecursively(UIView *root, Class targetClass);
static UIView * findViewByClassName(UIView *root, NSString *className);
static id getDownloadManagerFromClasses(void);
static id getFileListDataSource(UIViewController *vc);
static BOOL matchFileMeta(id item, NSDictionary *targetMeta);
static void simulateTouchOnView(UIView *view);
static void triggerCellActionByClassList(id cell, NSDictionary *fileMeta);
static void triggerDownloadViaManager(NSDictionary *fileMeta);
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
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir", @"_path", @"_currentPath", @"directory", @"folderPath", @"currentFolder", @"mPath", @"_mPath", @"fileListPath", @"_filePath", @"_dirPath"];
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
    NSArray *tokenKeys = @[@"bdstoken", @"BDSTOKEN", @"token", @"TOKEN", @"access_token", @"bd_token", @"pan_token", @"_bdstoken", @"user.bdstoken"];
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

// ========== v10.0 核心：修复自动点击 ==========

// 递归深度查找指定类的视图
static UIView * findViewRecursively(UIView *root, Class targetClass) {
    if (!root) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = findViewRecursively(subview, targetClass);
        if (found) return found;
    }
    return nil;
}

// 通过类名字符串递归查找视图
static UIView * findViewByClassName(UIView *root, NSString *className) {
    if (!root || !className) return nil;
    Class cls = NSClassFromString(className);
    if (!cls) return nil;
    return findViewRecursively(root, cls);
}

// 尝试从清单中的下载管理类获取实例
static id getDownloadManagerFromClasses(void) {
    NSArray *managerClasses = @[
        @"BDPanDownloadManager",
        @"BBADownloaderManager",
        @"BBADownloadService",
        @"BDPanDownloadFileUtil",
        @"BBADownloadCompressManager"
    ];

    for (NSString *className in managerClasses) {
        Class cls = NSClassFromString(className);
        if (!cls) continue;

        // 尝试单例方法
        NSArray *singletonSelectors = @[@"sharedManager", @"sharedInstance", @"defaultManager", @"manager", @"currentManager"];
        for (NSString *selName in singletonSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([cls respondsToSelector:sel]) {
                NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
                if (!sig) continue;
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setSelector:sel];
                [inv setTarget:cls];
                [inv invoke];
                id result = nil;
                if (sig.methodReturnLength > 0) {
                    [inv getReturnValue:&result];
                }
                if (result) {
                    DLog(@"Got download manager via %@.%@", className, selName);
                    return result;
                }
            }
        }

        // 尝试 alloc/init
        @try {
            id instance = [[cls alloc] init];
            if (instance) {
                DLog(@"Created download manager instance: %@", className);
                return instance;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

// 获取文件列表的数据源，尝试多种途径
static id getFileListDataSource(UIViewController *vc) {
    if (!vc) return nil;

    // 1. 查找 UITableView / UICollectionView 的数据源
    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);
    if (tableView && tableView.dataSource) return tableView.dataSource;

    UICollectionView *collectionView = (UICollectionView *)findViewRecursively(vc.view, [UICollectionView class]);
    if (collectionView && collectionView.dataSource) return collectionView.dataSource;

    // 2. 尝试从 VC 本身获取
    NSArray *dataSourceKeys = @[@"dataSource", @"viewModel", @"fileViewModel", @"listViewModel", @"_dataSource", @"_viewModel", @"presenter", @"interactor"];
    for (NSString *key in dataSourceKeys) {
        @try {
            id value = [vc valueForKey:key];
            if (value) return value;
        } @catch (NSException *e) {}
    }

    // 3. 尝试从导航栈中的其他 VC 获取
    if (vc.navigationController) {
        for (UIViewController *controller in vc.navigationController.viewControllers) {
            for (NSString *key in dataSourceKeys) {
                @try {
                    id value = [controller valueForKey:key];
                    if (value) return value;
                } @catch (NSException *e) {}
            }
        }
    }

    return nil;
}

// 多维度匹配文件元数据
static BOOL matchFileMeta(id item, NSDictionary *targetMeta) {
    if (!item || !targetMeta) return NO;

    // 优先匹配 fs_id
    NSNumber *targetFsId = targetMeta[@"fs_id"];
    if (targetFsId) {
        @try {
            NSNumber *itemFsId = [item valueForKey:@"fs_id"];
            if (!itemFsId) itemFsId = [item valueForKey:@"_fs_id"];
            if ([itemFsId isEqualToNumber:targetFsId]) return YES;
        } @catch (NSException *e) {}
    }

    // 匹配 path
    NSString *targetPath = targetMeta[@"path"];
    if (targetPath && targetPath.length > 0) {
        @try {
            NSString *itemPath = [item valueForKey:@"path"];
            if (!itemPath) itemPath = [item valueForKey:@"_path"];
            if (!itemPath) itemPath = [item valueForKey:@"filePath"];
            if ([itemPath isEqualToString:targetPath]) return YES;
        } @catch (NSException *e) {}
    }

    // 匹配 server_filename
    NSString *targetName = targetMeta[@"server_filename"];
    if (targetName && targetName.length > 0) {
        @try {
            NSString *itemName = [item valueForKey:@"server_filename"];
            if (!itemName) itemName = [item valueForKey:@"filename"];
            if (!itemName) itemName = [item valueForKey:@"name"];
            if (!itemName) itemName = [item valueForKey:@"_name"];
            if ([itemName isEqualToString:targetName]) return YES;
        } @catch (NSException *e) {}
    }

    return NO;
}

// 模拟触摸事件点击视图
static void simulateTouchOnView(UIView *view) {
    if (!view) return;
    CGPoint center = CGPointMake(view.bounds.size.width / 2, view.bounds.size.height / 2);

    @try {
        UITouch *touch = [[UITouch alloc] init];
        // 使用 KVC 设置私有属性
        [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"];
        [touch setValue:@(0) forKey:@"tapCount"];
        [touch setValue:view forKey:@"view"];
        [touch setValue:[view.window valueForKey:@"window"] ?: view.window forKey:@"window"];

        UIEvent *event = [[UIEvent alloc] init];
        [event setValue:touch forKey:@"_firstTouchForView"];
        [event setValue:touch forKey:@"_allTouches"];

        [view touchesBegan:[NSSet setWithObject:touch] withEvent:event];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"];
            [view touchesEnded:[NSSet setWithObject:touch] withEvent:event];
        });
    } @catch (NSException *e) {
        DLog(@"Touch simulation failed: %@", e.reason);
    }
}

// 通过类清单尝试触发 Cell 的点击动作
static void triggerCellActionByClassList(id cell, NSDictionary *fileMeta) {
    if (!cell) return;

    // 尝试调用 Cell 上的点击方法
    NSArray *cellSelectors = @[
        @"didSelect",
        @"onClick:",
        @"handleTap:",
        @"cellDidClick:",
        @"didTapCell:",
        @"onCellSelected:",
        @"triggerAction:",
        @"performClick",
        @"executeAction"
    ];

    for (NSString *selName in cellSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([cell respondsToSelector:sel]) {
            DLog(@"Calling cell method: %@", selName);
            @try {
                if ([selName hasSuffix:@":"]) {
                    invokeMethod(cell, sel, @[fileMeta]);
                } else {
                    invokeMethod(cell, sel, @[]);
                }
                return;
            } @catch (NSException *e) {
                DLog(@"Cell method %@ failed: %@", selName, e.reason);
            }
        }
    }

    // 尝试查找 Cell 内部的按钮并点击
    if ([cell isKindOfClass:[UIView class]]) {
        UIView *cellView = (UIView *)cell;
        UIButton *button = (UIButton *)findViewRecursively(cellView, [UIButton class]);
        if (button) {
            DLog(@"Found button in cell, simulating touch");
            simulateTouchOnView(button);
            return;
        }

        // 直接模拟点击 Cell 本身
        DLog(@"Simulating touch on cell itself");
        simulateTouchOnView(cellView);
    }
}

// 尝试通过下载管理器直接下载
static void triggerDownloadViaManager(NSDictionary *fileMeta) {
    id manager = getDownloadManagerFromClasses();
    if (!manager) return;

    DLog(@"Trying download manager direct call");

    NSArray *managerSelectors = @[
        @"downloadFile:",
        @"downloadFileWithMeta:",
        @"startDownload:",
        @"addDownloadTask:",
        @"handleDownloadAction:",
        @"onDownloadButtonClick:",
        @"didClickDownload:",
        @"downloadSelectedFile:",
        @"beginDownload:",
        @"queueDownload:",
        @"addToDownloadList:",
        @"createDownloadTask:",
        @"submitDownloadTask:",
        @"enqueueDownload:",
        @"startDownloadFile:",
        @"performDownload:",
        @"triggerDownload:",
        @"executeDownload:",
        @"downloadWithFileInfo:",
        @"addTaskWithFile:",
        @"startTaskWithMeta:"
    ];

    for (NSString *selName in managerSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([manager respondsToSelector:sel]) {
            DLog(@"Calling manager method: %@", selName);
            @try {
                invokeMethod(manager, sel, @[fileMeta]);
                showToast(@"已通过下载管理器触发");
                return;
            } @catch (NSException *e) {
                DLog(@"Manager method %@ failed: %@", selName, e.reason);
            }
        }
    }

    // 尝试用 BBADownloadItem / BBADownloaderTask 创建任务
    Class itemClass = NSClassFromString(@"BBADownloadItem");
    Class taskClass = NSClassFromString(@"BBADownloaderTask");

    if (itemClass) {
        @try {
            id item = [[itemClass alloc] init];
            if (item) {
                [item setValue:fileMeta[@"path"] forKey:@"path"];
                [item setValue:fileMeta[@"server_filename"] forKey:@"fileName"];
                [item setValue:fileMeta[@"fs_id"] forKey:@"fsId"];

                SEL addSel = NSSelectorFromString(@"addDownloadItem:");
                if ([manager respondsToSelector:addSel]) {
                    invokeMethod(manager, addSel, @[item]);
                    showToast(@"已创建下载任务");
                    return;
                }
            }
        } @catch (NSException *e) {
            DLog(@"BBADownloadItem approach failed: %@", e.reason);
        }
    }
}

static void triggerDownloadBySimulatingUserAction(NSDictionary *fileMeta) {
    UIViewController *vc = topViewController();
    if (!vc) {
        showToast(@"无法获取当前页面");
        return;
    }

    DLog(@"Trying to simulate user download action for: %@", fileMeta[@"server_filename"]);

    // ========== 方法1: 深度查找 UITableView 并模拟点击对应行 ==========
    UITableView *tableView = (UITableView *)findViewRecursively(vc.view, [UITableView class]);

    if (tableView) {
        DLog(@"Found tableView via recursive search");
        id dataSource = getFileListDataSource(vc);

        if (dataSource) {
            NSArray *fileList = nil;
            NSArray *listKeys = @[@"fileList", @"dataList", @"list", @"files", @"_fileList", @"_dataList", @"_list", @"fileArray", @"dataArray", @"items"];
            for (NSString *key in listKeys) {
                @try {
                    fileList = [dataSource valueForKey:key];
                    if (fileList && [fileList isKindOfClass:[NSArray class]]) break;
                } @catch (NSException *e) {}
            }

            // 如果数据源没有 list，尝试通过 dataSource 方法获取
            if (!fileList) {
                @try {
                    if ([dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
                        NSInteger count = [dataSource tableView:tableView numberOfRowsInSection:0];
                        NSMutableArray *temp = [NSMutableArray array];
                        for (NSInteger i = 0; i < count; i++) {
                            NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
                            if ([dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) {
                                UITableViewCell *cell = [dataSource tableView:tableView cellForRowAtIndexPath:ip];
                                if (cell) [temp addObject:cell];
                            }
                        }
                        fileList = temp;
                    }
                } @catch (NSException *e) {}
            }

            if (fileList && [fileList isKindOfClass:[NSArray class]]) {
                DLog(@"Found file list with %lu items", (unsigned long)[(NSArray *)fileList count]);

                NSUInteger targetIndex = NSNotFound;

                for (NSUInteger i = 0; i < [(NSArray *)fileList count]; i++) {
                    id item = [(NSArray *)fileList objectAtIndex:i];
                    if (matchFileMeta(item, fileMeta)) {
                        targetIndex = i;
                        break;
                    }
                }

                if (targetIndex != NSNotFound) {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:targetIndex inSection:0];
                    DLog(@"Found target at indexPath: %@", indexPath);

                    // 先尝试滚动到可见区域
                    @try {
                        [tableView scrollToRowAtIndexPath:indexPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                    } @catch (NSException *e) {}

                    // 获取 Cell 并尝试多种点击方式
                    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
                    if (!cell) {
                        @try {
                            cell = [tableView.dataSource tableView:tableView cellForRowAtIndexPath:indexPath];
                        } @catch (NSException *e) {}
                    }

                    if (cell) {
                        triggerCellActionByClassList(cell, fileMeta);
                        showToast(@"已模拟点击文件");
                        return;
                    }

                    // 回退到标准 delegate 方法
                    id delegate = tableView.delegate;
                    if (delegate && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        DLog(@"Calling delegate tableView:didSelectRowAtIndexPath:");
                        @try {
                            invokeMethod(delegate, @selector(tableView:didSelectRowAtIndexPath:), @[tableView, indexPath]);
                            showToast(@"已模拟点击文件");
                            return;
                        } @catch (NSException *e) {
                            DLog(@"Delegate method failed: %@", e.reason);
                        }
                    }

                    if ([vc respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                        DLog(@"Calling VC tableView:didSelectRowAtIndexPath:");
                        @try {
                            invokeMethod(vc, @selector(tableView:didSelectRowAtIndexPath:), @[tableView, indexPath]);
                            showToast(@"已模拟点击文件");
                            return;
                        } @catch (NSException *e) {
                            DLog(@"VC method failed: %@", e.reason);
                        }
                    }
                } else {
                    DLog(@"Target file not found in list");
                }
            }
        }
    }

    // ========== 方法1b: 深度查找 UICollectionView ==========
    UICollectionView *collectionView = (UICollectionView *)findViewRecursively(vc.view, [UICollectionView class]);
    if (collectionView) {
        DLog(@"Found collectionView via recursive search");
        id dataSource = collectionView.dataSource;

        if (dataSource && [dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
            NSInteger count = [dataSource collectionView:collectionView numberOfItemsInSection:0];
            for (NSInteger i = 0; i < count; i++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForItem:i inSection:0];
                @try {
                    UICollectionViewCell *cell = [dataSource collectionView:collectionView cellForItemAtIndexPath:indexPath];
                    if (cell) {
                        id item = [cell valueForKey:@"fileMeta"];
                        if (!item) item = [cell valueForKey:@"model"];
                        if (!item) item = [cell valueForKey:@"data"];
                        if (matchFileMeta(item ?: cell, fileMeta)) {
                            DLog(@"Found target in collectionView at indexPath: %@", indexPath);

                            id delegate = collectionView.delegate;
                            if (delegate && [delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
                                @try {
                                    invokeMethod(delegate, @selector(collectionView:didSelectItemAtIndexPath:), @[collectionView, indexPath]);
                                    showToast(@"已模拟点击文件");
                                    return;
                                } @catch (NSException *e) {}
                            }

                            triggerCellActionByClassList(cell, fileMeta);
                            showToast(@"已模拟点击文件");
                            return;
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }

    // ========== 方法2: 尝试直接调用 VC 的下载方法 ==========
    NSArray *vcSelectors = @[
        @"downloadFile:", @"downloadFileWithMeta:", @"startDownload:", @"addDownloadTask:",
        @"handleDownloadAction:", @"onDownloadButtonClick:", @"didClickDownload:",
        @"downloadSelectedFile:", @"beginDownload:", @"queueDownload:",
        @"addToDownloadList:", @"createDownloadTask:", @"submitDownloadTask:",
        @"enqueueDownload:", @"startDownloadFile:", @"performDownload:",
        @"triggerDownload:", @"executeDownload:", @"onDownloadFile:",
        @"handleFileDownload:", @"processDownload:", @"initiateDownload:"
    ];

    for (NSString *selName in vcSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([vc respondsToSelector:sel]) {
            DLog(@"Calling VC method: %@", selName);
            @try {
                invokeMethod(vc, sel, @[fileMeta]);
                showToast(@"已触发下载");
                return;
            } @catch (NSException *e) {
                DLog(@"VC method %@ failed: %@", selName, e.reason);
            }
        }
    }

    // ========== 方法3: 尝试 navigationController 的 viewControllers ==========
    if (vc.navigationController) {
        for (UIViewController *controller in vc.navigationController.viewControllers) {
            for (NSString *selName in vcSelectors) {
                SEL sel = NSSelectorFromString(selName);
                if ([controller respondsToSelector:sel]) {
                    DLog(@"Calling stack VC method: %@ on %@", selName, NSStringFromClass([controller class]));
                    @try {
                        invokeMethod(controller, sel, @[fileMeta]);
                        showToast(@"已触发下载");
                        return;
                    } @catch (NSException *e) {
                        DLog(@"Stack VC method failed: %@", e.reason);
                    }
                }
            }

            // 尝试从导航栈中的 VC 获取 TableView
            UITableView *stackTV = (UITableView *)findViewRecursively(controller.view, [UITableView class]);
            if (stackTV) {
                id ds = getFileListDataSource(controller);
                if (ds) {
                    NSArray *list = nil;
                    @try { list = [ds valueForKey:@"fileList"]; } @catch (NSException *e) {}
                    if (!list) @try { list = [ds valueForKey:@"list"]; } @catch (NSException *e) {}

                    if (list) {
                        for (NSUInteger i = 0; i < [list count]; i++) {
                            if (matchFileMeta(list[i], fileMeta)) {
                                NSIndexPath *ip = [NSIndexPath indexPathForRow:i inSection:0];
                                id del = stackTV.delegate;
                                if (del && [del respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
                                    @try {
                                        invokeMethod(del, @selector(tableView:didSelectRowAtIndexPath:), @[stackTV, ip]);
                                        showToast(@"已触发下载");
                                        return;
                                    } @catch (NSException *e) {}
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ========== 方法4: 尝试 AppDelegate ==========
    id appDelegate = [[UIApplication sharedApplication] delegate];
    if (appDelegate) {
        for (NSString *selName in vcSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([appDelegate respondsToSelector:sel]) {
                DLog(@"Calling AppDelegate method: %@", selName);
                @try {
                    invokeMethod(appDelegate, sel, @[fileMeta]);
                    showToast(@"已触发下载");
                    return;
                } @catch (NSException *e) {
                    DLog(@"AppDelegate method failed: %@", e.reason);
                }
            }
        }
    }

    // ========== 方法5: 尝试通过下载管理器直接下载 ==========
    triggerDownloadViaManager(fileMeta);

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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v10.0"
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
    DLog(@"BaiduPan Troll v10.0 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
