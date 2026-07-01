//
//  BaiduPan SVIP Direct Link Helper - TrollStore Edition v10.35
//  精简版：核心功能 only
//  Flow: select -> rename -> refresh x2 -> find & click -> scroll find & click -> restore if not found
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *gCurrentPath = nil;
static NSString *gBdstoken = nil;
static NSString *gBDUSS = nil;
static UIButton *gFloatButton = nil;
static NSString *gPendingRestoreFileId = nil;
static NSString *gPendingRestorePdfPath = nil;
static NSString *gPendingRestoreOriginalName = nil;

static UIViewController * topViewController(void);
static void autoDetectPathAndToken(void);
static void fetchFileList(void (^completion)(NSArray *files, NSError *err));
static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err));
static void executeRestoreWithoutRefresh(void (^completion)(BOOL success));
static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize);
static void triggerDownloadFlow(void);
static void onFloatButtonTap(void);
static void showFloatButton(void);

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
                    if (str.length == 16 && !bestToken) bestToken = str;
                }
            }
        }
    }
    return bestToken;
}

static NSString * extractPathFromVC(UIViewController *vc) {
    if (!vc) return nil;
    NSArray *pathKeys = @[@"path", @"currentPath", @"filePath", @"dirPath", @"currentDir",
                          @"_path", @"_currentPath", @"directory", @"folderPath", @"currentFolder",
                          @"mPath", @"_mPath", @"fileListPath", @"currentDirectory", @"directoryPath",
                          @"currentDirPath", @"_directory", @"_dirPath"];
    for (NSString *key in pathKeys) {
        @try {
            id value = [vc valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                NSString *path = (NSString *)value;
                if (![path hasPrefix:@"/"]) path = [@"/" stringByAppendingString:path];
                return path;
            }
        } @catch (NSException *e) {}
    }
    return nil;
}

static NSString * buildPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;
    NSString *path = extractPathFromVC(vc);
    if (path && path.length > 0 && ![path isEqualToString:@"/"]) return path;
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else if (vc.navigationController) {
        nav = vc.navigationController;
    }
    if (nav) {
        UIViewController *topVC = nav.topViewController;
        NSString *topPath = extractPathFromVC(topVC);
        if (topPath && topPath.length > 0 && ![topPath isEqualToString:@"/"]) return topPath;
        NSArray *vcs = nav.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            NSString *p = extractPathFromVC(vcs[i]);
            if (p && p.length > 0 && ![p isEqualToString:@"/"]) return p;
        }
        NSMutableArray *components = [NSMutableArray array];
        for (UIViewController *controller in vcs) {
            NSString *title = controller.title;
            if (!title || title.length == 0) title = controller.navigationItem.title;
            if (title && title.length > 0
                && ![title isEqualToString:@"百度网盘"]
                && ![title isEqualToString:@"文件"]
                && ![title isEqualToString:@"首页"]) {
                if (components.count == 0 || ![components.lastObject isEqualToString:title]) {
                    [components addObject:title];
                }
            }
        }
        if (components.count > 0) {
            NSString *fullPath = [components componentsJoinedByString:@"/"];
            if (![fullPath hasPrefix:@"/"]) fullPath = [@"/" stringByAppendingString:fullPath];
            return fullPath;
        }
    }
    return nil;
}

static void autoDetectPathAndToken(void) {
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
    gCurrentPath = buildPathFromNavStack();
    if (!gCurrentPath) gCurrentPath = @"/";
}

static void fetchFileList(void (^completion)(NSArray *files, NSError *err)) {
    if (!gBdstoken) {
        completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
        return;
    }
    NSString *encodedPath = strictEncodeURIComponent(gCurrentPath ?: @"/");
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?dir=%@&bdstoken=%@&order=time&desc=1&showempty=0&web=1&page=1&num=100&app_id=250528", encodedPath, gBdstoken];
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSNumber *errnoNum = json[@"errno"];
        if (errnoNum && [errnoNum integerValue] != 0) {
            NSString *errMsg = json[@"errmsg"] ?: [NSString stringWithFormat:@"API errno=%@", errnoNum];
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: errMsg}]);
            return;
        }
        NSArray *list = json[@"list"];
        if (![list isKindOfClass:[NSArray class]]) {
            completion(nil, [NSError errorWithDomain:@"BaiduPanTroll" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            return;
        }
        completion(list, nil);
    });
}

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    if (!gBdstoken) {
        completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"No token"}]);
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
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"Unknown";
            completion(NO, [NSError errorWithDomain:@"BaiduPanTroll" code:[errnoNum integerValue] userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static UIScrollView * findListViewInHierarchy(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UITableView class]] || [root isKindOfClass:[UICollectionView class]]) {
        return (UIScrollView *)root;
    }
    for (UIView *sub in root.subviews) {
        UIScrollView *found = findListViewInHierarchy(sub);
        if (found) return found;
    }
    return nil;
}

