//
//  BaiduNetDiskPlugin_Backstage.m
//  后台自动重命名+自动打开文件 v11.0
//  目标：用户点击图片界面文件，后台自动完成重命名并打开进入预览/下载界面
//  原则：所有操作后台完成，不做任何前台UI滚动操作
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>

// ==================== 精简类接口 (来自用户提供) ====================
// 省略类接口声明，直接使用 objc_msgSend 调用

// ==================== 全局状态 ====================
static NSString *kPendingRestoreFileId = @"BNDP_PendingRestoreFileId";
static NSString *kPendingRestorePath = @"BNDP_PendingRestorePath";
static NSString *kPendingRestoreOriginalName = @"BNDP_PendingRestoreOriginalName";
static NSString *kPendingRestoreTimestamp = @"BNDP_PendingRestoreTimestamp";
static NSString *const kRenameSuffix = @".88888888888888";
static NSString *const kRenamedName = @"88888888888888";

static BOOL g_isProcessing = NO;
static BOOL g_autoClickEnabled = YES;

// ==================== 辅助函数：创建 Dummy UIEvent ====================
static UIEvent* createDummyEvent(void) {
    // iOS 18 SDK 修复：不能传 nil，必须创建 dummy event
    // 通过 UIApplication 的 _touchesEvent 或创建新的 event
    UIApplication *app = [UIApplication sharedApplication];
    UIEvent *event = nil;

    // 尝试获取当前 event
    @try {
        // iOS 内部方法获取 event
        event = [app performSelector:@selector(_touchesEvent)];
    } @catch (NSException *e) {
        event = nil;
    }

    if (!event) {
        @try {
            // 通过 GSEvent 创建（私有API，但 Theos 环境可用）
            // 或者简单创建一个新的 UITouchesEvent
            Class eventClass = NSClassFromString(@"UITouchesEvent");
            if (eventClass) {
                event = [[eventClass alloc] performSelector:@selector(initWithTouches:) withObject:nil];
            }
        } @catch (NSException *e) {
            event = nil;
        }
    }

    // 如果还是无法创建，使用一个 trick：从 window 获取
    if (!event) {
        UIWindow *window = [app keyWindow];
        if (!window) {
            window = [[app windows] firstObject];
        }
        // 通过发送一个触摸事件来获取 event 对象
        // 这里我们返回一个非 nil 的占位对象，避免编译错误
        // 实际上 touchesBegan 等方法的 event 参数在内部可能不会被严格检查
        event = (UIEvent *)[[NSObject alloc] init];
    }

    return event;
}

// ==================== 辅助函数：获取当前 ViewController ====================
static UIViewController* topViewController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = [app keyWindow];
    if (!window) {
        window = [[app windows] firstObject];
    }
    UIViewController *root = [window rootViewController];
    UIViewController *top = root;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = [(UINavigationController *)top topViewController];
    }
    return top;
}

// ==================== 辅助函数：获取文件列表 TableView ====================
static UITableView* findFileListTableView(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    // 遍历 view 层次查找 UITableView
    NSArray *subviews = [vc.view subviews];
    NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];

    while ([queue count] > 0) {
        UIView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];

        if ([view isKindOfClass:[UITableView class]]) {
            return (UITableView *)view;
        }
        [queue addObjectsFromArray:[view subviews]];
    }
    return nil;
}

// ==================== 辅助函数：在 TableView 中查找指定文件名的 cell ====================
static NSIndexPath* findIndexPathForFileName(NSString *fileName, UITableView *tableView) {
    if (!tableView || !fileName) return nil;

    NSInteger sections = [tableView numberOfSections];
    for (NSInteger section = 0; section < sections; section++) {
        NSInteger rows = [tableView numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
            UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
            if (!cell) continue;

            // 查找 cell 中的文件名 label
            NSArray *cellSubviews = [cell.contentView subviews];
            NSMutableArray *labelQueue = [NSMutableArray arrayWithArray:cellSubviews];
            while ([labelQueue count] > 0) {
                UIView *subview = [labelQueue objectAtIndex:0];
                [labelQueue removeObjectAtIndex:0];

                if ([subview isKindOfClass:[UILabel class]]) {
                    UILabel *label = (UILabel *)subview;
                    if ([label.text isEqualToString:fileName]) {
                        return indexPath;
                    }
                }
                [labelQueue addObjectsFromArray:[subview subviews]];
            }
        }
    }
    return nil;
}

