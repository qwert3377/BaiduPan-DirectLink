//
//  Tweak.xm
//  BaiduPanTroll - TrollStore Edition v11.3
//  增强探测版：覆盖 TableView/CollectionView/UIView 多级 Hook
//  使用 Method Swizzling 替代 %hook，无 libsubstrate 依赖
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==================== 全局配置 ====================
static NSString *const kRenameSuffix = @".88888888888888";
static NSString *const kKeyPendingFileId = @"BNDP_Pending_FileId";
static NSString *const kKeyPendingPath = @"BNDP_Pending_Path";
static NSString *const kKeyPendingOriginalName = @"BNDP_Pending_OriginalName";
static NSString *const kKeyPendingTimestamp = @"BNDP_Pending_Timestamp";
static NSString *const kKeyLastFileId = @"BNDP_Last_FileId";
static NSString *const kKeyLastPath = @"BNDP_Last_Path";
static NSString *const kKeyLastOriginalName = @"BNDP_Last_OriginalName";

static BOOL g_autoProcessEnabled = YES;
static BOOL g_isProcessing = NO;

// ==================== Method Swizzling 工具 ====================
static void swizzleMethod(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, swizzledSelector);
    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

static void swizzleClassMethod(Class cls, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getClassMethod(cls, originalSelector);
    Method swizzledMethod = class_getClassMethod(cls, swizzledSelector);
    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

// ==================== 辅助函数：获取当前文件列表 VC ====================
static UIViewController* getCurrentFileListVC(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = [app keyWindow];
    if (!window) window = [[app windows] firstObject];
    UIViewController *rootVC = [window rootViewController];
    UIViewController *targetVC = nil;
    if ([rootVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)rootVC;
        NSArray *vcs = [nav viewControllers];
        for (UIViewController *vc in vcs) {
            NSString *className = NSStringFromClass([vc class]);
            if ([className containsString:@"FileList"] || [className containsString:@"FileView"] ||
                [className containsString:@"BDFile"] || [className containsString:@"PanFile"] ||
                [className containsString:@"Disk"] || [className containsString:@"Home"]) {
                targetVC = vc;
                break;
            }
        }
        if (!targetVC && [vcs count] > 0) {
            targetVC = [vcs lastObject];
        }
    } else if ([rootVC isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)rootVC;
        UIViewController *selected = [tab selectedViewController];
        if ([selected isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)selected;
            NSArray *vcs = [nav viewControllers];
            for (UIViewController *vc in vcs) {
                NSString *className = NSStringFromClass([vc class]);
                if ([className containsString:@"FileList"] || [className containsString:@"FileView"] ||
                    [className containsString:@"BDFile"] || [className containsString:@"PanFile"] ||
                    [className containsString:@"Disk"] || [className containsString:@"Home"]) {
                    targetVC = vc;
                    break;
                }
            }
            if (!targetVC && [vcs count] > 0) {
                targetVC = [vcs lastObject];
            }
        }
    }
    return targetVC;
}

// ==================== 辅助函数：刷新文件列表 ====================
static void refreshFileList(void) {
    UIViewController *vc = getCurrentFileListVC();
    if (!vc) return;

    SEL refreshSelectors[] = {
        NSSelectorFromString(@"reloadFileList"),
        NSSelectorFromString(@"refreshData"),
        NSSelectorFromString(@"loadData"),
        NSSelectorFromString(@"fetchFileList"),
        NSSelectorFromString(@"refreshFileList"),
        NSSelectorFromString(@"pullToRefresh"),
        NSSelectorFromString(@"onRefresh"),
        NSSelectorFromString(@"reloadData"),
        NSSelectorFromString(@"refresh"),
        NSSelectorFromString(@"requestData"),
        NSSelectorFromString(@"loadFileList"),
        (SEL)0
    };

    for (int i = 0; refreshSelectors[i] != (SEL)0; i++) {
        SEL sel = refreshSelectors[i];
        if ([vc respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            return;
        }
    }

    NSArray *subviews = [vc.view subviews];
    NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
    while ([queue count] > 0) {
        UIView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UITableView class]]) {
            [(UITableView *)view reloadData];
            return;
        }
        if ([view isKindOfClass:[UICollectionView class]]) {
            [(UICollectionView *)view reloadData];
            return;
        }
        [queue addObjectsFromArray:[view subviews]];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_RefreshFileList"
                                                        object:nil
                                                      userInfo:nil];
}

