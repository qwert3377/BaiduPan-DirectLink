//
//  百度网盘 SVIP 直链助手 - 巨魔/TrollStore 版 (修改版 v4.0)
//  修复错误码2：支持自动获取当前路径 & 文件选择器
//  纯 Runtime Swizzling，不依赖 Substrate/ElleKit
//  通过 TrollFools 注入百度网盘 IPA
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 配置与日志

#define DLog(fmt, ...) NSLog((@"[BaiduPanTroll] " fmt), ##__VA_ARGS__)

static const NSInteger kLargeFileThreshold = 30 * 1024 * 1024;
static const NSInteger kWaitTimeAfterRename = 4000;
static const NSInteger kLargeFileExtraWait = 10000;
static const NSInteger kDlinkRetryCount = 3;

static NSString *gManualToken = nil;
static NSString *gCurrentPath = @"/";  // 全局缓存当前路径

#pragma mark - 工具函数

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

static void bdAsyncRequest(NSString *url, NSString *method, NSDictionary *headers, NSString *body, void (^handler)(id json, NSError *err)) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 20;
    [req setValue:@"https://pan.baidu.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"XMLHttpRequest" forHTTPHeaderField:@"X-Requested-With"];
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

// ========== 【修改1】改进 getCurrentPath，优先使用全局缓存 ==========
static NSString * getCurrentPath(void) {
    // 优先使用运行时捕获的路径
    if (gCurrentPath && gCurrentPath.length > 0 && ![gCurrentPath isEqualToString:@"/"]) {
        return gCurrentPath;
    }
    // 尝试从 NSUserDefaults 读取（兼容旧版）
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *path = [defaults stringForKey:@"currentPath"];
    if (path.length > 0) return path;
    return @"/";
}

static void showAlert(NSString *title, NSString *msg) {
    UIViewController *vc = topViewController();
    if (!vc) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    if ([msg hasPrefix:@"http"]) {
        [alert addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[UIPasteboard generalPasteboard] setString:msg];
        }]];
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 【新增】通过百度网盘内部类获取当前路径

// 尝试从百度网盘的 ViewController 中读取当前路径
static NSString * extractPathFromViewController(UIViewController *vc) {
    if (!vc) return nil;

    // 百度网盘常见路径属性名（通过 class-dump 常见）
    NSArray *pathKeys = @[@"currentPath", @"path", @"dirPath", @"currentDir", @"m_path", @"_currentPath"];

    for (NSString *key in pathKeys) {
        @try {
            id val = [vc valueForKey:key];
            if (val && [val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                DLog(@"从 VC(%@) 读取到路径 [%@]: %@", NSStringFromClass([vc class]), key, val);
                return val;
            }
        } @catch (NSException *e) { /* ignore */ }
    }

    // 递归检查子视图控制器
    for (UIViewController *child in vc.childViewControllers) {
        NSString *p = extractPathFromViewController(child);
        if (p) return p;
    }

    return nil;
}

// 从导航栈顶部获取路径
static NSString * getPathFromNavStack(void) {
    UIViewController *vc = topViewController();
    if (!vc) return nil;

    NSString *path = extractPathFromViewController(vc);
    if (path) return path;

    // 如果是导航控制器，尝试从栈中每个 VC 获取
    if ([vc.navigationController isKindOfClass:[UINavigationController class]]) {
        NSArray *vcs = vc.navigationController.viewControllers;
        for (NSInteger i = vcs.count - 1; i >= 0; i--) {
            path = extractPathFromViewController(vcs[i]);
            if (path) return path;
        }
    }

    return nil;
}

#pragma mark - 【新增】获取当前目录下的文件列表

static void fetchFileList(NSString *path, void (^completion)(NSArray *files, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未获取到 bdstoken"}]);
        return;
    }

    NSString *encPath = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/list?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dir=%@&order=time&desc=1&showempty=0&page=1&num=100&t=%ld",
                     token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];

    DLog(@"请求文件列表: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) { completion(nil, err); return; }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            NSArray *list = json[@"list"] ?: @[];
            completion(list, nil);
        } else {
            NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"错误码: %ld", (long)errnoVal];
            completion(nil, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

#pragma mark - 核心 API

static void fetchDlink(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未获取到 bdstoken，请确保已登录或手动输入 token"}]);
        return;
    }

    // 确保路径以 / 开头
    NSString *normalizedPath = filePath;
    if (![normalizedPath hasPrefix:@"/"]) {
        normalizedPath = [@"/" stringByAppendingString:normalizedPath];
    }

    NSString *encPath = [normalizedPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemetas?bdstoken=%@&channel=chunlei&clienttype=0&web=1&app_id=250528&dlink=1&path=%@&t=%ld",
                     token, encPath, (long)([[NSDate date] timeIntervalSince1970] * 1000)];
    DLog(@"请求 filemetas: %@", url);
    bdAsyncRequest(url, @"GET", nil, nil, ^(id json, NSError *err) {
        if (err) {
            if (retry < kDlinkRetryCount) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    fetchDlink(filePath, retry + 1, completion);
                });
                return;
            }
            completion(nil, err);
            return;
        }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            NSArray *info = json[@"info"] ?: json[@"list"];
            if ([info count] > 0) {
                NSString *dlink = info[0][@"dlink"];
                if (dlink.length > 0) { completion(dlink, nil); return; }
            }
        } else if (errnoVal == -9 && retry < kDlinkRetryCount) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                fetchDlink(filePath, retry + 1, completion);
            });
            return;
        }
        NSString *msg = json[@"errmsg"] ?: [NSString stringWithFormat:@"错误码: %ld", (long)errnoVal];
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
    });
}