// ==================== 辅助函数：获取 cell 的 fileId ====================
static NSString* getFileIdFromCell(UITableViewCell *cell) {
    if (!cell) return nil;

    // 尝试从 cell 的关联对象或内部变量获取
    // 通过 KVC 获取 _fileInfo 或类似属性
    @try {
        id fileInfo = [cell valueForKey:@"_fileInfo"];
        if (!fileInfo) {
            fileInfo = [cell valueForKey:@"fileInfo"];
        }
        if (fileInfo) {
            NSString *fid = [fileInfo valueForKey:@"fid"];
            if (!fid) {
                fid = [fileInfo valueForKey:@"fileId"];
            }
            if (!fid) {
                fid = [fileInfo valueForKey:@"id"];
            }
            return fid;
        }
    } @catch (NSException *e) {}

    return nil;
}

// ==================== 辅助函数：获取 cell 的 path ====================
static NSString* getPathFromCell(UITableViewCell *cell) {
    if (!cell) return nil;

    @try {
        id fileInfo = [cell valueForKey:@"_fileInfo"];
        if (!fileInfo) {
            fileInfo = [cell valueForKey:@"fileInfo"];
        }
        if (fileInfo) {
            NSString *path = [fileInfo valueForKey:@"path"];
            return path;
        }
    } @catch (NSException *e) {}

    return nil;
}

// ==================== 辅助函数：获取 cell 的原始文件名 ====================
static NSString* getOriginalFileNameFromCell(UITableViewCell *cell) {
    if (!cell) return nil;

    NSArray *subviews = [cell.contentView subviews];
    NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
    while ([queue count] > 0) {
        UIView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if (label.text && [label.text length] > 0) {
                return label.text;
            }
        }
        [queue addObjectsFromArray:[view subviews]];
    }
    return nil;
}

// ==================== 核心：后台重命名文件 ====================
static void renameFileInBackground(NSString *fileId, NSString *path, NSString *originalName, 
                                    void (^completion)(BOOL success, NSString *newName)) {
    if (!fileId || !path || !originalName) {
        if (completion) completion(NO, nil);
        return;
    }

    // 构造新文件名：原始名 + .88888888888888
    NSString *newName = [originalName stringByAppendingString:kRenameSuffix];

    // 获取 bdstoken
    NSString *bdstoken = nil;
    @try {
        // 从 UserDefaults 或全局变量获取
        bdstoken = [[NSUserDefaults standardUserDefaults] objectForKey:@"bdstoken"];
        if (!bdstoken) {
            // 尝试从应用内部获取
            id appDelegate = [[UIApplication sharedApplication] delegate];
            bdstoken = [appDelegate valueForKey:@"bdstoken"];
        }
    } @catch (NSException *e) {}

    if (!bdstoken) {
        NSLog(@"[BNDP] bdstoken not found, cannot rename");
        if (completion) completion(NO, nil);
        return;
    }

    // 构造重命名请求
    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@&channel=chunlei&web=1&app_id=250528&clienttype=0", bdstoken];
    NSURL *url = [NSURL URLWithString:urlStr];

    // 构造请求体
    NSDictionary *fileList = @[@{
        @"path": path,
        @"newname": newName
    }];
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:fileList options:0 error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:bodyData];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"pan.baidu.com" forHTTPHeaderField:@"Referer"];

    // 发送异步请求
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                NSLog(@"[BNDP] Rename request failed: %@", error);
                if (completion) completion(NO, nil);
                return;
            }

            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSInteger errno_val = [[json objectForKey:@"errno"] integerValue];
                if (errno_val == 0) {
                    NSLog(@"[BNDP] Rename success: %@ -> %@", originalName, newName);
                    if (completion) completion(YES, newName);
                } else {
                    NSLog(@"[BNDP] Rename failed with errno: %ld", (long)errno_val);
                    if (completion) completion(NO, nil);
                }
            } @catch (NSException *e) {
                if (completion) completion(NO, nil);
            }
        });
    }];
    [task resume];
}

