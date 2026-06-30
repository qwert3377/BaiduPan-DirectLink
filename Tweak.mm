//
//  AdBlocker.dylib - TrollStore Ad Blocker
//  Targets: GroMore(ABU) + AWM + BaiduMobAd + App's own AD system
//  Method: Runtime hooking (no %hook, no substrate dependency)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// ============================================================================
// MARK: - Configuration
// ============================================================================
static BOOL g_adBlockEnabled = YES;
static BOOL g_logEnabled = YES;

#define ADLOG(fmt, ...) do { \
    if (g_logEnabled) NSLog(@"[AdBlocker] " fmt, ##__VA_ARGS__); \
} while(0)

// ============================================================================
// MARK: - Runtime Hook Helper
// ============================================================================

static void HookMethod(Class cls, SEL originalSel, SEL newSel, IMP newImp, IMP *oldImp) {
    if (!cls) {
        ADLOG(@"Class not found for %@", NSStringFromSelector(originalSel));
        return;
    }
    Method origMethod = class_getInstanceMethod(cls, originalSel);
    if (!origMethod) {
        ADLOG(@"Method not found: %@ in %@", NSStringFromSelector(originalSel), NSStringFromClass(cls));
        return;
    }
    
    IMP origImp = method_getImplementation(origMethod);
    if (oldImp) *oldImp = origImp;
    
    class_replaceMethod(cls, newSel, origImp, method_getTypeEncoding(origMethod));
    class_replaceMethod(cls, originalSel, newImp, method_getTypeEncoding(origMethod));
    
    ADLOG(@"Hooked %@ -> %@", NSStringFromClass(cls), NSStringFromSelector(originalSel));
}

static void HookClassMethod(Class cls, SEL originalSel, IMP newImp, IMP *oldImp) {
    if (!cls) return;
    Method origMethod = class_getClassMethod(cls, originalSel);
    if (!origMethod) return;
    IMP origImp = method_getImplementation(origMethod);
    if (oldImp) *oldImp = origImp;
    method_setImplementation(origMethod, newImp);
    ADLOG(@"Hooked Class +%@.%@", NSStringFromClass(cls), NSStringFromSelector(originalSel));
}

// ============================================================================
// MARK: - Block Ad Loading (Layer 1: Prevent ads from loading)
// ============================================================================

// Generic loadAd blocker - returns void, blocks all load calls
static void __attribute__((used)) BlockLoadAd(id self, SEL _cmd) {
    ADLOG(@"BLOCKED loadAd on %@", NSStringFromClass([self class]));
    // Do nothing - ad never loads
}

// Generic loadAdData blocker
static void __attribute__((used)) BlockLoadAdData(id self, SEL _cmd) {
    ADLOG(@"BLOCKED loadAdData on %@", NSStringFromClass([self class]));
}

// loadAdData with param
static void __attribute__((used)) BlockLoadAdDataParam(id self, SEL _cmd, id param) {
    ADLOG(@"BLOCKED loadAdData:param on %@", NSStringFromClass([self class]));
}

// Generic loadAd with config
static void __attribute__((used)) BlockLoadAdConfig(id self, SEL _cmd, id config) {
    ADLOG(@"BLOCKED loadAdWithConfig on %@", NSStringFromClass([self class]));
}

// ============================================================================
// MARK: - Block Ad Showing (Layer 2: Prevent ads from displaying)
// ============================================================================

// Generic showAd blocker - returns NO
static BOOL __attribute__((used)) BlockShowAd(id self, SEL _cmd, id vc) {
    ADLOG(@"BLOCKED showAd on %@", NSStringFromClass([self class]));
    return NO;
}

// showAd with extra info
static BOOL __attribute__((used)) BlockShowAdExtra(id self, SEL _cmd, id vc, id extra) {
    ADLOG(@"BLOCKED showAd:extra: on %@", NSStringFromClass([self class]));
    return NO;
}

// showInWindow blocker
static BOOL __attribute__((used)) BlockShowInWindow(id self, SEL _cmd, id window) {
    ADLOG(@"BLOCKED showInWindow on %@", NSStringFromClass([self class]));
    return NO;
}

