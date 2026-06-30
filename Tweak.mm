//
//  BaiduNetdiskAdBlocker.mm
//  百度网盘去广告插件 (精简版)
//  版本: 1.1.0
//  编译: Theos / Logos
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// MARK: - 通用工具
// ============================================================

static void Log(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSLog(@"[AdBlock] %@", [[NSString alloc] initWithFormat:fmt arguments:args]);
    va_end(args);
}

// ============================================================
// MARK: - ABU (GroMore/穿山甲聚合) SDK 拦截
// ============================================================

%hook ABUAdSDKManager
- (id)init { Log(@"ABU SDK init blocked"); return nil; }
- (void)_setup { }
- (void)registerAppID:(NSString *)appID { }
%end

%hook ABUConfigManager
- (id)init { return nil; }
- (void)getConfigWithBlock:(id)block {
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^cb)(id, NSError *) = block;
            cb(nil, [NSError errorWithDomain:@"AdBlock" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Blocked"}]);
        });
    }
}
%end

%hook ABUConfigManager_V2
- (id)init { return nil; }
- (void)getConfigWithBlock:(id)block {
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^cb)(id, NSError *) = block;
            cb(nil, [NSError errorWithDomain:@"AdBlock" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Blocked"}]);
        });
    }
}
%end

%hook ABUAdStorageManager
- (id)init { return nil; }
- (void)insertAd:(id)ad { }
%end

%hook ABUAdActionManager
- (id)init { return nil; }
- (BOOL)canRequestWithType:(NSInteger)type { return NO; }
%end

%hook ABUAdLoader
- (id)init { return nil; }
- (id)initWithMediationSlotConfig:(id)config { return nil; }
- (void)loadAdsWithConfigs:(id)configs { }
%end

%hook ABUBaseAd
- (id)init { return nil; }
- (id)initWithMediationRit:(NSString *)rit { return nil; }
- (void)loadAdData { }
%end

// 各类型广告加载器
%hook ABUBannerAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUSplashAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABURewardedVideoAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUFullscreenVideoAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUInterstitialAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUInterstitialProAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUNativeAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

%hook ABUDrawAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { }
%end

// 各类型广告展示类
%hook ABUBannerAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)loadAdData { }
%end

%hook ABUSplashAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)showInWindow:(UIWindow *)window { }
- (void)showInWindowWithBlock:(id)block { }
- (void)loadAdData { }
%end

%hook ABURewardedVideoAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
- (void)loadAdData { }
%end

%hook ABUFullscreenVideoAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
- (void)loadAdData { }
%end

%hook ABUInterstitialAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
- (void)loadAdData { }
%end

%hook ABUInterstitialProAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
- (void)loadAdData { }
%end

%hook ABUNativeAdsManager
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (id)initWithSlot:(id)slot { return nil; }
- (void)loadAdData { }
%end

%hook ABUNativeAdView
- (id)initWithSlot:(id)slot { return nil; }
- (id)initWithAdPackage:(id)package { return nil; }
- (id)initWithExpressView:(id)view { return nil; }
- (void)loadAdData { }
%end

%hook ABUDrawAdsManager
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
- (void)loadAdData { }
%end

%hook ABUDrawAdView
- (id)initWithSlot:(id)slot { return nil; }
- (id)initWithAdPackage:(id)package { return nil; }
- (id)initWithExpressView:(id)view { return nil; }
- (void)loadAdData { }
%end

// 瀑布流/竞价
%hook ABUMediationWaterfallIMP
- (id)init { return nil; }
- (id)initWithConfig:(id)config { return nil; }
- (BOOL)canMediationRequestForFreq { return NO; }
- (BOOL)canMediationRequestForAppFreq { return NO; }
- (BOOL)canMediationRequestForPeriod { return NO; }
%end

%hook ABUMediationWaterfallFactory
- (id)init { return nil; }
%end

%hook ABUMediationWaterfallExtra
- (void)startLoadWithAd:(id)ad { }
%end

// 预加载
%hook ABUPreloadManager
- (id)init { return nil; }
- (void)preloadAdFromAd:(id)ad { }
%end

