//
//  BaiduNetDiskPlugin_Backstage_Pure.m
//  纯后台自动重命名+自动打开文件 v11.0-Pure
//  目标：用户点击图片界面文件，后台自动完成重命名并打开进入预览/下载界面
//  原则：完全不依赖前台 UI，纯数据驱动，所有操作通过 API 完成
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>

// ==================== 全局配置 ====================
static NSString *const kRenameSuffix = @".88888888888888";
static NSString *const kRenamedDisplayName = @"88888888888888";

static NSString *const kKeyPendingFileId = @"BNDP_Pending_FileId";
static NSString *const kKeyPendingPath = @"BNDP_Pending_Path";
static NSString *const kKeyPendingOriginalName = @"BNDP_Pending_OriginalName";
static NSString *const kKeyPendingTimestamp = @"BNDP_Pending_Timestamp";
static NSString *const kKeyLastFileId = @"BNDP_Last_FileId";
static NSString *const kKeyLastPath = @"BNDP_Last_Path";
static NSString *const kKeyLastOriginalName = @"BNDP_Last_OriginalName";

static BOOL g_autoProcessEnabled = YES;
static BOOL g_isProcessing = NO;

// ==================== 辅助：获取 bdstoken ====================
static NSString* getBdstoken(void) {
    NSString *bdstoken = nil;

    // 方法1：UserDefaults
    @try {
        bdstoken = [[NSUserDefaults standardUserDefaults] objectForKey:@"bdstoken"];
    } @catch (NSException *e) {}

    // 方法2：从应用 delegate
    if (!bdstoken) {
        @try {
            id appDelegate = [[UIApplication sharedApplication] delegate];
            bdstoken = [appDelegate valueForKey:@"bdstoken"];
        } @catch (NSException *e) {}
    }

    // 方法3：从全局变量
    if (!bdstoken) {
        @try {
            // 尝试从 BaiduNetDisk 应用内部获取
            Class appClass = NSClassFromString(@"BDAppDelegate");
            if (appClass) {
                id app = [appClass performSelector:@selector(sharedInstance)];
                bdstoken = [app valueForKey:@"bdstoken"];
            }
        } @catch (NSException *e) {}
    }

    return bdstoken;
}

// ==================== 辅助：获取 BDUSS ====================
static NSString* getBDUSS(void) {
    NSString *bduss = nil;
    @try {
        bduss = [[NSUserDefaults standardUserDefaults] objectForKey:@"BDUSS"];
    } @catch (NSException *e) {}
    return bduss;
}

// ==================== 核心：后台重命名文件（纯 API） ====================
static void renameFileAPI(NSString *path, NSString *originalName, 
                           void (^completion)(BOOL success, NSString *newPath)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken || !path || !originalName) {
        if (completion) completion(NO, nil);
        return;
    }

    NSString *newName = [originalName stringByAppendingString:kRenameSuffix];
    NSString *newPath = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:newName];

    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@&channel=chunlei&web=1&app_id=250528&clienttype=0", bdstoken];
    NSURL *url = [NSURL URLWithString:urlStr];

    // 构造 filelist 参数
    NSString *filelistStr = [NSString stringWithFormat:@"[{\"path\":\"%@\",\"newname\":\"%@\"}]", 
                              [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                              [newName stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://pan.baidu.com/disk/main" forHTTPHeaderField:@"Referer"];

    // 构造 body
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
                    NSLog(@"[BNDP] Rename API success: %@ -> %@", originalName, newName);
                    if (completion) completion(YES, newPath);
                } else {
                    NSLog(@"[BNDP] Rename API failed, errno: %ld", (long)errno_val);
                    if (completion) completion(NO, nil);
                }
            } @catch (NSException *e) {
                if (completion) completion(NO, nil);
            }
        });
    }];
    [task resume];
}

// ==================== 核心：后台恢复文件名（纯 API） ====================
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
            NSLog(@"[BNDP] Restore API success: %@", originalName);
        } else {
            NSLog(@"[BNDP] Restore API failed: %@", error);
        }
    }];
    [task resume];
}