static void renameFile(NSString *fileId, NSString *path, NSString *newName, void (^completion)(BOOL success, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(NO, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未获取到 token"}]);
        return;
    }
    NSString *url = [NSString stringWithFormat:@"https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=rename&clienttype=0&app_id=250528&web=1&bdstoken=%@", token];
    NSArray *list = @[@{@"id": @([fileId integerValue]), @"path": path, @"newname": newName}];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
    NSString *listStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSString *body = [NSString stringWithFormat:@"filelist=%@", [listStr stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    bdAsyncRequest(url, @"POST", nil, body, ^(id json, NSError *err) {
        if (err) { completion(NO, err); return; }
        NSInteger errnoVal = [json[@"errno"] integerValue];
        if (errnoVal == 0) {
            completion(YES, nil);
        } else {
            NSString *msg = json[@"show_msg"] ?: json[@"errmsg"] ?: @"重命名失败";
            completion(NO, [NSError errorWithDomain:@"BaiduPan" code:errnoVal userInfo:@{NSLocalizedDescriptionKey: msg}]);
        }
    });
}

static void runPipeline(NSString *fileName, NSString *fileId, NSString *currentPath, NSInteger fileSize) {
    NSString *originalName = fileName;
    (void)originalName;
    void (^finish)(NSString *, NSError *) = ^(NSString *dlink, NSError *err) {
        if (dlink) {
            [[UIPasteboard generalPasteboard] setString:dlink];
            showAlert(@"直链已复制到剪贴板", dlink);
        } else {
            showAlert(@"获取失败", err.localizedDescription);
        }
    };

    // 构建完整路径
    NSString *fullPath;
    if ([currentPath isEqualToString:@"/"]) {
        fullPath = [NSString stringWithFormat:@"/%@", originalName];
    } else {
        fullPath = [NSString stringWithFormat:@"%@/%@", currentPath, originalName];
    }

    if (![originalName hasSuffix:@".pdf"]) {
        NSString *renamedName = [originalName stringByAppendingString:@".pdf"];
        DLog(@"开始重命名: %@ -> %@", fullPath, renamedName);
        renameFile(fileId, fullPath, renamedName, ^(BOOL success, NSError *err) {
            if (!success) {
                showAlert(@"重命名失败", err.localizedDescription);
                return;
            }
            NSString *renamedPath = [currentPath isEqualToString:@"/"] ? [NSString stringWithFormat:@"/%@", renamedName] : [NSString stringWithFormat:@"%@/%@", currentPath, renamedName];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWaitTimeAfterRename * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
                void (^fetchAndRestore)(void) = ^{
                    fetchDlink(renamedPath, 0, ^(NSString *dlink, NSError *err) {
                        renameFile(fileId, renamedPath, originalName, ^(BOOL s, NSError *e) {
                            if (!s) DLog(@"恢复文件名失败: %@", e.localizedDescription);
                            finish(dlink, err);
                        });
                    });
                };
                if (fileSize > kLargeFileThreshold) {
                    DLog(@"大文件(%ld MB)，额外等待 %ld ms", (long)(fileSize/1024/1024), (long)kLargeFileExtraWait);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLargeFileExtraWait * NSEC_PER_MSEC)), dispatch_get_main_queue(), fetchAndRestore);
                } else {
                    fetchAndRestore();
                }
            });
        });
    } else {
        fetchDlink(fullPath, 0, finish);
    }
}

