//
// BaiduPan SVIP Direct Link Helper
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define DLog(fmt, ...) NSLog(@"[BaiduPanTroll] " fmt, ##__VA_ARGS__)

static NSString *gInterceptedDlink = nil;
static NSString *gInterceptedFileName = nil;
static BOOL gShouldInterceptDlink = NO;

static void showToast(NSString *msg) {
    if (!msg) return;
    dispatch_async(dispatch_get_main_queue(), ^{
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

        UILabel *label = [[UILabel alloc] init];
        label.text = msg;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14];
        label.layer.cornerRadius = 8;
        label.clipsToBounds = YES;
        [label sizeToFit];
        label.frame = CGRectInset(label.frame, 16, 8);
        label.center = CGPointMake(window.bounds.size.width / 2, window.bounds.size.height / 2);
        [window addSubview:label];

        [UIView animateWithDuration:0.3 delay:1.5 options:UIViewAnimationOptionCurveEaseIn animations:^{
            label.alpha = 0;
        } completion:^(BOOL finished) {
            [label removeFromSuperview];
        }];
    });
}

static void handleInterceptedDlink(void) {
    if (!gInterceptedDlink || gInterceptedDlink.length == 0) {
        showToast(@"未拦截到下载链接");
        return;
    }
    DLog(@"Intercepted dlink: %@", gInterceptedDlink);
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = gInterceptedDlink;
    showToast(@"直链已复制到剪贴板");
    gShouldInterceptDlink = NO;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (url && gShouldInterceptDlink) {
        NSString *urlStr = url.absoluteString;
        if ([urlStr containsString:@"d.pcs.baidu.com"] || [urlStr containsString:@"dlink"] || [urlStr containsString:@"pcs.baidu.com"]) {
            DLog(@"Intercepted dlink: %@", urlStr);
            gInterceptedDlink = urlStr;
            gShouldInterceptDlink = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                handleInterceptedDlink();
            });
        }
    }
    return %orig;
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (url && gShouldInterceptDlink) {
        NSString *urlStr = url.absoluteString;
        if ([urlStr containsString:@"d.pcs.baidu.com"] || [urlStr containsString:@"dlink"] || [urlStr containsString:@"pcs.baidu.com"]) {
            DLog(@"Intercepted download dlink: %@", urlStr);
            gInterceptedDlink = urlStr;
            gShouldInterceptDlink = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                handleInterceptedDlink();
            });
        }
    }
    return %orig;
}

%end

%ctor {
    @autoreleasepool {
        DLog(@"BaiduPan Direct Link Helper loaded");
    }
}