// ==================== 辅助函数：获取 bdstoken ====================
static NSString* getBdstoken(void) {
    NSString *bdstoken = nil;
    @try {
        bdstoken = [[NSUserDefaults standardUserDefaults] objectForKey:@"bdstoken"];
    } @catch (NSException *e) {}
    if (!bdstoken) {
        @try {
            id appDelegate = [[UIApplication sharedApplication] delegate];
            bdstoken = [appDelegate valueForKey:@"bdstoken"];
        } @catch (NSException *e) {}
    }
    if (!bdstoken) {
        @try {
            id appDelegate = [[UIApplication sharedApplication] delegate];
            bdstoken = [appDelegate valueForKey:@"_bdstoken"];
        } @catch (NSException *e) {}
    }
    return bdstoken;
}

static void renameFileAPI(NSString *path, NSString *originalName, void (^completion)(BOOL success, NSString *newPath)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken || !path || !originalName) {
        if (completion) completion(NO, nil);
        return;
    }
    NSString *newName = [originalName stringByAppendingString:kRenameSuffix];
    NSString *newPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];
    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@&channel=chunlei&web=1&app_id=250528&clienttype=0", bdstoken];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *filelistStr = [NSString stringWithFormat:@"[{\"path\":\"%@\",\"newname\":\"%@\"}]",
                              [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                              [newName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://pan.baidu.com/disk/main" forHTTPHeaderField:@"Referer"];
    NSString *bodyString = [NSString stringWithFormat:@"filelist=%@",
                            [filelistStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    [request setHTTPBody:[bodyString dataUsingEncoding:NSUTF8StringEncoding]];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (completion) completion(NO, nil);
                return;
            }
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger errno_val = [[json objectForKey:@"errno"] integerValue];
                if (errno_val == 0) {
                    if (completion) completion(YES, newPath);
                } else {
                    if (completion) completion(NO, nil);
                }
            } @catch (NSException *e) {
                if (completion) completion(NO, nil);
            }
        });
    }];
    [task resume];
}

static void restoreFileNameAPI(NSString *path, NSString *originalName) {
    if (!path || !originalName) return;
    NSString *bdstoken = getBdstoken();
    if (!bdstoken) return;
    NSString *renamedPath = [path stringByAppendingString:kRenameSuffix];
    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@&channel=chunlei&web=1&app_id=250528&clienttype=0", bdstoken];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSString *filelistStr = [NSString stringWithFormat:@"[{\"path\":\"%@\",\"newname\":\"%@\"}]",
                              [renamedPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                              [originalName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://pan.baidu.com/disk/main" forHTTPHeaderField:@"Referer"];
    NSString *bodyString = [NSString stringWithFormat:@"filelist=%@",
                            [filelistStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    [request setHTTPBody:[bodyString dataUsingEncoding:NSUTF8StringEncoding]];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // silent
    }];
    [task resume];
}

static void fetchDownloadLinkAPI(NSString *fileId, NSString *path, void (^completion)(NSString *dlink)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken || !fileId) {
        if (completion) completion(nil);
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/rest/2.0/xpan/multimedia?method=filemetas&access_token=%@&fsids=[%@]&dlink=1", bdstoken, fileId];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"https://pan.baidu.com" forHTTPHeaderField:@"Referer"];
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (completion) completion(nil);
                return;
            }
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *list = [json objectForKey:@"list"];
                if ([list count] > 0) {
                    NSDictionary *fileInfo = [list objectAtIndex:0];
                    NSString *dlink = [fileInfo objectForKey:@"dlink"];
                    if (dlink) {
                        if (completion) completion(dlink);
                        return;
                    }
                }
            } @catch (NSException *e) {}
            if (completion) completion(nil);
        });
    }];
    [task resume];
}

