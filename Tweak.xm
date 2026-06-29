//
//  Tweak.xm
//  BaiduPanTroll - Pure Backstage v11.1
//  修复：重命名后自动刷新文件列表
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
                [className containsString:@"BDFile"] || [className containsString:@"PanFile"]) {
                targetVC = vc;
                break;
            }
        }
        if (!targetVC && [vcs count] > 0) {
            targetVC = [vcs lastObject];
        }
    }
    return targetVC;
}

// ==================== 辅助函数：刷新文件列表 ====================
static void refreshFileList(void) {
    UIViewController *vc = getCurrentFileListVC();
    if (!vc) {
        NSLog(@"[BNDP] Cannot find file list VC to refresh");
        return;
    }

    NSLog(@"[BNDP] Refreshing file list...");

    // 方法1：尝试调用常见的刷新方法
    SEL refreshSelectors[] = {
        NSSelectorFromString(@"reloadFileList"),
        NSSelectorFromString(@"refreshData"),
        NSSelectorFromString(@"loadData"),
        NSSelectorFromString(@"fetchFileList"),
        NSSelectorFromString(@"refreshFileList"),
        NSSelectorFromString(@"pullToRefresh"),
        NSSelectorFromString(@"onRefresh"),
        NSSelectorFromString(@"reloadData"),
        (SEL)0
    };

    for (int i = 0; refreshSelectors[i] != (SEL)0; i++) {
        SEL sel = refreshSelectors[i];
        if ([vc respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:sel];
            #pragma clang diagnostic pop
            NSLog(@"[BNDP] Refreshed via selector: %@", NSStringFromSelector(sel));
            return;
        }
    }

    // 方法2：查找 UITableView 并 reloadData
    NSArray *subviews = [vc.view subviews];
    NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
    while ([queue count] > 0) {
        UIView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)view;
            [tableView reloadData];
            NSLog(@"[BNDP] Refreshed via UITableView reloadData");
            return;
        }
        [queue addObjectsFromArray:[view subviews]];
    }

    // 方法3：发送通知
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_RefreshFileList"
                                                        object:nil
                                                      userInfo:nil];
    NSLog(@"[BNDP] Posted refresh notification");
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
                NSLog(@"[BNDP] Rename API error: %@", error);
                if (completion) completion(NO, nil);
                return;
            }
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger errno_val = [[json objectForKey:@"errno"] integerValue];
                if (errno_val == 0) {
                    NSLog(@"[BNDP] Rename success: %@ -> %@", originalName, newName);
                    if (completion) completion(YES, newPath);
                } else {
                    NSLog(@"[BNDP] Rename failed, errno: %ld", (long)errno_val);
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
        if (!error) {
            NSLog(@"[BNDP] Restore success: %@", originalName);
        } else {
            NSLog(@"[BNDP] Restore failed: %@", error);
        }
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
                        NSLog(@"[BNDP] Got dlink: %@", dlink);
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
                    NSLog(@"[BNDP] Open file via selector: %@", NSStringFromSelector(sel));
                    return;
                }
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_OpenFileRequest"
                                                            object:nil
                                                          userInfo:@{@"fileId": fileId, @"path": path}];
        NSLog(@"[BNDP] Open file via notification");
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
            [className containsString:@"Home"] || [className containsString:@"Main"]) {
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

static void extractFileInfoFromCell(UITableViewCell *cell, NSString **outFileId, NSString **outPath, NSString **outName) {
    *outFileId = nil;
    *outPath = nil;
    *outName = nil;
    @try {
        id fileInfo = [cell valueForKey:@"_fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"_data"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"data"];
        if (fileInfo) {
            *outFileId = [fileInfo valueForKey:@"fid"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"fileId"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"id"];
            if (!*outFileId) *outFileId = [fileInfo valueForKey:@"fs_id"];
            *outPath = [fileInfo valueForKey:@"path"];
            *outName = [fileInfo valueForKey:@"name"];
            if (!*outName) *outName = [fileInfo valueForKey:@"server_filename"];
        }
    } @catch (NSException *e) {}
    if (!*outName) {
        @try {
            NSArray *subviews = [cell.contentView subviews];
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

// ==================== 核心处理：重命名 + 刷新 + 打开 ====================
static void processBackstage(NSString *fileId, NSString *path, NSString *originalName) {
    if (g_isProcessing) {
        NSLog(@"[BNDP] Already processing, skip");
        return;
    }
    if (!fileId || !path || !originalName) {
        NSLog(@"[BNDP] Invalid parameters");
        return;
    }
    g_isProcessing = YES;
    NSLog(@"[BNDP] ====== Start Backstage Processing ======");
    NSLog(@"[BNDP] File: %@", originalName);
    NSLog(@"[BNDP] Path: %@", path);
    NSLog(@"[BNDP] FileId: %@", fileId);
    saveProcessingRecord(fileId, path, originalName);

    // 步骤1：后台重命名
    renameFileAPI(path, originalName, ^(BOOL success, NSString *newPath) {
        if (!success) {
            NSLog(@"[BNDP] Rename failed, abort");
            g_isProcessing = NO;
            return;
        }
        NSLog(@"[BNDP] Step 1: Rename success");

        // 步骤2：刷新文件列表（关键修复）
        refreshFileList();
        NSLog(@"[BNDP] Step 2: File list refreshed");

        // 步骤3：延迟打开文件，等刷新完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            openFileViaMessage(fileId, newPath ?: path);
            NSLog(@"[BNDP] Step 3: Open file triggered");
        });

        // 步骤4：保存待恢复状态
        savePendingRestore(fileId, path, originalName);
        NSLog(@"[BNDP] Step 4: Pending restore saved");

        // 步骤5：获取下载直链
        fetchDownloadLinkAPI(fileId, path, ^(NSString *dlink) {
            if (dlink) {
                NSLog(@"[BNDP] Step 5: Download link: %@", dlink);
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
        NSLog(@"[BNDP] ====== Processing Complete ======");
    });
}

// ==================== 悬浮球类声明（必须在所有 %hook 之前）====================
@interface BNDPFloatingBall : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@end

// ==================== Logos Hook 块 ====================
%hook UITableView

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!g_autoProcessEnabled) {
        %orig;
        return;
    }
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        %orig;
        return;
    }
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;
    extractFileInfoFromCell(cell, &fileId, &path, &originalName);
    if (!fileId || !path || !originalName) {
        NSLog(@"[BNDP] Cannot extract file info, fallback to original");
        %orig;
        return;
    }
    NSLog(@"[BNDP] Detected file click: %@", originalName);
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    processBackstage(fileId, path, originalName);
}

%end

%hook UITableViewCell

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!g_autoProcessEnabled) {
        %orig;
        return;
    }
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;
    extractFileInfoFromCell(self, &fileId, &path, &originalName);
    if (fileId && path && originalName) {
        NSLog(@"[BNDP] Touch on file: %@, start backstage", originalName);
        processBackstage(fileId, path, originalName);
        return;
    }
    %orig;
}

%end

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    NSString *urlStr = [url absoluteString];
    if ([urlStr containsString:@"d.pcs.baidu.com"] ||
        [urlStr containsString:@"pcs.baidu.com"] ||
        [urlStr containsString:@"cdn.baidupcs.com"] ||
        [urlStr containsString:@"bj.bcebos.com"]) {
        NSLog(@"[BNDP] Intercept download: %@", urlStr);
        [[UIPasteboard generalPasteboard] setString:urlStr];
    }
    return %orig;
}

%end

// ==================== 悬浮球实现 ====================
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

// ==================== 构造函数 ====================
%ctor {
    NSLog(@"[BNDP] ========================================");
    NSLog(@"[BNDP] Pure Backstage Plugin v11.1 Loaded");
    NSLog(@"[BNDP] Fix: Auto refresh file list after rename");
    NSLog(@"[BNDP] ========================================");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (!window) window = [[[UIApplication sharedApplication] windows] firstObject];
        CGFloat size = 50;
        CGFloat x = [UIScreen mainScreen].bounds.size.width - size - 20;
        CGFloat y = 100;
        BNDPFloatingBall *ball = [[BNDPFloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        [window addSubview:ball];
    });
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *note) {
        checkAndRestorePending();
    }];
}