// ==================== 核心：后台打开文件（进入预览/下载界面） ====================
static void openFileInBackground(NSString *fileId, NSString *path) {
    if (!fileId || !path) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // 获取当前 ViewController
        UIViewController *vc = topViewController();
        if (!vc) return;

        // 方法1：通过 FileViewController 的 openFile 方法
        SEL openFileSel = NSSelectorFromString(@"openFileWithId:path:");
        if ([vc respondsToSelector:openFileSel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [vc performSelector:openFileSel withObject:fileId withObject:path];
            #pragma clang diagnostic pop
            return;
        }

        // 方法2：通过导航控制器 push 文件详情页
        // 构造文件详情 VC
        Class fileDetailClass = NSClassFromString(@"FileDetailViewController");
        if (fileDetailClass) {
            id fileDetailVC = [[fileDetailClass alloc] init];
            if (fileDetailVC) {
                @try {
                    [fileDetailVC setValue:fileId forKey:@"fileId"];
                    [fileDetailVC setValue:path forKey:@"filePath"];
                } @catch (NSException *e) {}

                if ([vc isKindOfClass:[UINavigationController class]]) {
                    [(UINavigationController *)vc pushViewController:fileDetailVC animated:YES];
                } else if (vc.navigationController) {
                    [vc.navigationController pushViewController:fileDetailVC animated:YES];
                }
                return;
            }
        }

        // 方法3：通过发送通知触发文件打开
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BNDP_OpenFileRequest" 
                                                            object:nil 
                                                          userInfo:@{@"fileId": fileId, @"path": path}];
    });
}

// ==================== 核心：后台恢复文件名 ====================
static void restoreFileNameInBackground(NSString *fileId, NSString *path, NSString *originalName) {
    if (!fileId || !path || !originalName) return;

    NSString *bdstoken = nil;
    @try {
        bdstoken = [[NSUserDefaults standardUserDefaults] objectForKey:@"bdstoken"];
    } @catch (NSException *e) {}

    if (!bdstoken) return;

    NSString *urlStr = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?opera=rename&bdstoken=%@&channel=chunlei&web=1&app_id=250528&clienttype=0", bdstoken];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSDictionary *fileList = @[@{
        @"path": [path stringByAppendingString:kRenameSuffix],
        @"newname": originalName
    }];
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:fileList options:0 error:nil];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:bodyData];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"pan.baidu.com" forHTTPHeaderField:@"Referer"];

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

// ==================== 核心：检测是否已进入预览/下载界面 ====================
static BOOL isInPreviewOrDownloadView(void) {
    UIViewController *vc = topViewController();
    if (!vc) return NO;

    NSString *className = NSStringFromClass([vc class]);

    // 检查是否是预览或下载相关页面
    NSArray *previewClasses = @[
        @"FilePreviewViewController",
        @"FileDetailViewController", 
        @"DownloadViewController",
        @"BDFilePreviewController",
        @"BDFileDetailController"
    ];

    for (NSString *previewClass in previewClasses) {
        if ([className isEqualToString:previewClass] || [vc isKindOfClass:NSClassFromString(previewClass)]) {
            return YES;
        }
    }

    // 检查 view 层级中是否有预览相关的 view
    NSArray *subviews = [vc.view subviews];
    NSMutableArray *queue = [NSMutableArray arrayWithArray:subviews];
    while ([queue count] > 0) {
        UIView *view = [queue objectAtIndex:0];
        [queue removeObjectAtIndex:0];

        NSString *viewClass = NSStringFromClass([view class]);
        if ([viewClass containsString:@"Preview"] || 
            [viewClass containsString:@"Download"] ||
            [viewClass containsString:@"Player"]) {
            return YES;
        }
        [queue addObjectsFromArray:[view subviews]];
    }

    return NO;
}

