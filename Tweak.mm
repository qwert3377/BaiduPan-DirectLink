//
//  百度网盘 SVIP 直链助手 - 巨魔/TrollStore 版
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
    // 优先使用手动输入的 token
    if (gManualToken && gManualToken.length > 0) {
        return gManualToken;
    }
    // 尝试从 NSUserDefaults 读取
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *token = [defaults stringForKey:@"bdstoken"];
    if (token.length > 0) return token;
    return nil;
}

static NSString * getCurrentPath(void) {
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

#pragma mark - 核心 API

static void fetchDlink(NSString *filePath, NSInteger retry, void (^completion)(NSString *dlink, NSError *err)) {
    NSString *token = getBdstoken();
    if (!token) {
        completion(nil, [NSError errorWithDomain:@"BaiduPan" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"未获取到 bdstoken，请确保已登录或手动输入 token"}]);
        return;
    }
    NSString *encPath = [filePath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
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
    if (![originalName hasSuffix:@".pdf"]) {
        NSString *renamedName = [originalName stringByAppendingString:@".pdf"];
        NSString *originalPath = [currentPath isEqualToString:@"/"] ? [NSString stringWithFormat:@"/%@", originalName] : [NSString stringWithFormat:@"%@/%@", currentPath, originalName];
        DLog(@"开始重命名: %@ -> %@", originalName, renamedName);
        renameFile(fileId, originalPath, renamedName, ^(BOOL success, NSError *err) {
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
        NSString *filePath = [currentPath isEqualToString:@"/"] ? [NSString stringWithFormat:@"/%@", originalName] : [NSString stringWithFormat:@"%@/%@", currentPath, originalName];
        fetchDlink(filePath, 0, finish);
    }
}

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

- (void)buttonTapped:(UIButton *)sender {
    @try {
        UIViewController *vc = topViewController();
        if (!vc) return;
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
    } @catch (NSException *e) {
        DLog(@"按钮点击异常: %@", e.reason);
    }
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

#pragma mark - 使用 NSNotification 监听（最安全）

__attribute__((constructor)) static void init() {
    DLog(@"巨魔版已加载 v3.5.0 (arm64)");
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