#pragma mark - 【新增】文件选择器

@interface HKCFilePickerHelper : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSArray *fileList;
@property (nonatomic, strong) UIAlertController *alertController;
@property (nonatomic, copy) void (^selectedCallback)(NSDictionary *fileInfo);
@end

@implementation HKCFilePickerHelper

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"HKCFileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    }
    NSDictionary *file = self.fileList[indexPath.row];
    NSString *name = file[@"server_filename"] ?: file[@"path"];
    NSInteger isDir = [file[@"isdir"] integerValue];
    cell.textLabel.text = name;
    cell.detailTextLabel.text = isDir ? @"📁 文件夹" : [NSString stringWithFormat:@"📄 %@", file[@"size"]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *file = self.fileList[indexPath.row];
    if (self.selectedCallback) {
        self.selectedCallback(file);
    }
    [self.alertController dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - 悬浮按钮 Helper

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

// ========== 【修改2】按钮点击后先尝试自动获取路径，再显示文件选择器 ==========
- (void)buttonTapped:(UIButton *)sender {
    @try {
        UIViewController *vc = topViewController();
        if (!vc) return;

        // 1. 先尝试自动获取当前路径
        NSString *autoPath = getPathFromNavStack();
        if (autoPath) {
            gCurrentPath = autoPath;
            DLog(@"自动获取到路径: %@", autoPath);
        }

        // 2. 获取当前路径（可能来自自动检测或缓存）
        NSString *currentPath = getCurrentPath();
        DLog(@"使用路径: %@", currentPath);

        // 3. 获取该路径下的文件列表，让用户选择
        UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"加载中" message:@"正在获取文件列表..." preferredStyle:UIAlertControllerStyleAlert];
        [vc presentViewController:loading animated:YES completion:nil];

        fetchFileList(currentPath, ^(NSArray *files, NSError *err) {
            [loading dismissViewControllerAnimated:YES completion:^{
                if (err) {
                    // 文件列表获取失败，回退到手动输入模式
                    [self showManualInputDialog:vc];
                    return;
                }

                if (files.count == 0) {
                    showAlert(@"提示", @"当前目录下没有文件");
                    return;
                }

                // 过滤出文件（排除文件夹）
                NSMutableArray *fileItems = [NSMutableArray array];
                for (NSDictionary *f in files) {
                    if ([f[@"isdir"] integerValue] == 0) {
                        [fileItems addObject:f];
                    }
                }

                if (fileItems.count == 0) {
                    showAlert(@"提示", @"当前目录下没有文件，只有文件夹");
                    return;
                }

                // 显示文件选择器
                [self showFilePicker:vc files:fileItems];
            }];
        }];

    } @catch (NSException *e) {
        DLog(@"按钮点击异常: %@", e.reason);
    }
}

// 显示文件选择弹窗
- (void)showFilePicker:(UIViewController *)vc files:(NSArray *)files {
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"选择文件" message:[NSString stringWithFormat:@"当前路径: %@\n共 %lu 个文件", getCurrentPath(), (unsigned long)files.count] preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *file in files) {
        NSString *name = file[@"server_filename"] ?: file[@"path"];
        NSInteger size = [file[@"size"] integerValue];
        NSString *sizeStr = size > 1024*1024 ? [NSString stringWithFormat:@"%.1fMB", size/1024.0/1024.0] : [NSString stringWithFormat:@"%.1fKB", size/1024.0];
        NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, sizeStr];

        [picker addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            NSString *fileName = file[@"server_filename"];
            NSString *fileId = [NSString stringWithFormat:@"%@", file[@"fs_id"]];
            NSInteger fileSize = [file[@"size"] integerValue];

            // 先让用户输入/确认 bdstoken
            [self showTokenConfirmDialog:vc fileName:fileName fileId:fileId fileSize:fileSize];
        }]];
    }

    [picker addAction:[UIAlertAction actionWithTitle:@"手动输入文件名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self showManualInputDialog:vc];
    }]];

    [picker addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
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

// 确认/输入 bdstoken
- (void)showTokenConfirmDialog:(UIViewController *)vc fileName:(NSString *)fileName fileId:(NSString *)fileId fileSize:(NSInteger)fileSize {
    UIAlertController *input = [UIAlertController alertControllerWithTitle:@"确认信息" message:[NSString stringWithFormat:@"文件: %@\n路径: %@", fileName, getCurrentPath()] preferredStyle:UIAlertControllerStyleAlert];

    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken (从网页版获取)";
        tf.text = gManualToken ?: @"";
    }];

    [input addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *token = input.textFields[0].text;
        if (token.length > 0) {
            gManualToken = token;
        }
        runPipeline(fileName, fileId, getCurrentPath(), fileSize);
    }]];

    [vc presentViewController:input animated:YES completion:nil];
}