// ==================== 核心：开始检测导航栈变化（用于恢复原名） ====================
static void startNavigationMonitoring(NSString *fileId, NSString *path, NSString *originalName) {
    // 保存待恢复信息
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:fileId forKey:kPendingRestoreFileId];
    [defaults setObject:path forKey:kPendingRestorePath];
    [defaults setObject:originalName forKey:kPendingRestoreOriginalName];
    [defaults setObject:@([[NSDate date] timeIntervalSince1970]) forKey:kPendingRestoreTimestamp];
    [defaults synchronize];

    // 使用 KVO 监听导航控制器变化
    UIViewController *vc = topViewController();
    UINavigationController *nav = nil;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)vc;
    } else {
        nav = vc.navigationController;
    }

    if (nav) {
        // 监听 viewControllers 变化
        [nav addObserver:nav 
              forKeyPath:@"viewControllers" 
                 options:NSKeyValueObservingOptionNew 
                 context:NULL];

        // 设置一个定时器检查是否已离开预览页
        NSTimer *checkTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 
                                                                 target:nav 
                                                               selector:@selector(checkAndRestoreFileName) 
                                                               userInfo:@{@"fileId": fileId, @"path": path, @"originalName": originalName} 
                                                                repeats:YES];

        // 5分钟后自动清理
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [checkTimer invalidate];
            [defaults removeObjectForKey:kPendingRestoreFileId];
            [defaults removeObjectForKey:kPendingRestorePath];
            [defaults removeObjectForKey:kPendingRestoreOriginalName];
            [defaults removeObjectForKey:kPendingRestoreTimestamp];
            [defaults synchronize];
        });
    }
}

// ==================== 核心：检查并恢复文件名 ====================
static void checkAndRestoreFileName(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *fileId = [defaults objectForKey:kPendingRestoreFileId];
    NSString *path = [defaults objectForKey:kPendingRestorePath];
    NSString *originalName = [defaults objectForKey:kPendingRestoreOriginalName];
    NSNumber *timestamp = [defaults objectForKey:kPendingRestoreTimestamp];

    if (!fileId || !path || !originalName) return;

    // 检查是否超时（5分钟）
    if (timestamp) {
        NSTimeInterval savedTime = [timestamp doubleValue];
        NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
        if (currentTime - savedTime > 300) {
            // 超时，清理并恢复
            restoreFileNameInBackground(fileId, path, originalName);
            [defaults removeObjectForKey:kPendingRestoreFileId];
            [defaults removeObjectForKey:kPendingRestorePath];
            [defaults removeObjectForKey:kPendingRestoreOriginalName];
            [defaults removeObjectForKey:kPendingRestoreTimestamp];
            [defaults synchronize];
            return;
        }
    }

    // 检查是否已离开预览界面
    if (!isInPreviewOrDownloadView()) {
        // 用户已返回文件列表，恢复原名
        restoreFileNameInBackground(fileId, path, originalName);
        [defaults removeObjectForKey:kPendingRestoreFileId];
        [defaults removeObjectForKey:kPendingRestorePath];
        [defaults removeObjectForKey:kPendingRestoreOriginalName];
        [defaults removeObjectForKey:kPendingRestoreTimestamp];
        [defaults synchronize];
    }
}

// ==================== 核心：主流程 - 用户点击文件后的后台处理 ====================
static void processFileClickBackstage(UITableViewCell *cell) {
    if (g_isProcessing) {
        NSLog(@"[BNDP] Already processing, skip");
        return;
    }

    NSString *fileId = getFileIdFromCell(cell);
    NSString *path = getPathFromCell(cell);
    NSString *originalName = getOriginalFileNameFromCell(cell);

    if (!fileId || !path || !originalName) {
        NSLog(@"[BNDP] Cannot get file info from cell");
        return;
    }

    g_isProcessing = YES;
    NSLog(@"[BNDP] Start backstage processing for: %@", originalName);

    // 步骤1：后台重命名
    renameFileInBackground(fileId, path, originalName, ^(BOOL success, NSString *newName) {
        if (!success) {
            NSLog(@"[BNDP] Rename failed, abort");
            g_isProcessing = NO;
            return;
        }

        NSLog(@"[BNDP] Rename success, now opening file...");

        // 步骤2：后台打开文件（进入预览/下载界面）
        openFileInBackground(fileId, path);

        // 步骤3：开始监控导航栈，以便在用户返回时恢复原名
        startNavigationMonitoring(fileId, path, originalName);

        g_isProcessing = NO;
    });
}

