//
//  BaiduNetdiskAdBlocker.mm
//  百度网盘去广告插件 (纯运行时版)
//  版本: 1.2.2
//  编译: Theos / Logos
//  修复1: %ctor -> __attribute__((constructor)) 避免 Logos 预处理器错误
//  修复2: 删除未使用的 hooked 变量，避免 -Werror,-Wunused-but-set-variable
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// MARK: - 运行时动态 Hook (唯一方案)
// ============================================================

static void __attribute__((optnone)) blk_void(id self, SEL _cmd) { }
static id __attribute__((optnone)) blk_nil(id self, SEL _cmd) { return nil; }
static BOOL __attribute__((optnone)) blk_no(id self, SEL _cmd) { return NO; }

// 修复1: 使用 C 构造函数替代 %ctor，避免 Logos 预处理器 "expected unqualified-id" 错误
// 当 .mm 文件中没有 %hook 块时，Logos 无法解析 %ctor，必须用 __attribute__((constructor))
static void __attribute__((constructor)) adBlockerInit() {
    // 广告SDK类前缀列表
    NSArray *adPrefixes = @[@"ABU", @"CSJ", @"BaiduMobAd", @"GDT", @"Wind", @"Sigmob", @"AWM", @"Pangle"];

    // void 方法选择器
    NSArray *voidSels = @[
        @"loadAdData", @"loadAd", @"load", @"loadBiddingAd", @"preloadAdWithType:",
        @"showAdFromRootViewController:", @"showInWindow:", @"showInWindowWithBlock:",
        @"show", @"showFromViewController:", @"showSplashViewInRootViewController:",
        @"showCardViewInRootViewController:", @"showZoomOutViewInRootViewController:",
        @"play", @"replay", @"startPlayVideo", @"render", @"_setup",
        @"setupUserConfig", @"setupAPMConfig", @"setupTNCConfig", @"setupApplogConfig",
        @"setupSDKConfig", @"setupModuleControl", @"setupAdnDetectManager",
        @"setupUpperDetectManager", @"setupPangleSDK", @"setupAdActionManager",
        @"_updatePC", @"_updateRulesWithConfig", @"setupTrackerConfig",
        @"setupLogConfigViaConfig", @"setupAdnSDKWithConfig:", @"setupAdnSDKWithConfigSYNC:",
        @"configLoadDidSuccess", @"loadConfigFromServerIfNeeded", @"loadConfigFromServer",
        @"loadConfigFromLocalIfNeeded", @"configLoadForServerDidSuccess_V2",
        @"_loadConfigFromServerWithTimes:", @"initializeConfig", @"updateConfig",
        @"insertAd:", @"clearAdListWithRequestID:", @"setup",
        @"canLoadForFreqWithBlock:", @"updateLoadRulesWithTimes:",
        @"updateErrorCodesListWithConfig:", @"updateAllHistoriesWithNewConfigsRule:",
        @"loadAdsWithConfigs:", @"_notifyLoadFinishWithParam:",
        @"notifyMediaLoadSuccessWithLoadID:", @"notifyMediaLoadFailedWithLoadID:",
        @"notifyMediaLoadWillBeginWithConfig:", @"beginLoadMediaAdIfNeededWithConfig:",
        @"willLoadMediaAdUsingRules:", @"ex_loadAdData",
        @"loadAdDataWithMediaSlotConfigIDs:", @"preloadByUser",
        @"checkPreloadCacheExistWithWaterfall:", @"adLoadDidSuccess",
        @"adLoadDidFailedWithError:", @"adViewDidShow",
        @"waterfallDidLoadSuccess", @"startLoadWithAd:",
        @"preloadAdFromAd:", @"preloadAdsWithInfos:", @"checkPreloadExistWithAd:",
        @"bannerAdDidLoad", @"bannerCarouselViewDidShowBannerAd",
        @"loadAdAndShowInWindow:", @"loadAdAndShowFullScreenInWindow:",
        @"loadAdWithAdCount:", @"loadAdWithCount:",
        @"loadFullScreenAd", @"_loadAdData", @"updateScrollViewPlayerToCell",
        @"updateNoramlPlayerWithContainerView:", @"preStrategyWithPlacementId:",
        @"layoutDisplayArea", @"handleCloud", @"bubbleShow", @"showSlideGestureView",
        @"nativeAdExpressSuccessRender", @"pause", @"reload",
        @"showPureImage", @"showResource", @"showImage", @"showGifImage",
        @"setAudioSessionCategory", @"viewDidLoad", @"viewWillAppear:",
        @"setModelWithDictionary:", @"relayoutSubViews",
        @"loadMediaAdWithAdapter:", @"showInWindow:", @"showInWindowWithBlock:",
        @"_setup", @"registerAppID:", @"getConfigWithBlock:",
        @"loadAdAndShowInWindow:", @"loadAdAndShowFullScreenInWindow:",
        @"loadAd", @"showAdInWindow:", @"preload",
        @"loadAdDataWithCount:", @"loadAdDataWithCount:",
        @"playTheIndexPath:", @"showAdFromRootViewController:",
        @"showSplashViewInRootViewController:", @"showCardViewInRootViewController:",
        @"showZoomOutViewInRootViewController:", @"startPlayVideo", @"render", @"replay"
    ];

    // nil 返回方法选择器
    NSArray *nilSels = @[
        @"init", @"initWithAdUnitID:", @"initWithSlot:", @"initWithSlotID:",
        @"initWithPlacementId:", @"initWithAdObject:", @"initWithAdRendererHelper:",
        @"initWithAdRender:", @"initWithFrame:", @"initWithDictonary:",
        @"initCpuInstanceWithDictonary:", @"initWithOriginJson:",
        @"initWithSplashMediaRit:", @"initWithDictionary:",
        @"initWithSplashMediationRit:", @"initWithMediationSlotConfig:",
        @"initWithMediationRit:", @"initWithRequest:",
        @"initWithMediatedNativeAd:", @"initWithMaterial:",
        @"initWithExpressView:", @"initWithAdPackage:",
        @"initWithBidResponse:", @"initWithConfig:",
        @"initWithAd:", @"initVideoWithFrame:",
        @"initWithNativeAd:", @"initWithSplashMediationRit:",
        @"mediaSlotConfigWithMediationSlotID:", @"mediationSlotConfig",
        @"getAdStrategyWithRequest:", @"initWithMediationSlotConfig:",
        @"initWithDictonary:", @"initCpuInstanceWithDictonary:",
        @"initWithOriginJson:", @"initWithAdUnitID:",
        @"initWithSplashMediaRit:", @"initWithSplashMediationRit:",
        @"initWithDictionary:", @"initWithMediationSlotConfig:",
        @"initWithMediationRit:", @"initWithRequest:",
        @"initWithMediatedNativeAd:", @"initWithMaterial:",
        @"initWithExpressView:", @"initWithAdPackage:",
        @"initWithBidResponse:", @"initWithConfig:",
        @"initWithAd:", @"initVideoWithFrame:",
        @"initWithNativeAd:", @"initWithSplashMediationRit:",
        @"mediaSlotConfigWithMediationSlotID:", @"mediationSlotConfig",
        @"getAdStrategyWithRequest:"
    ];

    // NO 返回方法选择器
    NSArray *noSels = @[
        @"canMediationRequestForFreq", @"canMediationRequestForAppFreq",
        @"canMediationRequestForPeriod", @"canMediaRequestForFreqWithConfig:",
        @"canMediaRequestForPeriodWithConfig:", @"canMediaRequestForErrorCodeControlWithConfig:",
        @"canRequestWithType:", @"instancesRespondToSelector:"
    ];

    // 修复2: 删除 hooked 计数器变量，避免 -Werror,-Wunused-but-set-variable
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);

    for (unsigned int i = 0; i < classCount; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        BOOL isAdClass = NO;
        for (NSString *prefix in adPrefixes) {
            if ([name hasPrefix:prefix]) {
                isAdClass = YES;
                break;
            }
        }
        if (!isAdClass) continue;

        for (NSString *selStr in voidSels) {
            SEL sel = NSSelectorFromString(selStr);
            if ([classes[i] instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(classes[i], sel);
                if (m) {
                    method_setImplementation(m, (IMP)blk_void);
                }
            }
        }
        for (NSString *selStr in nilSels) {
            SEL sel = NSSelectorFromString(selStr);
            if ([classes[i] instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(classes[i], sel);
                if (m) {
                    method_setImplementation(m, (IMP)blk_nil);
                }
            }
        }
        for (NSString *selStr in noSels) {
            SEL sel = NSSelectorFromString(selStr);
            if ([classes[i] instancesRespondToSelector:sel]) {
                Method m = class_getInstanceMethod(classes[i], sel);
                if (m) {
                    method_setImplementation(m, (IMP)blk_no);
                }
            }
        }
    }
    free(classes);
}