// showSplashAdInWindow blocker
static void __attribute__((used)) BlockShowSplash(id self, SEL _cmd, id window, id param) {
    ADLOG(@"BLOCKED showSplashAdInWindow on %@", NSStringFromClass([self class]));
}

// ============================================================================
// MARK: - Block Ad Callbacks (Layer 3: Prevent success callbacks)
// ============================================================================

// Block adLoadDidSuccess
static void __attribute__((used)) BlockAdLoadSuccess(id self, SEL _cmd) {
    ADLOG(@"BLOCKED adLoadDidSuccess on %@", NSStringFromClass([self class]));
    // Don't call original - suppress success notification
}

// Block adLoadDidFailedWithError - call it to make app think ad failed
static void __attribute__((used)) BlockAdLoadFail(id self, SEL _cmd, id error) {
    ADLOG(@"BLOCKED adLoadDidFailedWithError on %@", NSStringFromClass([self class]));
}

// Block bannerAdDidLoad
static void __attribute__((used)) BlockBannerDidLoad(id self, SEL _cmd, id banner, id ext) {
    ADLOG(@"BLOCKED bannerAd:didLoad: on %@", NSStringFromClass([self class]));
}

// Block nativeAdDidLoad
static void __attribute__((used)) BlockNativeDidLoad(id self, SEL _cmd, id nativeAd, id exts) {
    ADLOG(@"BLOCKED nativeAd:didLoad: on %@", NSStringFromClass([self class]));
}

// Block rewardedVideoAdDidLoad
static void __attribute__((used)) BlockRewardDidLoad(id self, SEL _cmd, id ext) {
    ADLOG(@"BLOCKED rewardedVideoAd:didLoad: on %@", NSStringFromClass([self class]));
}

// ============================================================================
// MARK: - Block Ad View Creation (Layer 4: Return nil/empty views)
// ============================================================================

// Return nil for ad view creation
static id __attribute__((used)) BlockReturnNil(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return nil from %@", NSStringFromSelector(_cmd));
    return nil;
}

// Return NO for isReady
static BOOL __attribute__((used)) BlockReturnNO(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return NO from %@", NSStringFromSelector(_cmd));
    return NO;
}

// Return 0 for ad count
static NSInteger __attribute__((used)) BlockReturnZero(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return 0 from %@", NSStringFromSelector(_cmd));
    return 0;
}

// Return empty array
static id __attribute__((used)) BlockReturnEmptyArray(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return empty array from %@", NSStringFromSelector(_cmd));
    return @[];
}

// Return empty dictionary
static id __attribute__((used)) BlockReturnEmptyDict(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return empty dict from %@", NSStringFromSelector(_cmd));
    return @{};
}

// Return CGSizeZero
static CGSize __attribute__((used)) BlockReturnZeroSize(id self, SEL _cmd) {
    ADLOG(@"BLOCKED return CGSizeZero from %@", NSStringFromSelector(_cmd));
    return CGSizeZero;
}

// ============================================================================
// MARK: - Block SDK Initialization (Layer 5: Stop SDK from starting)
// ============================================================================

// Block ABUAdSDKManager setup
static void __attribute__((used)) BlockSDKSetup(id self, SEL _cmd) {
    ADLOG(@"BLOCKED SDK setup on %@", NSStringFromClass([self class]));
}

// Block registerAppID
static void __attribute__((used)) BlockRegisterAppID(id self, SEL _cmd, id appID) {
    ADLOG(@"BLOCKED registerAppID: %@", appID);
}

// Block config load
static void __attribute__((used)) BlockConfigLoad(id self, SEL _cmd) {
    ADLOG(@"BLOCKED config load on %@", NSStringFromClass([self class]));
}