// ==================== Hook：拦截用户点击 Cell ====================
%hook UITableView

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!g_autoClickEnabled) {
        %orig;
        return;
    }

    // 获取当前点击的 cell
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        %orig;
        return;
    }

    // 检查是否是百度网盘的文件列表
    NSString *vcClass = NSStringFromClass([topViewController class]);
    if (![vcClass containsString:@"File"] && ![vcClass containsString:@"List"]) {
        %orig;
        return;
    }

    // 获取文件信息
    NSString *fileId = getFileIdFromCell(cell);
    NSString *path = getPathFromCell(cell);
    NSString *originalName = getOriginalFileNameFromCell(cell);

    if (!fileId || !path || !originalName) {
        %orig;
        return;
    }

    NSLog(@"[BNDP] User clicked file: %@, start backstage processing", originalName);

    // 取消默认选择（防止立即打开）
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    // 后台处理：重命名 + 打开
    processFileClickBackstage(cell);
}

%end

// ==================== Hook：拦截 Cell 的 touchesBegan（更底层的点击拦截） ====================
%hook UITableViewCell

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!g_autoClickEnabled) {
        %orig;
        return;
    }

    // 获取当前 view controller 判断是否在文件列表
    NSString *vcClass = NSStringFromClass([topViewController class]);
    if (![vcClass containsString:@"File"] && ![vcClass containsString:@"List"]) {
        %orig;
        return;
    }

    // 获取文件信息
    NSString *fileId = getFileIdFromCell(self);
    NSString *path = getPathFromCell(self);
    NSString *originalName = getOriginalFileNameFromCell(self);

    if (fileId && path && originalName) {
        NSLog(@"[BNDP] Touch detected on file: %@, processing backstage", originalName);
        processFileClickBackstage(self);
        return; // 不调用 orig，阻止默认行为
    }

    %orig;
}

%end

// ==================== Hook：NSURLSession 下载链接拦截 ====================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = [request URL];
    NSString *urlStr = [url absoluteString];

    // 拦截下载链接
    if ([urlStr containsString:@"d.pcs.baidu.com"] || 
        [urlStr containsString:@"pcs.baidu.com"] ||
        [urlStr containsString:@"cdn.baidupcs.com"]) {
        NSLog(@"[BNDP] Intercepted download URL: %@", urlStr);

        // 可以在这里复制链接到剪贴板
        [[UIPasteboard generalPasteboard] setString:urlStr];

        // 显示提示
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"下载链接已复制" 
                                                            message:urlStr 
                                                           delegate:nil 
                                                  cancelButtonTitle:@"确定" 
                                                  otherButtonTitles:nil];
            [alert show];
        });
    }

    return %orig;
}

%end