// 轮播广告
%hook ABUCarouselBannerAd
- (id)initWithAdUnitID:(NSString *)adUnitID { return nil; }
%end

%hook ABUInterstitialProCarouselManager
- (id)initWithAd:(id)ad { return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

// 个性化配置适配器
%hook ABUPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUPanglePersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUBaiduPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUGdtPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUCsjPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUKsPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUKlevinPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUMintegralPersonaliseConfigAdapter
- (id)init { return nil; }
%end

%hook ABUAdmobPersonaliseConfigAdapter
- (id)init { return nil; }
%end

// 服务器竞价
%hook ABUCustomServerBiddingManager
- (id)init { return nil; }
%end

%hook ABUDefaultServerBiddingManager
- (id)init { return nil; }
%end

// 策略管理器
%hook ABUMediaSlotConfig
- (id)init { return nil; }
- (id)initWithSplashMediaRit:(id)rit { return nil; }
- (id)initWithDictionary:(id)dict { return nil; }
- (id)mediaSlotConfigWithMediationSlotID:(NSString *)slotID { return nil; }
%end

%hook ABUMediationSlotConfig
- (id)init { return nil; }
- (id)initWithSplashMediationRit:(id)rit { return nil; }
- (id)initWithDictionary:(id)dict { return nil; }
- (id)mediationSlotConfig { return nil; }
%end

%hook ABUMediaSlotConfigGroup
- (id)initWithMediationSlotConfig:(id)config { return nil; }
%end

// ============================================================
// MARK: - CSJ (穿山甲/Pangle) SDK 拦截
// ============================================================

%hook CSJSplashAd
- (id)initWithSlotID:(NSString *)slotID { return nil; }
- (id)initWithSlot:(id)slot { return nil; }
- (void)loadAdData { }
- (void)showSplashViewInRootViewController:(UIViewController *)vc { }
%end

%hook CSJNativeExpressAdManager
- (id)initWithSlot:(id)slot { return nil; }
- (void)loadAdDataWithCount:(NSInteger)count { }
- (void)loadAdData { }
%end

%hook CSJNativeExpressRewardedVideoAd
- (id)initWithSlotID:(NSString *)slotID { return nil; }
- (id)initWithSlot:(id)slot { return nil; }
- (void)loadAdData { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook CSJNativeExpressFullscreenVideoAd
- (id)initWithSlotID:(NSString *)slotID { return nil; }
- (id)initWithSlot:(id)slot { return nil; }
- (void)loadAdData { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook CSJNativeExpressAdView
- (void)play { }
- (void)replay { }
- (void)startPlayVideo { }
%end

%hook CSJMaterialMeta
- (id)initWithDictionary:(id)dict { return nil; }
- (id)init { return nil; }
%end

// ============================================================
// MARK: - BaiduMobAd (百度广告) SDK 拦截
// ============================================================

%hook BaiduMobAdExpressFullScreenVideo
- (id)init { return nil; }
- (void)load { }
- (void)loadBiddingAd { }
- (void)show { }
- (void)showFromViewController:(UIViewController *)vc { }
%end

%hook BaiduMobAdExpressInterstitial
- (id)init { return nil; }
- (void)load { }
- (void)loadBiddingAd { }
- (void)show { }
- (void)showFromViewController:(UIViewController *)vc { }
%end

%hook BaiduMobAdExpressNativeView
- (id)initWithAdObject:(id)adObject { return nil; }
- (void)render { }
%end

%hook BaiduMobAdRenderer
- (id)initWithAdRendererHelper:(id)helper { return nil; }
- (void)load { }
%end

%hook BaiduMobAdVideoRenderer
- (id)initWithAdRendererHelper:(id)helper { return nil; }
- (void)load { }
%end

%hook BaiduMobAdHTMLRenderer
- (id)initWithAdRendererHelper:(id)helper { return nil; }
- (void)load { }
%end

%hook BaiduMobAdH5Renderer
- (void)load { }
%end

%hook BaiduMobAdImageRenderer
- (void)load { }
%end

%hook BaiduMobAdGifImageRenderer
- (void)showResource { }
%end

%hook BaiduMobAdNativeVideoView
- (id)initWithFrame:(CGRect)frame { return nil; }
%end

%hook BaiduMobAdNativeCPUVideoView
- (id)initWithFrame:(CGRect)frame { return nil; }
%end

%hook BaiduMobAdExpressIntViewController
- (id)initWithAdRender:(id)render { return nil; }
%end

%hook BaiduMobAdRewardVideoRenderer
- (id)initWithAdRendererHelper:(id)helper { return nil; }
%end

%hook BaiduMobAdSmartFeedView
- (id)initWithFrame:(CGRect)frame { return nil; }
%end

%hook BaiduMobAdMraidBridge
- (id)init { return nil; }
%end

%hook BaiduMobAdInstance
- (id)initWithDictonary:(id)dict { return nil; }
- (id)initCpuInstanceWithDictonary:(id)dict { return nil; }
%end

%hook BaiduMobAdComponentModel
- (id)initWithOriginJson:(id)json { return nil; }
%end

// ============================================================
// MARK: - GDT (广点通/Tencent Ads) SDK 拦截
// ============================================================

%hook GDTSplashAd
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAdAndShowInWindow:(UIWindow *)window { }
%end

%hook GDTSplashAdImp
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
- (void)showAdInWindow:(UIWindow *)window { }
- (void)preload { }
%end

%hook GDTRewardVideoAd
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook GDTUnifiedInterstitialAd
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
- (void)loadFullScreenAd { }
%end

%hook GDTUnifiedInterstitialAdImp
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
%end

%hook GDTNativeExpressAd
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
%end

%hook GDTNativeExpressAdImp
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
%end

%hook GDTNativeExpressAdView
- (void)render { }
%end

%hook GDTNativeExpressAdViewImp
- (void)render { }
- (void)play { }
%end

%hook GDTUnifiedNativeAd
- (id)initWithPlacementId:(NSString *)placementId { return nil; }
- (void)loadAd { }
%end

%hook GDTADConfiguration
- (id)init { return nil; }
%end

// ============================================================
// MARK: - Wind/Sigmob SDK 拦截
// ============================================================

%hook WindMillRewardVideoAdManager
- (id)init { return nil; }
- (void)loadAdData { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook WindMillInterstitialAdManager
- (id)initWithRequest:(id)request { return nil; }
- (void)loadAdData { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook WindMillBannerAdManager
- (id)initWithRequest:(id)request { return nil; }
- (void)loadAdData { }
- (void)showAdFromRootViewController:(UIViewController *)vc { }
%end

%hook WindMillNativeAdsManager
- (id)initWithRequest:(id)request { return nil; }
- (void)_loadAdData { }
- (void)loadAdDataWithCount:(NSInteger)count { }
%end

%hook WindMillNativeAd
- (id)initWithMediatedNativeAd:(id)ad { return nil; }
%end

%hook WindMillNativeAdView
- (id)initWithFrame:(CGRect)frame { return nil; }
- (void)play { }
%end

%hook WindMillBannerView
- (id)initWithRequest:(id)request { return nil; }
- (void)loadAdData { }
%end

%hook WindMillNativeInterstitialViewController
- (id)init { return nil; }
%end

%hook WindPlayerController
- (void)playTheIndexPath:(NSIndexPath *)indexPath { }
- (void)updateScrollViewPlayerToCell { }
%end

%hook WindmillStrategyManager
- (id)init { return nil; }
- (void)preStrategyWithPlacementId:(NSString *)placementId { }
- (id)getAdStrategyWithRequest:(id)request { return nil; }
%end

%hook SigmobFullscreenAdViewController
- (id)initWithBidResponse:(id)response { return nil; }
%end

// ============================================================
// MARK: - 通用广告视图/控制器拦截
// ============================================================

%hook CSJRewardedVideoDisplayViewController
- (id)init { return nil; }
%end

%hook CSJVideoDetailPageViewController
- (id)init { return nil; }
%end

%hook CSJExpressRewardFullScreenVM
- (id)init { return nil; }
%end

%hook CSJWebViewControllerViewModel
- (id)init { return nil; }
%end

%hook CSJPlayableWebVM
- (id)init { return nil; }
%end

%hook CSJRewardedVideoWebViewControllerVM
- (id)init { return nil; }
%end

%hook CSJRewardFullScreenBaseVM
- (id)init { return nil; }
%end

%hook CSJDynamicRenderTemplateStrategy
- (id)init { return nil; }
%end

%hook CSJNativeAd
- (id)init { return nil; }
%end

%hook CSJVideoAdView
- (id)initWithNativeAd:(id)nativeAd { return nil; }
%end

%hook CSJNativeExpressRewardedVideoAdView
- (id)initWithFrame:(CGRect)frame { return nil; }
- (void)startPlayVideo { }
%end

%hook CSJNativeExpressRewardDrawAdView
- (id)initWithFrame:(CGRect)frame { return nil; }
- (void)render { }
- (void)replay { }
%end

%hook CSJNativeExpressRewardedVideoAdDisplayViewController
- (id)init { return nil; }
%end

%hook CSJNativeExpressRewardedVideoAdViewController
- (id)init { return nil; }
%end

%hook CSJNativeExpressRewardDrawAdViewController
- (id)init { return nil; }
%end

%hook CSJFullScreenInterstitialAdView
- (id)initWithMaterial:(id)material { return nil; }
%end

%hook CSJRewardedVideoAdViewController
- (id)init { return nil; }
%end

// ============================================================
// MARK: - 运行时动态 Hook (兜底方案)
// ============================================================

static void __attribute__((optnone)) blk_void(id self, SEL _cmd) { }
static id __attribute__((optnone)) blk_nil(id self, SEL _cmd) { return nil; }
static BOOL __attribute__((optnone)) blk_no(id self, SEL _cmd) { return NO; }

%ctor {
    Log(@"百度网盘去广告插件 v1.1.0 已加载");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSArray *voidSels = @[@"loadAdData", @"loadAd", @"load", @"loadBiddingAd", @"preloadAdWithType:",
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
                              @"setModelWithDictionary:", @"relayoutSubViews"];

        NSArray *nilSels = @[@"init", @"initWithAdUnitID:", @"initWithSlot:", @"initWithSlotID:",
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
                             @"getAdStrategyWithRequest:", @"initWithMediationSlotConfig:"];

        NSArray *noSels = @[@"canMediationRequestForFreq", @"canMediationRequestForAppFreq",
                            @"canMediationRequestForPeriod", @"canMediaRequestForFreqWithConfig:",
                            @"canMediaRequestForPeriodWithConfig:", @"canMediaRequestForErrorCodeControlWithConfig:",
                            @"canRequestWithType:", @"instancesRespondToSelector:"];

        int hooked = 0;
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name hasPrefix:@"ABU"] || [name hasPrefix:@"CSJ"] || [name hasPrefix:@"BaiduMobAd"] ||
                [name hasPrefix:@"GDT"] || [name hasPrefix:@"Wind"] || [name hasPrefix:@"Sigmob"] ||
                [name hasPrefix:@"AWM"] || [name hasPrefix:@"Pangle"]) {

                for (NSString *selStr in voidSels) {
                    SEL sel = NSSelectorFromString(selStr);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method m = class_getInstanceMethod(classes[i], sel);
                        if (m) { method_setImplementation(m, (IMP)blk_void); hooked++; }
                    }
                }
                for (NSString *selStr in nilSels) {
                    SEL sel = NSSelectorFromString(selStr);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method m = class_getInstanceMethod(classes[i], sel);
                        if (m) { method_setImplementation(m, (IMP)blk_nil); hooked++; }
                    }
                }
                for (NSString *selStr in noSels) {
                    SEL sel = NSSelectorFromString(selStr);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method m = class_getInstanceMethod(classes[i], sel);
                        if (m) { method_setImplementation(m, (IMP)blk_no); hooked++; }
                    }
                }
            }
        }
        free(classes);
        Log(@"运行时兜底: %d 个方法已Hook", hooked);
    });
}