static void openFileViaMessage(NSString *fileId, NSString *path) {
    if (!fileId || !path) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *targetVC = getCurrentFileListVC();
        if (targetVC) {
            SEL selectors[] = {
                NSSelectorFromString(@"openFileWithId:"),
                NSSelectorFromString(@"openFileWithId:path:"),
                NSSelectorFromString(@"previewFileWithId:"),
                NSSelectorFromString(@"showFileDetail:"),
                NSSelectorFromString(@"didSelectFile:"),
                NSSelectorFromString(@"selectFileAtIndexPath:"),
                NSSelectorFromString(@"onFileSelected:"),
                NSSelectorFromString(@"handleFileTap:"),
                NSSelectorFromString(@"openFile:"),
                NSSelectorFromString(@"previewDocument:"),
                NSSelectorFromString(@"openDocument:"),
                NSSelectorFromString(@"previewFile:"),
                NSSelectorFromString(@"tapFile:"),
                NSSelectorFromString(@"clickFile:"),
                (SEL)0
            };
            for (int i = 0; selectors[i] != (SEL)0; i++) {
                SEL sel = selectors[i];
                if ([targetVC respondsToSelector:sel]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    NSMethodSignature *sig = [targetVC methodSignatureForSelector:sel];
                    if (sig) {
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        [inv setSelector:sel];
                        [inv setTarget:targetVC];
                        NSUInteger numArgs = [sig numberOfArguments];
                        if (numArgs >= 3) {
                            NSString *arg1 = fileId;
                            [inv setArgument:&arg1 atIndex:2];
                        }
                        if (numArgs >= 4) {
                            NSString *arg2 = path;
                            [inv setArgument:&arg2 atIndex:3];
                        }
                        [inv invoke];
                    }
                    #pragma clang diagnostic pop
                    return;
                }
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_OpenFileRequest"
                                                            object:nil
                                                          userInfo:@{@"fileId": fileId, @"path": path}];
    });
}

static void saveProcessingRecord(NSString *fileId, NSString *path, NSString *originalName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:fileId forKey:kKeyLastFileId];
    [defaults setObject:path forKey:kKeyLastPath];
    [defaults setObject:originalName forKey:kKeyLastOriginalName];
    [defaults synchronize];
}

static void savePendingRestore(NSString *fileId, NSString *path, NSString *originalName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:fileId forKey:kKeyPendingFileId];
    [defaults setObject:path forKey:kKeyPendingPath];
    [defaults setObject:originalName forKey:kKeyPendingOriginalName];
    [defaults setObject:@([[NSDate date] timeIntervalSince1970]) forKey:kKeyPendingTimestamp];
    [defaults synchronize];
}

static void checkAndRestorePending(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *fileId = [defaults objectForKey:kKeyPendingFileId];
    NSString *path = [defaults objectForKey:kKeyPendingPath];
    NSString *originalName = [defaults objectForKey:kKeyPendingOriginalName];
    NSNumber *timestamp = [defaults objectForKey:kKeyPendingTimestamp];
    if (!fileId || !path || !originalName) return;
    if (timestamp) {
        NSTimeInterval savedTime = [timestamp doubleValue];
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        if (currentTime - savedTime > 300) {
            restoreFileNameAPI(path, originalName);
            [defaults removeObjectForKey:kKeyPendingFileId];
            [defaults removeObjectForKey:kKeyPendingPath];
            [defaults removeObjectForKey:kKeyPendingOriginalName];
            [defaults removeObjectForKey:kKeyPendingTimestamp];
            [defaults synchronize];
            return;
        }
    }
    UIViewController *vc = getCurrentFileListVC();
    BOOL inFileList = NO;
    if (vc) {
        NSString *className = NSStringFromClass([vc class]);
        if ([className containsString:@"FileList"] || [className containsString:@"FileView"] ||
            [className containsString:@"Home"] || [className containsString:@"Main"] ||
            [className containsString:@"Disk"]) {
            inFileList = YES;
        }
    }
    if (inFileList) {
        restoreFileNameAPI(path, originalName);
        [defaults removeObjectForKey:kKeyPendingFileId];
        [defaults removeObjectForKey:kKeyPendingPath];
        [defaults removeObjectForKey:kKeyPendingOriginalName];
        [defaults removeObjectForKey:kKeyPendingTimestamp];
        [defaults synchronize];
    }
}