// ==================== 核心：获取文件下载直链（dlink） ====================
static void fetchDownloadLinkAPI(NSString *fileId, NSString *path, 
                                  void (^completion)(NSString *dlink)) {
    NSString *bdstoken = getBdstoken();
    if (!bdstoken || !fileId) {
        if (completion) completion(nil);
        return;
    }

    // 方法1：使用 filemetas API
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

// ==================== 核心：通过消息发送打开文件（不依赖 UI） ====================
static void openFileViaMessage(NSString *fileId, NSString *path) {
    if (!fileId || !path) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // 方法1：尝试通过 FileListViewController 的 openFile 方法
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *window = [app keyWindow];
        if (!window) window = [[app windows] firstObject];

        UIViewController *rootVC = [window rootViewController];

        // 查找 FileListViewController
        UIViewController *targetVC = nil;
        if ([rootVC isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)rootVC;
            NSArray *vcs = [nav viewControllers];
            for (UIViewController *vc in vcs) {
                NSString *className = NSStringFromClass([vc class]);
                if ([className containsString:@"FileList"] || [className containsString:@"FileView"]) {
                    targetVC = vc;
                    break;
                }
            }
            if (!targetVC && [vcs count] > 0) {
                targetVC = [vcs lastObject];
            }
        }

        if (targetVC) {
            // 尝试调用 openFile 相关方法
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
                0
            };

            for (int i = 0; selectors[i] != 0; i++) {
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

        // 方法2：通过 NSNotification 触发
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_OpenFileRequest"
                                                            object:nil
                                                          userInfo:@{@"fileId": fileId, @"path": path}];
        NSLog(@"[BNDP] Open file via notification");
    });
}

// ==================== 核心：保存处理记录 ====================
static void saveProcessingRecord(NSString *fileId, NSString *path, NSString *originalName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:fileId forKey:kKeyLastFileId];
    [defaults setObject:path forKey:kKeyLastPath];
    [defaults setObject:originalName forKey:kKeyLastOriginalName];
    [defaults synchronize];
}

// ==================== 核心：保存待恢复状态 ====================
static void savePendingRestore(NSString *fileId, NSString *path, NSString *originalName) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:fileId forKey:kKeyPendingFileId];
    [defaults setObject:path forKey:kKeyPendingPath];
    [defaults setObject:originalName forKey:kKeyPendingOriginalName];
    [defaults setObject:@([[NSDate date] timeIntervalSince1970]) forKey:kKeyPendingTimestamp];
    [defaults synchronize];
}