static UIScrollView * findListViewGlobally(void) {
    UIViewController *vc = topViewController();
    if (vc) {
        UIScrollView *found = findListViewInHierarchy(vc.view);
        if (found) return found;
    }
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        UIScrollView *found = findListViewInHierarchy(window);
        if (found) return found;
    }
    return nil;
}

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
                if (!cell) continue;
                if (viewContainsText(cell, targetName)) return ip;
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

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
                if (!cell) continue;
                if (viewContainsText(cell, targetName)) return ip;
            } @catch (NSException *e) {}
        }
    }
    return nil;
}

static NSIndexPath * searchInListView(NSString *targetName, UIScrollView *listView) {
    if (!targetName || !listView) return nil;
    if ([listView isKindOfClass:[UITableView class]]) {
        return searchFileInTableView(targetName, (UITableView *)listView);
    } else if ([listView isKindOfClass:[UICollectionView class]]) {
        return searchFileInCollectionView(targetName, (UICollectionView *)listView);
    }
    return nil;
}

static void simulateTouchOnCell(UIView *cell) {
    if (!cell) return;
    if ([cell isKindOfClass:[UIControl class]]) {
        [(UIControl *)cell sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
    for (UIView *sub in cell.subviews) {
        if ([sub isKindOfClass:[UIButton class]]) {
            [(UIButton *)sub sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    }
}

static void executeRestoreWithoutRefresh(void (^completion)(BOOL success)) {
    if (!gPendingRestoreFileId || !gPendingRestorePdfPath || !gPendingRestoreOriginalName) {
        if (completion) completion(NO);
        return;
    }
    renameFile(gPendingRestoreFileId, gPendingRestorePdfPath, gPendingRestoreOriginalName, ^(BOOL ok, NSError *e) {
        gPendingRestoreFileId = nil;
        gPendingRestorePdfPath = nil;
        gPendingRestoreOriginalName = nil;
        if (completion) completion(ok);
    });
}

static void clickCell(NSString *ppName, UIScrollView *listView, NSIndexPath *foundPath) {
    executeRestoreWithoutRefresh(^(BOOL success) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id delegate = nil;
            if ([listView isKindOfClass:[UITableView class]]) {
                delegate = [(UITableView *)listView delegate];
                SEL didSelect = @selector(tableView:didSelectRowAtIndexPath:);
                if (delegate && [delegate respondsToSelector:didSelect]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [delegate performSelector:didSelect withObject:listView withObject:foundPath];
                    #pragma clang diagnostic pop
                }
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                delegate = [(UICollectionView *)listView delegate];
                SEL didSelect = @selector(collectionView:didSelectItemAtIndexPath:);
                if (delegate && [delegate respondsToSelector:didSelect]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [delegate performSelector:didSelect withObject:listView withObject:foundPath];
                    #pragma clang diagnostic pop
                }
            }

            UIView *cell = nil;
            if ([listView isKindOfClass:[UITableView class]]) {
                cell = [(UITableView *)listView cellForRowAtIndexPath:foundPath];
            } else if ([listView isKindOfClass:[UICollectionView class]]) {
                cell = [(UICollectionView *)listView cellForItemAtIndexPath:foundPath];
            }
            if (cell) simulateTouchOnCell(cell);
        });
    });
}

static void performScrollAttempt(NSString *ppName, UIScrollView *listView, NSInteger attempt, NSInteger maxAttempts, CGFloat scrollStep) {
    if (attempt >= maxAttempts) {
        executeRestoreWithoutRefresh(nil);
        return;
    }

    CGFloat currentY = listView.contentOffset.y;
    CGFloat targetY = currentY + scrollStep;
    CGFloat maxY = listView.contentSize.height - listView.bounds.size.height;
    if (maxY < 0) maxY = 0;
    if (targetY > maxY) targetY = maxY;

    if (targetY <= currentY && attempt > 0) {
        executeRestoreWithoutRefresh(nil);
        return;
    }

    listView.contentOffset = CGPointMake(0, targetY);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSIndexPath *foundPath = searchInListView(ppName, listView);
        if (foundPath) {
            clickCell(ppName, listView, foundPath);
            return;
        }

        if (targetY >= maxY && maxY >= 0) {
            executeRestoreWithoutRefresh(nil);
            return;
        }

        performScrollAttempt(ppName, listView, attempt + 1, maxAttempts, scrollStep);
    });
}