static void extractFileInfoFromCell(UIView *cell, NSString **outFileId, NSString **outPath, NSString **outName) {
    *outFileId = nil;
    *outPath = nil;
    *outName = nil;
    @try {
        id fileInfo = [cell valueForKey:@"_fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"_data"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"data"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"_fileData"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"fileData"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"_item"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"item"];
        if (fileInfo) {
            *outFileId = [fileInfo valueForKey:@"fid"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"fileId"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"id"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"fs_id"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"fsid"];
            *outPath = [fileInfo valueForKey:@"path"];
            *outName = [fileInfo valueForKey:@"name"];
            if (!*outName) *outName = [fileInfo valueForKey:@"server_filename"];
            if (!*outName) *outName = [fileInfo valueForKey:@"filename"];
        }
    } @catch (NSException *e) {}
    if (!*outName) {
        @try {
            NSArray *subviews = [cell subviews];
            NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
            while ([queue count] > 0) {
                UIView *view = [queue objectAtIndex:0];
                [queue removeObjectAtIndex:0];
                if ([view isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)view;
                    if (label.text && [label.text length] > 0 && ![label.text isEqualToString:@" "]) {
                        *outName = label.text;
                        break;
                    }
                }
                [queue addObjectsFromArray:[view subviews]];
            }
        } @catch (NSException *e) {}
    }
}

static void processBackstage(NSString *fileId, NSString *path, NSString *originalName) {
    if (g_isProcessing) return;
    if (!fileId || !path || !originalName) return;
    g_isProcessing = YES;
    saveProcessingRecord(fileId, path, originalName);

    renameFileAPI(path, originalName, ^(BOOL success, NSString *newPath) {
        if (!success) {
            g_isProcessing = NO;
            return;
        }

        refreshFileList();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            openFileViaMessage(fileId, newPath ?: path);
        });

        savePendingRestore(fileId, path, originalName);

        fetchDownloadLinkAPI(fileId, path, ^(NSString *dlink) {
            if (dlink) {
                [[UIPasteboard generalPasteboard] setString:dlink];
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"下载直链已复制"
                                                                    message:dlink
                                                                   delegate:nil
                                                          cancelButtonTitle:@"确定"
                                                          otherButtonTitles:nil];
                    [alert show];
                });
            }
        });

        g_isProcessing = NO;
    });
}

// ==================== 核心：尝试从任意 View 提取文件信息并处理 ====================
static void tryProcessView(UIView *view) {
    if (!g_autoProcessEnabled) return;
    if (!view) return;

    // 向上查找 cell
    UIView *cell = view;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]] && ![cell isKindOfClass:[UICollectionViewCell class]]) {
        cell = [cell superview];
        if (!cell) return;
    }
    if (!cell) return;

    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;
    extractFileInfoFromCell(cell, &fileId, &path, &originalName);

    if (fileId && path && originalName) {
        processBackstage(fileId, path, originalName);
    }
}

// ==================== 悬浮球 ====================
@interface BNDPFloatingBall : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation BNDPFloatingBall

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        self.layer.shadowOpacity = 0.3;
        self.titleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        self.titleLabel.text = @"BD";
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [self addSubview:self.titleLabel];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:longPress];
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        [singleTap requireGestureRecognizerToFail:doubleTap];
        [self addGestureRecognizer:singleTap];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    g_autoProcessEnabled = !g_autoProcessEnabled;
    self.titleLabel.text = g_autoProcessEnabled ? @"BD" : @"OFF";
    self.backgroundColor = g_autoProcessEnabled ? [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9] : [UIColor grayColor];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *lastFileId = [defaults objectForKey:kKeyLastFileId];
    NSString *lastPath = [defaults objectForKey:kKeyLastPath];
    NSString *lastOriginalName = [defaults objectForKey:kKeyLastOriginalName];
    if (lastFileId && lastPath && lastOriginalName) {
        restoreFileNameAPI(lastPath, lastOriginalName);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            processBackstage(lastFileId, lastPath, lastOriginalName);
        });
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"百度网盘插件"
                                                        message:[NSString stringWithFormat:@"自动处理: %@\n点击文件后自动重命名并打开", g_autoProcessEnabled ? @"开启" : @"关闭"]
                                                       delegate:nil
                                              cancelButtonTitle:@"确定"
                                              otherButtonTitles:nil];
        [alert show];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint newCenter = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
        CGFloat margin = self.frame.size.width / 2;
        newCenter.x = MAX(margin, MIN(self.superview.frame.size.width - margin, newCenter.x));
        newCenter.y = MAX(margin, MIN(self.superview.frame.size.height - margin, newCenter.y));
        self.center = newCenter;
        [gesture setTranslation:CGPointZero inView:self.superview];
    }
}

@end