// Block config load with block
static void __attribute__((used)) BlockConfigLoadBlock(id self, SEL _cmd, id block) {
    ADLOG(@"BLOCKED configLoadWithBlock on %@", NSStringFromClass([self class]));
    // Call block with error to make app think config failed
    if (block) {
        NSError *error = [NSError errorWithDomain:@"AdBlocker" code:999 userInfo:@{NSLocalizedDescriptionKey: @"Ad config blocked"}];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Try to call block with error
            void (^callbackBlock)(id) = block;
            // Actually we can't easily call it, so just don't call
        });
    }
}

// ============================================================================
// MARK: - Block App's Own Ad System (ADxxx classes)
// ============================================================================

// Block ADInfoManager ad loading
static void __attribute__((used)) BlockADInfoUpdate(id self, SEL _cmd, id key, id imgSize) {
    ADLOG(@"BLOCKED ADInfoManager updateAdWithKey: %@", key);
}

// Block full screen ad
static void __attribute__((used)) BlockADFullScreen(id self, SEL _cmd, id info, id complete) {
    ADLOG(@"BLOCKED full screen ad");
    if (complete) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^completion)(BOOL) = complete;
            completion(NO); // Tell app ad was skipped/failed
        });
    }
}

// Block ADFullScreenViewController
static id __attribute__((used)) BlockADFullScreenInit(id self, SEL _cmd, id info, id complete) {
    ADLOG(@"BLOCKED ADFullScreenViewController init");
    // Return nil - ad view controller never created
    return nil;
}

// ============================================================================
// MARK: - Block URL Requests (Layer 6: Network level blocking)
// ============================================================================

// Hook NSURLSession to block ad requests
static IMP orig_dataTaskWithRequest = NULL;
static NSURLSessionDataTask * __attribute__((used)) Hook_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    NSURL *url = request.URL;
    NSString *urlStr = url.absoluteString;
    
    // Block known ad domains
    NSArray *adDomains = @[
        @"pangolin-sdk-toutiao.com",      // 穿山甲
        @"pangolin-sdk-toutiao-b.com",
        @"pangolin-sdk-toutiao1.com",
        @"adkwai.com",                     // 快手
        @"mob.com",                        // 百度Mob
        @"baidu.com",                      // 百度广告
        @"gdtimg.com",                     // 广点通
        @"gdt.qq.com",
        @"qq.com",                         // 腾讯广告
        @"adn.xiaomi.com",                 // 小米
        @"ad.xiaomi.com",
        @"adsrvr.org",                     // 其他
        @"doubleclick.net",
        @"googleadservices.com",
        @"googlesyndication.com",
        @"google-analytics.com",
        @"facebook.com/tr",                // FB追踪
        @"crashlytics.com",                // 崩溃上报（可选）
        @"firebase",
        @"appsflyer",
        @"adjust.com",
        @"umeng.com",                      // 友盟
        @"umengcloud.com",
        @"sentry.io",
    ];
    
    for (NSString *domain in adDomains) {
        if ([urlStr containsString:domain]) {
            ADLOG(@"BLOCKED URL: %@", urlStr);
            // Return a dummy task that immediately completes with error
            NSURLSessionDataTask *dummyTask = ((NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *))orig_dataTaskWithRequest)(self, _cmd, request);
            [dummyTask cancel];
            return dummyTask;
        }
    }
    
    return ((NSURLSessionDataTask * (*)(id, SEL, NSURLRequest *))orig_dataTaskWithRequest)(self, _cmd, request);
}

// ============================================================================
// MARK: - Block Specific Ad Classes (Layer 7: Class-level hooking)
// ============================================================================

static void HookAdClass(const char *className, const char *methodName, const char *methodSig, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) {
        ADLOG(@"Class %s not found (may be loaded later)", className);
        return;
    }
    SEL sel = sel_registerName(methodName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        ADLOG(@"Method %s not found in %s", methodName, className);
        return;
    }
    IMP orig = method_getImplementation(m);
    if (oldImp) *oldImp = orig;
    method_setImplementation(m, newImp);
    ADLOG(@"Hooked %s -> %s", className, methodName);
}

static void HookAdClassMethod(const char *className, const char *methodName, IMP newImp) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    SEL sel = sel_registerName(methodName);
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, newImp);
    ADLOG(@"Hooked +%s -> %s", className, methodName);
}