// ==================== 悬浮球 UI ====================
@interface BNDPFloatingBall : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGPoint startPoint;
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

        // 长按手势 - 设置菜单
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:longPress];

        // 双击手势 - 一键重试
        UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
        doubleTap.numberOfTapsRequired = 2;
        [self addGestureRecognizer:doubleTap];

        // 单击手势 - 切换开关
        UITapGestureRecognizer *singleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleSingleTap:)];
        [singleTap requireGestureRecognizerToFail:doubleTap];
        [self addGestureRecognizer:singleTap];

        // 拖动手势
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture {
    g_autoClickEnabled = !g_autoClickEnabled;
    self.titleLabel.text = g_autoClickEnabled ? @"BD" : @"OFF";
    self.backgroundColor = g_autoClickEnabled ? [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9] : [UIColor grayColor];

    NSString *msg = g_autoClickEnabled ? @"自动处理已开启" : @"自动处理已关闭";
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"百度网盘插件" 
                                                    message:msg 
                                                   delegate:nil 
                                          cancelButtonTitle:@"确定" 
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gesture {
    // 一键重试：从 UserDefaults 读取上次处理的文件信息
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *lastFileId = [defaults objectForKey:@"BNDP_LastFileId"];
    NSString *lastPath = [defaults objectForKey:@"BNDP_LastPath"];
    NSString *lastOriginalName = [defaults objectForKey:@"BNDP_LastOriginalName"];

    if (lastFileId && lastPath && lastOriginalName) {
        NSLog(@"[BNDP] Retry last file: %@", lastOriginalName);

        // 先恢复原名（如果之前重命名过）
        restoreFileNameInBackground(lastFileId, lastPath, lastOriginalName);

        // 延迟后重新处理
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            // 重新重命名并打开
            renameFileInBackground(lastFileId, lastPath, lastOriginalName, ^(BOOL success, NSString *newName) {
                if (success) {
                    openFileInBackground(lastFileId, lastPath);
                    startNavigationMonitoring(lastFileId, lastPath, lastOriginalName);
                }
            });
        });
    } else {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"百度网盘插件" 
                                                        message:@"没有可重试的记录" 
                                                       delegate:nil 
                                              cancelButtonTitle:@"确定" 
                                              otherButtonTitles:nil];
        [alert show];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        // 显示设置菜单
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"百度网盘插件设置" 
                                                        message:@"选择操作" 
                                                       delegate:self 
                                              cancelButtonTitle:@"取消" 
                                              otherButtonTitles:@"查看历史", @"清除缓存", @"关于", nil];
        [alert show];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self.superview];

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.startPoint = self.center;
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint newCenter = CGPointMake(self.startPoint.x + translation.x, self.startPoint.y + translation.y);

        // 限制在屏幕内
        CGFloat margin = self.frame.size.width / 2;
        newCenter.x = MAX(margin, MIN(self.superview.frame.size.width - margin, newCenter.x));
        newCenter.y = MAX(margin, MIN(self.superview.frame.size.height - margin, newCenter.y));

        self.center = newCenter;
    }
}

@end

// ==================== 悬浮球管理器 ====================
@interface BNDPFloatingBallManager : NSObject
@property (nonatomic, strong) BNDPFloatingBall *floatingBall;
+ (instancetype)sharedManager;
- (void)showFloatingBall;
@end

@implementation BNDPFloatingBallManager

+ (instancetype)sharedManager {
    static BNDPFloatingBallManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)showFloatingBall {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.floatingBall) {
            [self.floatingBall removeFromSuperview];
        }

        UIWindow *window = [[UIApplication sharedApplication] keyWindow];
        if (!window) {
            window = [[[UIApplication sharedApplication] windows] firstObject];
        }

        CGFloat size = 50;
        CGFloat x = [UIScreen mainScreen].bounds.size.width - size - 20;
        CGFloat y = 100;

        self.floatingBall = [[BNDPFloatingBall alloc] initWithFrame:CGRectMake(x, y, size, size)];
        [window addSubview:self.floatingBall];
    });
}

@end

// ==================== 构造函数 ====================
%ctor {
    NSLog(@"[BNDP] Backstage Plugin v11.0 loaded");
    NSLog(@"[BNDP] Features: Auto-rename -> Auto-open -> Auto-restore");
    NSLog(@"[BNDP] No UI scrolling, all operations in background");

    // 显示悬浮球
    [[BNDPFloatingBallManager sharedManager] showFloatingBall];

    // 注册应用进入前台通知，检查是否有待恢复的文件
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification 
                                                        object:nil 
                                                         queue:[NSOperationQueue mainQueue] 
                                                    usingBlock:^(NSNotification *note) {
        checkAndRestoreFileName();
    }];
}

%dtor {
    NSLog(@"[BNDP] Plugin unloaded");
}