static void scrollToRenamedFileAndAutoClick(NSString *ppName) {
    if (!ppName) return;

    UIScrollView *listView = findListViewGlobally();
    if (!listView) {
        executeRestoreWithoutRefresh(nil);
        return;
    }

    NSIndexPath *foundPath = searchInListView(ppName, listView);
    if (foundPath) {
        if ([listView isKindOfClass:[UITableView class]]) {
            [(UITableView *)listView scrollToRowAtIndexPath:foundPath atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)listView scrollToItemAtIndexPath:foundPath atScrollPosition:UICollectionViewScrollPositionCenteredVertically animated:NO];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            clickCell(ppName, listView, foundPath);
        });
        return;
    }

    listView.contentOffset = CGPointZero;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGFloat scrollStep = listView.bounds.size.height * 0.7;
        if (scrollStep < 100) scrollStep = 100;
        performScrollAttempt(ppName, listView, 0, 15, scrollStep);
    });
}

static void forceRefreshFileList(void) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    UIScrollView *listView = findListViewInHierarchy(vc.view);
    if (!listView) {
        for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
            listView = findListViewInHierarchy(window);
            if (listView) break;
        }
    }
    if (listView) {
        if ([listView isKindOfClass:[UITableView class]]) {
            [(UITableView *)listView reloadData];
        } else if ([listView isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)listView reloadData];
        }
        if (listView.refreshControl) {
            [listView.refreshControl beginRefreshing];
            listView.contentOffset = CGPointMake(listView.contentOffset.x, -listView.refreshControl.frame.size.height);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [listView.refreshControl endRefreshing];
            });
        }
    }
}

static void runSmartFlow(NSString *fileName, NSString *filePath, NSString *fileId, NSNumber *fileSize) {
    gPendingRestoreFileId = nil;
    gPendingRestorePdfPath = nil;
    gPendingRestoreOriginalName = nil;

    NSString *ext = fileName.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"88888888888888"]) return;

    NSString *ppName = [fileName stringByAppendingString:@".8888888888888888"];
    NSString *ppPath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:ppName];

    renameFile(fileId, filePath, ppName, ^(BOOL success, NSError *err) {
        if (!success) return;

        gPendingRestoreFileId = fileId;
        gPendingRestorePdfPath = ppPath;
        gPendingRestoreOriginalName = fileName;

        forceRefreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            forceRefreshFileList();

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                scrollToRenamedFileAndAutoClick(ppName);
            });
        });
    });
}

static void triggerDownloadFlow(void) {
    autoDetectPathAndToken();
    if (!gBdstoken) return;
    fetchFileList(^(NSArray *files, NSError *err) {
        if (err || !files || files.count == 0) return;
        NSMutableArray *fileItems = [NSMutableArray array];
        for (NSDictionary *file in files) {
            NSNumber *isdir = file[@"isdir"];
            if (!isdir || [isdir integerValue] == 0) [fileItems addObject:file];
        }
        if (fileItems.count == 0) return;
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择文件"
                                                                       message:nil
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
                runSmartFlow(name, path, fid, size);
            }];
            if (isTooLarge) [action setValue:@NO forKey:@"enabled"];
            [sheet addAction:action];
        }
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                               style:UIAlertActionStyleCancel
                                                             handler:nil];
        [sheet addAction:cancelAction];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = topViewController();
            if (vc) {
                if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                    sheet.popoverPresentationController.sourceView = vc.view;
                    sheet.popoverPresentationController.sourceRect = CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height / 2, 1, 1);
                }
                [vc presentViewController:sheet animated:YES completion:nil];
            }
        });
    });
}

static void onFloatButtonTap(void) {
    autoDetectPathAndToken();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BaiduPan Troll v10.35"
                                                                   message:@"选择文件开始下载"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"选择文件"
                                                             style:UIAlertActionStyleDefault
                                                           handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            triggerDownloadFlow();
        });
    }];
    [alert addAction:downloadAction];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleCancel
                                                     handler:nil];
    [alert addAction:okAction];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        showFloatButton();
        autoDetectPathAndToken();
    });
}