// ============================================================================
// MARK: - Main Constructor (Entry Point)
// ============================================================================

__attribute__((constructor))
static void AdBlockerInit() {
    ADLOG(@"=== AdBlocker.dylib loaded ===");
    
    // Wait a bit for classes to be loaded
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        ADLOG(@"Starting hooks...");
        
        // ================================================================
        // 1. Block GroMore (ABU) SDK
        // ================================================================
        
        // ABUAdSDKManager - block initialization
        HookAdClass("ABUAdSDKManager", "setup", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ABUAdSDKManager", "_setup", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ABUAdSDKManager", "registerAppID:", "v@:@", (IMP)BlockRegisterAppID, NULL);
        HookAdClass("ABUAdSDKManager", "setupAdnSDKWithConfig:complete:", "v@:@@", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ABUAdSDKManager", "setupPangleSDK", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ABUAdSDKManager", "setupAdActionManager", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ABUAdSDKManager", "setupNotifications", "v@:", (IMP)BlockSDKSetup, NULL);
        
        // ABUConfigManager - block config loading
        HookAdClass("ABUConfigManager", "getConfigWithBlock:", "v@:@", (IMP)BlockConfigLoadBlock, NULL);
        HookAdClass("ABUConfigManager", "loadConfigFromServer", "v@:", (IMP)BlockConfigLoad, NULL);
        HookAdClass("ABUConfigManager", "loadConfigFromLocalIfNeeded", "v@:", (IMP)BlockConfigLoad, NULL);
        HookAdClass("ABUConfigManager_V2", "getConfigWithBlock:", "v@:@", (IMP)BlockConfigLoadBlock, NULL);
        HookAdClass("ABUConfigManager_V2", "loadConfigFromServerIfNeeded", "v@:", (IMP)BlockConfigLoad, NULL);
        HookAdClass("ABUConfigManager_V2", "_loadConfigFromLocalIfNeeded", "v@:", (IMP)BlockConfigLoad, NULL);
        
        // ABUBaseAd - block ad loading
        HookAdClass("ABUBaseAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUBaseAd", "ex_loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUBaseAd", "preloadByUser", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUBaseAd", "loadAdDataWithConfig:", "v@:@", (IMP)BlockLoadAdConfig, NULL);
        HookAdClass("ABUBaseAd", "loadAdDataWithMediaSlotConfigIDs:sign:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        
        // ABUBannerAd
        HookAdClass("ABUBannerAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUBannerAd", "adLoadDidSuccess", "v@:", (IMP)BlockAdLoadSuccess, NULL);
        HookAdClass("ABUBannerAd", "adLoadDidFailedWithError:", "v@:@", (IMP)BlockAdLoadFail, NULL);
        
        // ABUNativeAdsManager
        HookAdClass("ABUNativeAdsManager", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUNativeAdsManager", "loadAdDataWithCount:", "v@:q", (IMP)BlockLoadAdData, NULL);
        
        // ABURewardedVideoAd
        HookAdClass("ABURewardedVideoAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABURewardedVideoAd", "showAdFromRootViewController:", "B@:@", (IMP)BlockShowAd, NULL);
        HookAdClass("ABURewardedVideoAd", "showAdFromRootViewController:extroInfos:", "B@:@@", (IMP)BlockShowAdExtra, NULL);
        HookAdClass("ABURewardedVideoAd", "showAdFromRootViewController:extraInfos:", "B@:@@", (IMP)BlockShowAdExtra, NULL);
        HookAdClass("ABURewardedVideoAd", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        HookAdClass("ABURewardedVideoAd", "adLoadDidSuccess", "v@:", (IMP)BlockAdLoadSuccess, NULL);
        
        // ABUFullscreenVideoAd
        HookAdClass("ABUFullscreenVideoAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUFullscreenVideoAd", "showAdFromRootViewController:", "B@:@", (IMP)BlockShowAd, NULL);
        HookAdClass("ABUFullscreenVideoAd", "showAdFromRootViewController:extroInfos:", "B@:@@", (IMP)BlockShowAdExtra, NULL);
        HookAdClass("ABUFullscreenVideoAd", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        
        // ABUInterstitialAd
        HookAdClass("ABUInterstitialAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUInterstitialAd", "showAdFromRootViewController:", "B@:@", (IMP)BlockShowAd, NULL);
        HookAdClass("ABUInterstitialAd", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        
        // ABUSplashAd
        HookAdClass("ABUSplashAd", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUSplashAd", "showInWindow:", "B@:@", (IMP)BlockShowInWindow, NULL);
        HookAdClass("ABUSplashAd", "showInWindowWithBlock:", "v@:@", (IMP)BlockShowSplash, NULL);
        HookAdClass("ABUSplashAd", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        HookAdClass("ABUSplashAd", "adLoadDidSuccess", "v@:", (IMP)BlockAdLoadSuccess, NULL);
        
        // ABUNativeAdView / ABUDrawAdView
        HookAdClass("ABUNativeAdView", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUDrawAdView", "loadAdData", "v@:", (IMP)BlockLoadAdData, NULL);
        
        // ABUAdLoader - block all ad loading
        HookAdClass("ABUAdLoader", "loadAdsWithConfigs:limitSeconds:param:ext:", "v@:@@d@", (IMP)BlockLoadAdData, NULL);
        HookAdClass("ABUAdLoader", "beginLoadMediaAdIfNeededWithConfig:andParam:loadAction:", "v@:@@@", (IMP)BlockLoadAdData, NULL);
        
        // ABUMediationWaterfallIMP - block waterfall requests
        HookAdClass("ABUMediationWaterfallIMP", "startWaterfallRequestWithParams:adReuseIdentifier:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        
        // ================================================================
        // 2. Block AWM SDK
        // ================================================================
        
        // AWMCSJCustomConfigAdapter - block CSJ init
        HookAdClass("AWMCSJCustomConfigAdapter", "initializeAdapterWithConfiguration:", "v@:@", (IMP)BlockSDKSetup, NULL);
        
        // AWMGDTCustomConfigAdapter - block GDT init
        HookAdClass("AWMGDTCustomConfigAdapter", "initializeAdapterWithConfiguration:", "v@:@", (IMP)BlockSDKSetup, NULL);
        
        // AWMBaiduCustomConfigAdapter - block Baidu init
        HookAdClass("AWMBaiduCustomConfigAdapter", "initializeAdapterWithConfiguration:", "v@:@", (IMP)BlockSDKSetup, NULL);
        
        // AWMGroMoreCustomConfigAdapter - block GroMore init
        HookAdClass("AWMGroMoreCustomConfigAdapter", "initializeAdapterWithConfiguration:", "v@:@", (IMP)BlockSDKSetup, NULL);
        
        // Generic AWM ad loading
        HookAdClass("AWMCSJCustomBannerAdapter", "loadAdWithPlacementId:parameter:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        HookAdClass("AWMCSJCustomInterstitialAdapter", "loadAdWithPlacementId:parameter:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        HookAdClass("AWMCSJCustomRewardedVideoAdapter", "loadAdWithPlacementId:parameter:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        HookAdClass("AWMCSJCustomSplashAdapter", "loadAdWithPlacementId:parameter:", "v@:@@", (IMP)BlockLoadAdData, NULL);
        HookAdClass("AWMCSJCustomNativeAdapter", "loadAdWithPlacementId:adSize:parameter:", "v@:@@@", (IMP)BlockLoadAdData, NULL);
        
        // AWM show methods
        HookAdClass("AWMCSJCustomInterstitialAdapter", "showAdFromRootViewController:parameter:", "B@:@@", (IMP)BlockShowAd, NULL);
        HookAdClass("AWMCSJCustomRewardedVideoAdapter", "showAdFromRootViewController:parameter:", "B@:@@", (IMP)BlockShowAd, NULL);
        HookAdClass("AWMCSJCustomSplashAdapter", "showSplashAdInWindow:parameter:", "v@:@@", (IMP)BlockShowSplash, NULL);
        
        // ================================================================
        // 3. Block BaiduMobAd SDK
        // ================================================================
        
        // BaiduMobAdExpressFullScreenVideo
        HookAdClass("BaiduMobAdExpressFullScreenVideo", "load", "v@:", (IMP)BlockLoadAd, NULL);
        HookAdClass("BaiduMobAdExpressFullScreenVideo", "show", "v@:", (IMP)BlockLoadAd, NULL);
        HookAdClass("BaiduMobAdExpressFullScreenVideo", "showFromViewController:", "v@:@", (IMP)BlockShowAd, NULL);
        HookAdClass("BaiduMobAdExpressFullScreenVideo", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        
        // BaiduMobAdExpressInterstitial
        HookAdClass("BaiduMobAdExpressInterstitial", "load", "v@:", (IMP)BlockLoadAd, NULL);
        HookAdClass("BaiduMobAdExpressInterstitial", "show", "v@:", (IMP)BlockLoadAd, NULL);
        HookAdClass("BaiduMobAdExpressInterstitial", "showFromViewController:", "v@:@", (IMP)BlockShowAd, NULL);
        HookAdClass("BaiduMobAdExpressInterstitial", "isReady", "B@:", (IMP)BlockReturnNO, NULL);
        
        // BaiduMobAd bookmark/splash components
        HookAdClass("BaiduMobAdBookmarkContainerView", "renderBookmarkView", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("BaiduMobAdBookmarkContainerView", "showBookmarkAnimation", "v@:", (IMP)BlockSDKSetup, NULL);
        
        // BaiduMobAd barrage
        HookAdClass("BaiduMobAdbarrageView", "showBarrage", "v@:", (IMP)BlockSDKSetup, NULL);
        
        // BaiduMobAd CPU (content recommendation)
        HookAdClass("BaiduMobAdCPUSlot", "loadCPUWithPage:Channels:IsShowAd:", "v@:iiB", (IMP)BlockLoadAdData, NULL);
        
        // ================================================================
        // 4. Block App's Own AD System (ADxxx)
        // ================================================================
        
        // ADInfoManager - block all ad updates
        HookAdClass("ADInfoManager", "updateAdWithKey:imgSize:", "v@:@@", (IMP)BlockADInfoUpdate, NULL);
        HookAdClass("ADInfoManager", "updateStartupAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateHotStartupAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateDeviceListAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateDeviceTopAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateDeviceReserveAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateMineReserveAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateClientActivityAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateRemoteEndAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "updateRemoteEndInsertAD", "v@:", (IMP)BlockSDKSetup, NULL);
        HookAdClass("ADInfoManager", "getAdModeWithKey:imgSize:complete:", "v@:@@@", (IMP)BlockADInfoUpdate, NULL);
        
        // ADFullScreenViewController - block splash/interstitial
        HookAdClass("ADFullScreenViewController", "initWithADInfo:complete:", "@@:@@", (IMP)BlockADFullScreenInit, NULL);
        
        // ADTESTViewController - hide test page
        HookAdClass("ADTESTViewController", "viewDidLoad", "v@:", (IMP)BlockSDKSetup, NULL);
        
        // ================================================================
        // 5. Block Network Requests (NSURLSession)
        // ================================================================
        
        Class nsurlsession = objc_getClass("NSURLSession");
        if (nsurlsession) {
            Method m = class_getInstanceMethod(nsurlsession, sel_registerName("dataTaskWithRequest:"));
            if (m) {
                orig_dataTaskWithRequest = method_getImplementation(m);
                method_setImplementation(m, (IMP)Hook_dataTaskWithRequest);
                ADLOG(@"Hooked NSURLSession dataTaskWithRequest:");
            }
        }
        
        // Also hook dataTaskWithURL:
        Class nsurlsessionCls = objc_getClass("NSURLSession");
        if (nsurlsessionCls) {
            Method m2 = class_getInstanceMethod(nsurlsessionCls, sel_registerName("dataTaskWithURL:"));
            if (m2) {
                IMP orig = method_getImplementation(m2);
                method_setImplementation(m2, imp_implementationWithBlock(^NSURLSessionDataTask *(id self, NSURL *url) {
                    NSString *urlStr = url.absoluteString;
                    NSArray *adDomains = @[
                        @"pangolin-sdk-toutiao", @"adkwai", @"baidu.com/mobad",
                        @"gdtimg.com", @"gdt.qq.com", @"adsrvr",
                        @"doubleclick", @"googleadservices", @"googlesyndication",
                        @"facebook.com/tr", @"crashlytics", @"firebase",
                        @"appsflyer", @"adjust.com", @"umeng",
                    ];
                    for (NSString *domain in adDomains) {
                        if ([urlStr containsString:domain]) {
                            ADLOG(@"BLOCKED NSURL dataTask: %@", urlStr);
                            // Return and immediately cancel
                            NSURLSessionDataTask *task = ((NSURLSessionDataTask * (*)(id, NSURL *))orig)(self, url);
                            [task cancel];
                            return task;
                        }
                    }
                    return ((NSURLSessionDataTask * (*)(id, NSURL *))orig)(self, url);
                }));
                ADLOG(@"Hooked NSURLSession dataTaskWithURL:");
            }
        }
        
        // ================================================================
        // 6. Block UIViewController ad presentation
        // ================================================================
        
        // Hook presentViewController to block ad VCs
        Class vcClass = [UIViewController class];
        Method presentM = class_getInstanceMethod(vcClass, @selector(presentViewController:animated:completion:));
        if (presentM) {
            IMP origPresent = method_getImplementation(presentM);
            method_setImplementation(presentM, imp_implementationWithBlock(^void(id self, UIViewController *vc, BOOL animated, id completion) {
                NSString *className = NSStringFromClass([vc class]);
                NSArray *adVCs = @[
                    @"ADFullScreenViewController",
                    @"BaiduMobAdExpressFullScreenVideoViewController",
                    @"BaiduMobAdExpressIntViewController",
                    @"ABUSplashAd",
                    @"ABURewardAgainView",
                    @"BaiduMobAdActionRootController",
                    @"BaiduMobAdBookmarkContainerView",
                ];
                for (NSString *adVC in adVCs) {
                    if ([className isEqualToString:adVC] || [className containsString:@"Ad"] || [className containsString:@"AD"]) {
                        ADLOG(@"BLOCKED presentViewController: %@", className);
                        if (completion) {
                            void (^comp)(void) = completion;
                            comp();
                        }
                        return;
                    }
                }
                ((void (*)(id, UIViewController *, BOOL, id))origPresent)(self, vc, animated, completion);
            }));
            ADLOG(@"Hooked UIViewController presentViewController:");
        }
        
        // ================================================================
        // 7. Hide existing ad views
        // ================================================================
        
        // Hook UIView didMoveToSuperview to hide ad views
        Class uiviewClass = [UIView class];
        Method didMoveM = class_getInstanceMethod(uiviewClass, @selector(didMoveToSuperview));
        if (didMoveM) {
            IMP origDidMove = method_getImplementation(didMoveM);
            method_setImplementation(didMoveM, imp_implementationWithBlock(^void(id self) {
                NSString *className = NSStringFromClass([self class]);
                // Hide known ad view classes
                if ([className containsString:@"Ad"] || [className containsString:@"AD"] ||
                    [className containsString:@"Banner"] || [className containsString:@"Splash"] ||
                    [className containsString:@"Native"] || [className containsString:@"Interstitial"] ||
                    [className containsString:@"Reward"] || [className containsString:@"Express"]) {
                    UIView *view = self;
                    if (view.superview) {
                        ADLOG(@"HIDING ad view: %@", className);
                        view.hidden = YES;
                        view.alpha = 0;
                        CGRect f = view.frame;
                        f.size = CGSizeZero;
                        view.frame = f;
                    }
                }
                ((void (*)(id))origDidMove)(self);
            }));
            ADLOG(@"Hooked UIView didMoveToSuperview");
        }
        
        ADLOG(@"=== All hooks installed ===");
    });
}