// ==================== 核心：检查并恢复待恢复文件 ====================
static void checkAndRestorePending(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *fileId = [defaults objectForKey:kKeyPendingFileId];
    NSString *path = [defaults objectForKey:kKeyPendingPath];
    NSString *originalName = [defaults objectForKey:kKeyPendingOriginalName];
    NSNumber *timestamp = [defaults objectForKey:kKeyPendingTimestamp];

    if (!fileId || !path || !originalName) return;

    // 检查是否超时（5分钟）
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

    // 检查当前是否在文件列表页（不在预览页则恢复）
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = [app keyWindow];
    if (!window) window = [[app windows] firstObject];
    UIViewController *vc = [window rootViewController];

    BOOL inFileList = NO;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        UIViewController *topVC = [nav topViewController];
        NSString *className = NSStringFromClass([topVC class]);
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

// ==================== 核心：主处理流程 ====================
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

    // 保存记录
    saveProcessingRecord(fileId, path, originalName);

    // 步骤1：后台重命名
    renameFileAPI(path, originalName, ^(BOOL success, NSString *newPath) {
        if (!success) {
            NSLog(@"[BNDP] Rename failed, abort");
            g_isProcessing = NO;
            return;
        }

        NSLog(@"[BNDP] Step 1: Rename success");

        // 步骤2：后台打开文件
        openFileViaMessage(fileId, newPath ?: path);
        NSLog(@"[BNDP] Step 2: Open file triggered");

        // 步骤3：保存待恢复状态
        savePendingRestore(fileId, path, originalName);
        NSLog(@"[BNDP] Step 3: Pending restore saved");

        // 步骤4：获取下载直链（可选）
        fetchDownloadLinkAPI(fileId, path, ^(NSString *dlink) {
            if (dlink) {
                NSLog(@"[BNDP] Step 4: Download link: %@", dlink);
                [[UIPasteboard generalPasteboard] setString:dlink];

                // 显示提示
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

// ==================== Hook 1：拦截 UITableView 的 didSelectRow ====================
%hook UITableView

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!g_autoProcessEnabled) {
        %orig;
        return;
    }

    // 获取 cell
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        %orig;
        return;
    }

    // 获取文件信息（通过 cell 内部数据）
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;

    @try {
        // 尝试获取 fileInfo
        id fileInfo = [cell valueForKey:@"_fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"fileInfo"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"_data"];
        if (!fileInfo) fileInfo = [cell valueForKey:@"data"];

        if (fileInfo) {
            fileId = [fileInfo valueForKey:@"fid"];
            if (!fileId) fileId = [fileInfo valueForKey:@"fileId"];
            if (!fileId) fileId = [fileInfo valueForKey:@"id"];
            if (!fileId) fileId = [fileInfo valueForKey:@"fs_id"];

            path = [fileInfo valueForKey:@"path"];
            originalName = [fileInfo valueForKey:@"name"];
            if (!originalName) originalName = [fileInfo valueForKey:@"server_filename"];
        }
    } @catch (NSException *e) {}

    // 如果无法从 fileInfo 获取，尝试从 label 获取文件名
    if (!originalName) {
        @try {
            NSArray *subviews = [cell.contentView subviews];
            NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
            while ([queue count] > 0) {
                UIView *view = [queue objectAtIndex:0];
                [queue removeObjectAtIndex:0];
                if ([view isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)view;
                    if (label.text && [label.text length] > 0 && ![label.text isEqualToString:@" "]) {
                        originalName = label.text;
                        break;
                    }
                }
                [queue addObjectsFromArray:[view subviews]];
            }
        } @catch (NSException *e) {}
    }

    if (!fileId || !path || !originalName) {
        NSLog(@"[BNDP] Cannot extract file info, fallback to original");
        %orig;
        return;
    }

    NSLog(@"[BNDP] Detected file click: %@", originalName);

    // 取消选择，防止默认行为
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    // 后台处理
    processBackstage(fileId, path, originalName);
}

%end

// ==================== Hook 2：拦截 Cell 触摸事件（更底层） ====================
%hook UITableViewCell

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!g_autoProcessEnabled) {
        %orig;
        return;
    }

    // 尝试获取文件信息
    NSString *fileId = nil;
    NSString *path = nil;
    NSString *originalName = nil;

    @try {
        id fileInfo = [self valueForKey:@"_fileInfo"];
        if (!fileInfo) fileInfo = [self valueForKey:@"fileInfo"];
        if (!fileInfo) fileInfo = [self valueForKey:@"_data"];
        if (!fileInfo) fileInfo = [self valueForKey:@"data"];

        if (fileInfo) {
            fileId = [fileInfo valueForKey:@"fid"];
            if (!fileId) fileId = [fileInfo valueForKey:@"fileId"];
            if (!fileId) fileId = [fileInfo valueForKey:@"id"];
            if (!fileId) fileId = [fileInfo valueForKey:@"fs_id"];

            path = [fileInfo valueForKey:@"path"];
            originalName = [fileInfo valueForKey:@"name"];
            if (!originalName) originalName = [fileInfo valueForKey:@"server_filename"];
        }
    } @catch (NSException *e) {}

    if (fileId && path && originalName) {
        NSLog(@"[BNDP] Touch on file: %@, start backstage", originalName);
        processBackstage(fileId, path, originalName);
        return; // 阻止默认触摸行为
    }

    %orig;
}

%end

// ==================== Hook 3：拦截下载链接 ====================
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

// ==================== 悬浮球 UI ====================
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

// ==================== 构造函数 ====================
%ctor {
    NSLog(@"[BNDP] ========================================");
    NSLog(@"[BNDP] Pure Backstage Plugin v11.0 Loaded");
    NSLog(@"[BNDP] Features:");
    NSLog(@"[BNDP]   1. Backstage rename via API");
    NSLog(@"[BNDP]   2. Auto open file via message");
    NSLog(@"[BNDP]   3. Auto restore when return");
    NSLog(@"[BNDP]   4. Download link intercept");
    NSLog(@"[BNDP]   5. No UI scrolling at all");
    NSLog(@"[BNDP] ========================================");

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

    // 注册前台通知，检查待恢复文件
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                        object:nil
                                                         queue:[NSOperationQueue mainQueue]
                                                    usingBlock:^(NSNotification *note) {
        checkAndRestorePending();
    }];
}
