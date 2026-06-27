//
//  BaiduPan Final Probe - 修复宏定义
//  修复变量名冲突问题
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableString *gLog = nil;
static NSMutableArray *gKeyFindings = nil;

#define LOG(fmt, ...) do { \
    NSString *_logMsg = [NSString stringWithFormat:@"[PROBE] " fmt, ##__VA_ARGS__]; \
    NSLog(@"%@", _logMsg); \
    if (gLog) [gLog appendString:_logMsg]; \
    if (gLog) [gLog appendString:@"\n"]; \
} while(0)

#define KEY(fmt, ...) do { \
    NSString *_keyMsg = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    if (gKeyFindings) [gKeyFindings addObject:_keyMsg]; \
    NSString *_logMsg = [NSString stringWithFormat:@"[PROBE] KEY: %@", _keyMsg]; \
    NSLog(@"%@", _logMsg); \
    if (gLog) [gLog appendString:_logMsg]; \
    if (gLog) [gLog appendString:@"\n"]; \
} while(0)

static void showResults(void) {
    if (!gKeyFindings || gKeyFindings.count == 0) return;
    NSMutableString *msg = [NSMutableString stringWithString:@"=== 探测结果 ===\n\n"];
    for (NSString *f in gKeyFindings) {
        [msg appendString:f];
        [msg appendString:@"\n"];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"探测结果" 
                                                                   message:msg 
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制全部" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        pb.string = gLog ?: @"";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续" style:UIAlertActionStyleCancel handler:nil]];
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
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    [vc presentViewController:alert animated:YES completion:nil];
}

static void hookDownloadClasses(void) {
    int count = objc_getClassList(NULL, 0);
    Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * count);
    objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"download"] || [lower containsString:@"transfer"] ||
            [lower containsString:@"bdpan"] || [lower containsString:@"netdisk"]) {
            KEY(@"类: %@", name);
            unsigned int mc = 0;
            Method *methods = class_copyMethodList(classes[i], &mc);
            for (unsigned int j = 0; j < mc; j++) {
                NSString *sel = NSStringFromSelector(method_getName(methods[j]));
                NSString *sl = sel.lowercaseString;
                if ([sl containsString:@"download"] || [sl containsString:@"transfer"] ||
                    [sl containsString:@"start"] || [sl containsString:@"add"] ||
                    [sl containsString:@"task"]) {
                    KEY(@"  方法: %@.%@", name, sel);
                }
            }
            free(methods);
        }
    }
    free(classes);
}

%hook NSNotificationCenter
- (void)postNotificationName:(NSString *)name object:(id)object userInfo:(NSDictionary *)userInfo {
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"download"] || [lower containsString:@"transfer"] ||
        [lower containsString:@"task"] || [lower containsString:@"pan"]) {
        KEY(@"通知: %@", name);
    }
    %orig;
}
%end

%hook UIButton
- (void)sendActionsForControlEvents:(UIControlEvents)events {
    if (events == UIControlEventTouchUpInside) {
        NSSet *targets = [self allTargets];
        for (id target in targets) {
            NSArray *actions = [self actionsForTarget:target forControlEvent:events];
            for (NSString *action in actions) {
                NSString *tc = NSStringFromClass([target class]);
                KEY(@"按钮: %@ -> %@", tc, action);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    showResults();
                });
            }
        }
    }
    %orig;
}
%end

%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    NSString *sel = NSStringFromSelector(action);
    NSString *lower = sel.lowercaseString;
    if ([lower containsString:@"download"] || [lower containsString:@"transfer"] ||
        [lower containsString:@"save"]) {
        KEY(@"Action: %@ -> %@", NSStringFromClass([target class]), sel);
    }
    return %orig;
}
%end

%ctor {
    gLog = [NSMutableString string];
    gKeyFindings = [NSMutableArray array];
    LOG(@"Final Probe loaded!");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookDownloadClasses();
        showResults();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        hookDownloadClasses();
        showResults();
    });
}