// 手动输入模式（兼容旧版）
- (void)showManualInputDialog:(UIViewController *)vc {
    UIAlertController *input = [UIAlertController alertControllerWithTitle:@"复制直链" message:@"输入文件名和 bdstoken" preferredStyle:UIAlertControllerStyleAlert];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"文件名，例如: example.zip";
    }];
    [input addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"bdstoken (从网页版获取)";
        tf.text = gManualToken ?: @"";
    }];
    [input addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [input addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    CGPoint translation = [pan translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:btn.superview];
}

@end

#pragma mark - 添加悬浮按钮（安全方式）

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
                [btn setTitle:@"直链" forState:UIControlStateNormal];
                [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
                btn.alpha = 0.9;
                [btn addTarget:[HKCButtonHelper shared] action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
                UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[HKCButtonHelper shared] action:@selector(pan:)];
                [btn addGestureRecognizer:pan];
                [window addSubview:btn];
                DLog(@"悬浮按钮已添加");
            } @catch (NSException *e) {
                DLog(@"添加按钮异常: %@", e.reason);
            }
        });
    });
}

#pragma mark - 【新增】Method Swizzling 拦截百度网盘路径变化

// 通用 Swizzling 工具
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

// 拦截 viewDidAppear 来捕获路径（通用方案）
@interface UIViewController (HKCPathHook)
@end

@implementation UIViewController (HKCPathHook)

- (void)hkc_viewDidAppear:(BOOL)animated {
    [self hkc_viewDidAppear:animated];

    // 尝试从当前 VC 提取路径
    NSString *path = extractPathFromViewController(self);
    if (path && path.length > 0) {
        gCurrentPath = path;
        DLog(@"[Swizzle] 捕获路径: %@ from %@", path, NSStringFromClass([self class]));
    }
}

@end

#pragma mark - 初始化

__attribute__((constructor)) static void init() {
    DLog(@"巨魔版已加载 v4.0 (arm64) - 修复错误码2");

    // 注册 Swizzle：拦截所有 UIViewController 的 viewDidAppear
    static dispatch_once_t swizzleOnce;
    dispatch_once(&swizzleOnce, ^{
        swizzleInstanceMethod([UIViewController class], @selector(viewDidAppear:), @selector(hkc_viewDidAppear:));
        DLog(@"UIViewController swizzle 已注册");
    });

    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                            object:nil
                                                             queue:[NSOperationQueue mainQueue]
                                                        usingBlock:^(NSNotification *note) {
            DLog(@"App 已激活，准备添加悬浮按钮");
            addFloatingButton();
        }];
        DLog(@"NSNotification 监听已设置");
    } @catch (NSException *e) {
        DLog(@"初始化异常: %@", e.reason);
    }
}