// ==================== Hook 1: UITableView delegate ====================
@interface UITableView (BNDP)
- (void)bndp_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation UITableView (BNDP)

- (void)bndp_tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!g_autoProcessEnabled) {
        [self bndp_tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        [self bndp_tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;
    extractFileInfoFromCell(cell, &fileId, &path, &originalName);
    if (!fileId || !path || !originalName) {
        [self bndp_tableView:tableView didSelectRowAtIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    processBackstage(fileId, path, originalName);
}

@end

// ==================== Hook 2: UICollectionView delegate ====================
@interface UICollectionView (BNDP)
- (void)bndp_collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath;
@end

@implementation UICollectionView (BNDP)

- (void)bndp_collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (!g_autoProcessEnabled) {
        [self bndp_collectionView:collectionView didSelectItemAtIndexPath:indexPath];
        return;
    }
    UICollectionViewCell *cell = [collectionView cellForItemAtIndexPath:indexPath];
    if (!cell) {
        [self bndp_collectionView:collectionView didSelectItemAtIndexPath:indexPath];
        return;
    }
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;
    extractFileInfoFromCell(cell, &fileId, &path, &originalName);
    if (!fileId || !path || !originalName) {
        [self bndp_collectionView:collectionView didSelectItemAtIndexPath:indexPath];
        return;
    }
    processBackstage(fileId, path, originalName);
}

@end

// ==================== Hook 3: UIView touchesBegan（最底层拦截）====================
@interface UIView (BNDP)
- (void)bndp_touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event;
- (void)bndp_touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event;
@end

@implementation UIView (BNDP)

- (void)bndp_touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    tryProcessView(self);
    [self bndp_touchesBegan:touches withEvent:event];
}

- (void)bndp_touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    tryProcessView(self);
    [self bndp_touchesEnded:touches withEvent:event];
}

@end

// ==================== Hook 4: UIControl sendAction（按钮点击）====================
@interface UIControl (BNDP)
- (void)bndp_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event;
@end

@implementation UIControl (BNDP)

- (void)bndp_sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    tryProcessView(self);
    [self bndp_sendAction:action to:target forEvent:event];
}

@end

// ==================== Hook 5: NSURLSession 下载拦截 ====================
@interface NSURLSession (BNDP)
- (NSURLSessionDataTask *)bndp_dataTaskWithRequest:(NSURLRequest *)request;
@end

@implementation NSURLSession (BNDP)

- (NSURLSessionDataTask *)bndp_dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    NSString *urlStr = [url absoluteString];
    if ([urlStr containsString:@"d.pcs.baidu.com"] ||
        [urlStr containsString:@"pcs.baidu.com"] ||
        [urlStr containsString:@"cdn.baidupcs.com"] ||
        [urlStr containsString:@"bj.bcebos.com"]) {
        [[UIPasteboard generalPasteboard] setString:urlStr];
    }
    return [self bndp_dataTaskWithRequest:request];
}

@end

// ==================== 构造函数 ====================
__attribute__((constructor))
static void bndp_initialize(void) {
    // Method Swizzling
    swizzleMethod([UITableView class], @selector(tableView:didSelectRowAtIndexPath:), @selector(bndp_tableView:didSelectRowAtIndexPath:));
    swizzleMethod([UICollectionView class], @selector(collectionView:didSelectItemAtIndexPath:), @selector(bndp_collectionView:didSelectItemAtIndexPath:));
    swizzleMethod([UIView class], @selector(touchesBegan:withEvent:), @selector(bndp_touchesBegan:withEvent:));
    swizzleMethod([UIView class], @selector(touchesEnded:withEvent:), @selector(bndp_touchesEnded:withEvent:));
    swizzleMethod([UIControl class], @selector(sendAction:to:forEvent:), @selector(bndp_sendAction:to:forEvent:));
    swizzleMethod([NSURLSession class], @selector(dataTaskWithRequest:), @selector(bndp_dataTaskWithRequest:));

    // 显示悬浮球
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (!window) window = [[[UIApplication sharedApplication] windows] firstObject];
        CGFloat size = 50;
        CGFloat x = [UIScreen mainScreen].bounds.size.width - size - 20;
        CGFloat y = 100;
        BNDPFloatingBall *ball = [[BNDPFloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        [window addSubview:ball];
    });

    // 注册前台通知
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *note) {
        checkAndRestorePending();
    }];
}
