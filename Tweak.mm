//
//  BaiduNetdiskAdBlocker.mm
//  百度网盘去广告插件 (GroMore聚合SDK + 多广告源拦截)
//  版本: 1.0.0
//  编译: Theos / Logos
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================================
// MARK: - 通用工具函数
// ============================================================

static void LogAdBlock(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[AdBlock] %@", msg);
}

// ============================================================
// MARK: - ABU (GroMore/穿山甲聚合) SDK 拦截
// ============================================================

// 1. SDK初始化拦截 - 阻止广告SDK注册和配置加载
%hook ABUAdSDKManager

- (id)init {
    LogAdBlock(@"ABUAdSDKManager init blocked");
    return nil;
}

- (void)_setup {
    LogAdBlock(@"ABUAdSDKManager _setup blocked");
}

- (void)registerAppID:(NSString *)appID {
    LogAdBlock(@"ABUAdSDKManager registerAppID blocked: %@", appID);
}

- (void)setupUserConfig {
    LogAdBlock(@"ABUAdSDKManager setupUserConfig blocked");
}

- (void)setupAPMConfig {
    LogAdBlock(@"ABUAdSDKManager setupAPMConfig blocked");
}

- (void)setupTNCConfig {
    LogAdBlock(@"ABUAdSDKManager setupTNCConfig blocked");
}

- (void)setupApplogConfig {
    LogAdBlock(@"ABUAdSDKManager setupApplogConfig blocked");
}

- (void)setupSDKConfig {
    LogAdBlock(@"ABUAdSDKManager setupSDKConfig blocked");
}

- (void)setupModuleControl {
    LogAdBlock(@"ABUAdSDKManager setupModuleControl blocked");
}

- (void)setupAdnDetectManager {
    LogAdBlock(@"ABUAdSDKManager setupAdnDetectManager blocked");
}

- (void)setupUpperDetectManager {
    LogAdBlock(@"ABUAdSDKManager setupUpperDetectManager blocked");
}

- (void)setupPangleSDK {
    LogAdBlock(@"ABUAdSDKManager setupPangleSDK blocked");
}

- (void)setupAdActionManager {
    LogAdBlock(@"ABUAdSDKManager setupAdActionManager blocked");
}

- (void)_updatePC {
    LogAdBlock(@"ABUAdSDKManager _updatePC blocked");
}

- (void)_updateRulesWithConfig {
    LogAdBlock(@"ABUAdSDKManager _updateRulesWithConfig blocked");
}

- (void)setupTrackerConfig {
    LogAdBlock(@"ABUAdSDKManager setupTrackerConfig blocked");
}

- (void)setupLogConfigViaConfig {
    LogAdBlock(@"ABUAdSDKManager setupLogConfigViaConfig blocked");
}

- (void)setupAdnSDKWithConfig:(id)config {
    LogAdBlock(@"ABUAdSDKManager setupAdnSDKWithConfig blocked");
}

- (void)setupAdnSDKWithConfigSYNC:(id)config {
    LogAdBlock(@"ABUAdSDKManager setupAdnSDKWithConfigSYNC blocked");
}

%end

// 2. 配置管理器拦截 - 阻止广告配置获取
%hook ABUConfigManager

- (id)init {
    LogAdBlock(@"ABUConfigManager init blocked");
    return nil;
}

- (void)getConfigWithBlock:(id)block {
    LogAdBlock(@"ABUConfigManager getConfigWithBlock blocked");
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^configBlock)(id, NSError *) = block;
            NSError *err = [NSError errorWithDomain:@"AdBlock" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Ad config blocked"}];
            configBlock(nil, err);
        });
    }
}

- (void)configLoadDidSuccess {
    LogAdBlock(@"ABUConfigManager configLoadDidSuccess blocked");
}

- (void)loadConfigFromServerIfNeeded {
    LogAdBlock(@"ABUConfigManager loadConfigFromServerIfNeeded blocked");
}

- (void)loadConfigFromServer {
    LogAdBlock(@"ABUConfigManager loadConfigFromServer blocked");
}

- (void)loadConfigFromLocalIfNeeded {
    LogAdBlock(@"ABUConfigManager loadConfigFromLocalIfNeeded blocked");
}

%end

%hook ABUConfigManager_V2

- (id)init {
    LogAdBlock(@"ABUConfigManager_V2 init blocked");
    return nil;
}

- (void)getConfigWithBlock:(id)block {
    LogAdBlock(@"ABUConfigManager_V2 getConfigWithBlock blocked");
    if (block) {
        dispatch_async(dispatch_get_main_queue(), ^{
            void (^configBlock)(id, NSError *) = block;
            NSError *err = [NSError errorWithDomain:@"AdBlock" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Ad config blocked"}];
            configBlock(nil, err);
        });
    }
}

- (void)configLoadForServerDidSuccess_V2 {
    LogAdBlock(@"ABUConfigManager_V2 configLoadForServerDidSuccess_V2 blocked");
}

- (void)_loadConfigFromServerWithTimes:(NSInteger)times {
    LogAdBlock(@"ABUConfigManager_V2 _loadConfigFromServerWithTimes blocked");
}

%end

// 3. 广告存储管理器拦截
%hook ABUAdStorageManager

- (id)init {
    LogAdBlock(@"ABUAdStorageManager init blocked");
    return nil;
}

- (void)initializeConfig {
    LogAdBlock(@"ABUAdStorageManager initializeConfig blocked");
}

- (void)updateConfig {
    LogAdBlock(@"ABUAdStorageManager updateConfig blocked");
}

- (void)configLoadDidSuccess {
    LogAdBlock(@"ABUAdStorageManager configLoadDidSuccess blocked");
}

- (void)configLoadForServerDidSuccess_V2 {
    LogAdBlock(@"ABUAdStorageManager configLoadForServerDidSuccess_V2 blocked");
}

- (void)insertAd:(id)ad {
    LogAdBlock(@"ABUAdStorageManager insertAd blocked");
}

- (void)clearAdListWithRequestID:(NSString *)requestID {
    LogAdBlock(@"ABUAdStorageManager clearAdListWithRequestID blocked");
}

%end

// 4. 广告行为管理器拦截
%hook ABUAdActionManager

- (id)init {
    LogAdBlock(@"ABUAdActionManager init blocked");
    return nil;
}

- (void)setup {
    LogAdBlock(@"ABUAdActionManager setup blocked");
}

- (void)canLoadForFreqWithBlock:(id)block {
    LogAdBlock(@"ABUAdActionManager canLoadForFreqWithBlock blocked");
    if (block) {
        void (^freqBlock)(BOOL) = block;
        freqBlock(NO);
    }
}

- (BOOL)canRequestWithType:(NSInteger)type {
    LogAdBlock(@"ABUAdActionManager canRequestWithType:%ld blocked", (long)type);
    return NO;
}

- (void)updateLoadRulesWithTimes:(NSInteger)times {
    LogAdBlock(@"ABUAdActionManager updateLoadRulesWithTimes blocked");
}

- (void)updateErrorCodesListWithConfig:(id)config {
    LogAdBlock(@"ABUAdActionManager updateErrorCodesListWithConfig blocked");
}

- (void)updateAllHistoriesWithNewConfigsRule:(id)rule {
    LogAdBlock(@"ABUAdActionManager updateAllHistoriesWithNewConfigsRule blocked");
}

%end

// 5. 广告加载器基类拦截
%hook ABUAdLoader

- (id)init {
    LogAdBlock(@"ABUAdLoader init blocked");
    return nil;
}

- (id)initWithMediationSlotConfig:(id)config {
    LogAdBlock(@"ABUAdLoader initWithMediationSlotConfig blocked");
    return nil;
}

- (void)loadAdsWithConfigs:(id)configs {
    LogAdBlock(@"ABUAdLoader loadAdsWithConfigs blocked");
}

- (void)_notifyLoadFinishWithParam:(id)param {
    LogAdBlock(@"ABUAdLoader _notifyLoadFinishWithParam blocked");
}

- (void)notifyMediaLoadSuccessWithLoadID:(NSString *)loadID {
    LogAdBlock(@"ABUAdLoader notifyMediaLoadSuccessWithLoadID blocked");
}

- (void)notifyMediaLoadFailedWithLoadID:(NSString *)loadID {
    LogAdBlock(@"ABUAdLoader notifyMediaLoadFailedWithLoadID blocked");
}

- (void)notifyMediaLoadWillBeginWithConfig:(id)config {
    LogAdBlock(@"ABUAdLoader notifyMediaLoadWillBeginWithConfig blocked");
}

- (void)beginLoadMediaAdIfNeededWithConfig:(id)config {
    LogAdBlock(@"ABUAdLoader beginLoadMediaAdIfNeededWithConfig blocked");
}

- (void)willLoadMediaAdUsingRules:(id)rules {
    LogAdBlock(@"ABUAdLoader willLoadMediaAdUsingRules blocked");
}

%end

// 6. 广告基类拦截
%hook ABUBaseAd

- (id)init {
    LogAdBlock(@"ABUBaseAd init blocked");
    return nil;
}

- (id)initWithMediationRit:(NSString *)rit {
    LogAdBlock(@"ABUBaseAd initWithMediationRit:%@ blocked", rit);
    return nil;
}

- (void)ex_loadAdData {
    LogAdBlock(@"ABUBaseAd ex_loadAdData blocked");
}

- (void)loadAdData {
    LogAdBlock(@"ABUBaseAd loadAdData blocked");
}

- (void)loadAdDataWithMediaSlotConfigIDs:(id)ids {
    LogAdBlock(@"ABUBaseAd loadAdDataWithMediaSlotConfigIDs blocked");
}

- (void)preloadByUser {
    LogAdBlock(@"ABUBaseAd preloadByUser blocked");
}

- (void)checkPreloadCacheExistWithWaterfall:(id)waterfall {
    LogAdBlock(@"ABUBaseAd checkPreloadCacheExistWithWaterfall blocked");
}

%end

// 7. 各类型广告加载器拦截
%hook ABUBannerAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUBannerAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUBannerAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUSplashAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUSplashAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUSplashAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABURewardedVideoAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABURewardedVideoAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABURewardedVideoAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUFullscreenVideoAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUFullscreenVideoAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUFullscreenVideoAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUInterstitialAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUInterstitialAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUInterstitialAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUInterstitialProAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUInterstitialProAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUInterstitialProAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUNativeAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUNativeAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUNativeAdLoader willLoadMediaAdUsingRules blocked"); }
%end

%hook ABUDrawAdLoader
- (void)loadMediaAdWithAdapter:(id)adapter { LogAdBlock(@"ABUDrawAdLoader loadMediaAdWithAdapter blocked"); }
- (void)willLoadMediaAdUsingRules:(id)rules { LogAdBlock(@"ABUDrawAdLoader willLoadMediaAdUsingRules blocked"); }
%end

// 8. 各类型广告展示类拦截
%hook ABUBannerAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUBannerAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)loadAdData { LogAdBlock(@"ABUBannerAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUBannerAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUBannerAd adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUBannerAd preloadAdWithType blocked"); }
%end

%hook ABUSplashAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUSplashAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)showInWindowWithBlock:(id)block { LogAdBlock(@"ABUSplashAd showInWindowWithBlock blocked"); }
- (void)showInWindow:(UIWindow *)window { LogAdBlock(@"ABUSplashAd showInWindow blocked"); }
- (void)loadAdData { LogAdBlock(@"ABUSplashAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUSplashAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUSplashAd adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUSplashAd preloadAdWithType blocked"); }
%end

%hook ABURewardedVideoAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABURewardedVideoAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)showAdFromRootViewController:(UIViewController *)rootViewController { LogAdBlock(@"ABURewardedVideoAd showAdFromRootViewController blocked"); }
- (void)loadAdData { LogAdBlock(@"ABURewardedVideoAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABURewardedVideoAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABURewardedVideoAd adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABURewardedVideoAd preloadAdWithType blocked"); }
%end

%hook ABUFullscreenVideoAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUFullscreenVideoAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)showAdFromRootViewController:(UIViewController *)rootViewController { LogAdBlock(@"ABUFullscreenVideoAd showAdFromRootViewController blocked"); }
- (void)loadAdData { LogAdBlock(@"ABUFullscreenVideoAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUFullscreenVideoAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUFullscreenVideoAd adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUFullscreenVideoAd preloadAdWithType blocked"); }
%end

%hook ABUInterstitialAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUInterstitialAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)showAdFromRootViewController:(UIViewController *)rootViewController { LogAdBlock(@"ABUInterstitialAd showAdFromRootViewController blocked"); }
- (void)loadAdData { LogAdBlock(@"ABUInterstitialAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUInterstitialAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUInterstitialAd adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUInterstitialAd preloadAdWithType blocked"); }
%end

%hook ABUInterstitialProAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUInterstitialProAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)showAdFromRootViewController:(UIViewController *)rootViewController { LogAdBlock(@"ABUInterstitialProAd showAdFromRootViewController blocked"); }
- (void)loadAdData { LogAdBlock(@"ABUInterstitialProAd loadAdData blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUInterstitialProAd adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUInterstitialProAd adLoadDidFailedWithError blocked"); }
%end

%hook ABUNativeAdsManager
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUNativeAdsManager initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (id)initWithSlot:(id)slot { LogAdBlock(@"ABUNativeAdsManager initWithSlot blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"ABUNativeAdsManager loadAdData blocked"); }
- (void)loadAdDataWithCount:(NSInteger)count { LogAdBlock(@"ABUNativeAdsManager loadAdDataWithCount blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUNativeAdsManager adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUNativeAdsManager adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUNativeAdsManager preloadAdWithType blocked"); }
%end

%hook ABUNativeAdView
- (id)initWithSlot:(id)slot { LogAdBlock(@"ABUNativeAdView initWithSlot blocked"); return nil; }
- (id)initWithAdPackage:(id)package { LogAdBlock(@"ABUNativeAdView initWithAdPackage blocked"); return nil; }
- (id)initWithExpressView:(id)view { LogAdBlock(@"ABUNativeAdView initWithExpressView blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"ABUNativeAdView loadAdData blocked"); }
- (void)adViewDidShow { LogAdBlock(@"ABUNativeAdView adViewDidShow blocked"); }
%end

%hook ABUDrawAdsManager
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUDrawAdsManager initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)loadAdData { LogAdBlock(@"ABUDrawAdsManager loadAdData blocked"); }
- (void)loadAdDataWithCount:(NSInteger)count { LogAdBlock(@"ABUDrawAdsManager loadAdDataWithCount blocked"); }
- (void)adLoadDidSuccess { LogAdBlock(@"ABUDrawAdsManager adLoadDidSuccess blocked"); }
- (void)adLoadDidFailedWithError:(id)error { LogAdBlock(@"ABUDrawAdsManager adLoadDidFailedWithError blocked"); }
- (void)preloadAdWithType:(NSInteger)type { LogAdBlock(@"ABUDrawAdsManager preloadAdWithType blocked"); }
%end

%hook ABUDrawAdView
- (id)initWithSlot:(id)slot { LogAdBlock(@"ABUDrawAdView initWithSlot blocked"); return nil; }
- (id)initWithAdPackage:(id)package { LogAdBlock(@"ABUDrawAdView initWithAdPackage blocked"); return nil; }
- (id)initWithExpressView:(id)view { LogAdBlock(@"ABUDrawAdView initWithExpressView blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"ABUDrawAdView loadAdData blocked"); }
- (void)adViewDidShow { LogAdBlock(@"ABUDrawAdView adViewDidShow blocked"); }
%end

// 9. 瀑布流/竞价拦截
%hook ABUMediationWaterfallIMP
- (id)init { LogAdBlock(@"ABUMediationWaterfallIMP init blocked"); return nil; }
- (id)initWithConfig:(id)config { LogAdBlock(@"ABUMediationWaterfallIMP initWithConfig blocked"); return nil; }
- (BOOL)canMediationRequestForFreq { LogAdBlock(@"ABUMediationWaterfallIMP canMediationRequestForFreq blocked"); return NO; }
- (BOOL)canMediationRequestForAppFreq { LogAdBlock(@"ABUMediationWaterfallIMP canMediationRequestForAppFreq blocked"); return NO; }
- (BOOL)canMediationRequestForPeriod { LogAdBlock(@"ABUMediationWaterfallIMP canMediationRequestForPeriod blocked"); return NO; }
- (BOOL)canMediaRequestForFreqWithConfig:(id)config { LogAdBlock(@"ABUMediationWaterfallIMP canMediaRequestForFreqWithConfig blocked"); return NO; }
- (BOOL)canMediaRequestForPeriodWithConfig:(id)config { LogAdBlock(@"ABUMediationWaterfallIMP canMediaRequestForPeriodWithConfig blocked"); return NO; }
- (BOOL)canMediaRequestForErrorCodeControlWithConfig:(id)config { LogAdBlock(@"ABUMediationWaterfallIMP canMediaRequestForErrorCodeControlWithConfig blocked"); return NO; }
- (void)reportMediaRequestForErrorCodeControlWithConfig:(id)config { LogAdBlock(@"ABUMediationWaterfallIMP reportMediaRequestForErrorCodeControlWithConfig blocked"); }
%end

%hook ABUMediationWaterfallFactory
- (id)init { LogAdBlock(@"ABUMediationWaterfallFactory init blocked"); return nil; }
%end

%hook ABUMediationWaterfallExtra
- (void)startLoadWithAd:(id)ad { LogAdBlock(@"ABUMediationWaterfallExtra startLoadWithAd blocked"); }
- (void)waterfallDidLoadSuccess { LogAdBlock(@"ABUMediationWaterfallExtra waterfallDidLoadSuccess blocked"); }
%end

// 10. 预加载管理器拦截
%hook ABUPreloadManager
- (id)init { LogAdBlock(@"ABUPreloadManager init blocked"); return nil; }
- (void)preloadAdFromAd:(id)ad { LogAdBlock(@"ABUPreloadManager preloadAdFromAd blocked"); }
- (void)preloadAdsWithInfos:(id)infos { LogAdBlock(@"ABUPreloadManager preloadAdsWithInfos blocked"); }
- (void)checkPreloadExistWithAd:(id)ad { LogAdBlock(@"ABUPreloadManager checkPreloadExistWithAd blocked"); }
%end

// 11. 轮播广告拦截
%hook ABUCarouselBannerAd
- (id)initWithAdUnitID:(NSString *)adUnitID { LogAdBlock(@"ABUCarouselBannerAd initWithAdUnitID:%@ blocked", adUnitID); return nil; }
- (void)bannerAdDidLoad { LogAdBlock(@"ABUCarouselBannerAd bannerAdDidLoad blocked"); }
- (void)bannerCarouselViewDidShowBannerAd { LogAdBlock(@"ABUCarouselBannerAd bannerCarouselViewDidShowBannerAd blocked"); }
%end

%hook ABUInterstitialProCarouselManager
- (id)initWithAd:(id)ad { LogAdBlock(@"ABUInterstitialProCarouselManager initWithAd blocked"); return nil; }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"ABUInterstitialProCarouselManager showAdFromRootViewController blocked"); }
%end

// 12. 个性化配置适配器拦截
%hook ABUPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUPanglePersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUPanglePersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUBaiduPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUBaiduPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUGdtPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUGdtPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUCsjPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUCsjPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUKsPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUKsPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUKlevinPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUKlevinPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUMintegralPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUMintegralPersonaliseConfigAdapter init blocked"); return nil; }
%end

%hook ABUAdmobPersonaliseConfigAdapter
- (id)init { LogAdBlock(@"ABUAdmobPersonaliseConfigAdapter init blocked"); return nil; }
%end

// 13. 服务器竞价拦截
%hook ABUCustomServerBiddingManager
- (id)init { LogAdBlock(@"ABUCustomServerBiddingManager init blocked"); return nil; }
%end

%hook ABUDefaultServerBiddingManager
- (id)init { LogAdBlock(@"ABUDefaultServerBiddingManager init blocked"); return nil; }
%end

// 14. 策略管理器拦截
%hook ABUMediaSlotConfig
- (id)init { LogAdBlock(@"ABUMediaSlotConfig init blocked"); return nil; }
- (id)initWithSplashMediaRit:(id)rit { LogAdBlock(@"ABUMediaSlotConfig initWithSplashMediaRit blocked"); return nil; }
- (id)initWithDictionary:(id)dict { LogAdBlock(@"ABUMediaSlotConfig initWithDictionary blocked"); return nil; }
- (id)mediaSlotConfigWithMediationSlotID:(NSString *)slotID { LogAdBlock(@"ABUMediaSlotConfig mediaSlotConfigWithMediationSlotID blocked"); return nil; }
%end

%hook ABUMediationSlotConfig
- (id)init { LogAdBlock(@"ABUMediationSlotConfig init blocked"); return nil; }
- (id)initWithSplashMediationRit:(id)rit { LogAdBlock(@"ABUMediationSlotConfig initWithSplashMediationRit blocked"); return nil; }
- (id)initWithDictionary:(id)dict { LogAdBlock(@"ABUMediationSlotConfig initWithDictionary blocked"); return nil; }
- (id)mediationSlotConfig { LogAdBlock(@"ABUMediationSlotConfig mediationSlotConfig blocked"); return nil; }
%end

%hook ABUMediaSlotConfigGroup
- (id)initWithMediationSlotConfig:(id)config { LogAdBlock(@"ABUMediaSlotConfigGroup initWithMediationSlotConfig blocked"); return nil; }
%end

// ============================================================
// MARK: - CSJ (穿山甲/Pangle) 原生SDK 拦截
// ============================================================

%hook CSJSplashAd
- (id)initWithSlotID:(NSString *)slotID { LogAdBlock(@"CSJSplashAd initWithSlotID:%@ blocked", slotID); return nil; }
- (id)initWithSlot:(id)slot { LogAdBlock(@"CSJSplashAd initWithSlot blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"CSJSplashAd loadAdData blocked"); }
- (void)showSplashViewInRootViewController:(UIViewController *)vc { LogAdBlock(@"CSJSplashAd showSplashViewInRootViewController blocked"); }
- (void)showCardViewInRootViewController:(UIViewController *)vc { LogAdBlock(@"CSJSplashAd showCardViewInRootViewController blocked"); }
- (void)showZoomOutViewInRootViewController:(UIViewController *)vc { LogAdBlock(@"CSJSplashAd showZoomOutViewInRootViewController blocked"); }
%end

%hook CSJNativeExpressAdManager
- (id)initWithSlot:(id)slot { LogAdBlock(@"CSJNativeExpressAdManager initWithSlot blocked"); return nil; }
- (void)loadAdDataWithCount:(NSInteger)count { LogAdBlock(@"CSJNativeExpressAdManager loadAdDataWithCount blocked"); }
- (void)loadAdData { LogAdBlock(@"CSJNativeExpressAdManager loadAdData blocked"); }
- (void)nativeAdsManagerSuccessToLoad:(id)ads { LogAdBlock(@"CSJNativeExpressAdManager nativeAdsManagerSuccessToLoad blocked"); }
%end

%hook CSJNativeExpressRewardedVideoAd
- (id)initWithSlotID:(NSString *)slotID { LogAdBlock(@"CSJNativeExpressRewardedVideoAd initWithSlotID:%@ blocked", slotID); return nil; }
- (id)initWithSlot:(id)slot { LogAdBlock(@"CSJNativeExpressRewardedVideoAd initWithSlot blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"CSJNativeExpressRewardedVideoAd loadAdData blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"CSJNativeExpressRewardedVideoAd showAdFromRootViewController blocked"); }
%end

%hook CSJNativeExpressFullscreenVideoAd
- (id)initWithSlotID:(NSString *)slotID { LogAdBlock(@"CSJNativeExpressFullscreenVideoAd initWithSlotID:%@ blocked", slotID); return nil; }
- (id)initWithSlot:(id)slot { LogAdBlock(@"CSJNativeExpressFullscreenVideoAd initWithSlot blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"CSJNativeExpressFullscreenVideoAd loadAdData blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"CSJNativeExpressFullscreenVideoAd showAdFromRootViewController blocked"); }
%end

%hook CSJNativeExpressAdView
- (void)play { LogAdBlock(@"CSJNativeExpressAdView play blocked"); }
- (void)replay { LogAdBlock(@"CSJNativeExpressAdView replay blocked"); }
- (void)startPlayVideo { LogAdBlock(@"CSJNativeExpressAdView startPlayVideo blocked"); }
%end

%hook CSJMaterialMeta
- (id)initWithDictionary:(id)dict { LogAdBlock(@"CSJMaterialMeta initWithDictionary blocked"); return nil; }
- (id)init { LogAdBlock(@"CSJMaterialMeta init blocked"); return nil; }
%end

// ============================================================
// MARK: - BaiduMobAd (百度广告) SDK 拦截
// ============================================================

%hook BaiduMobAdExpressFullScreenVideo
- (id)init { LogAdBlock(@"BaiduMobAdExpressFullScreenVideo init blocked"); return nil; }
- (void)load { LogAdBlock(@"BaiduMobAdExpressFullScreenVideo load blocked"); }
- (void)loadBiddingAd { LogAdBlock(@"BaiduMobAdExpressFullScreenVideo loadBiddingAd blocked"); }
- (void)show { LogAdBlock(@"BaiduMobAdExpressFullScreenVideo show blocked"); }
- (void)showFromViewController:(UIViewController *)vc { LogAdBlock(@"BaiduMobAdExpressFullScreenVideo showFromViewController blocked"); }
%end

%hook BaiduMobAdExpressInterstitial
- (id)init { LogAdBlock(@"BaiduMobAdExpressInterstitial init blocked"); return nil; }
- (void)load { LogAdBlock(@"BaiduMobAdExpressInterstitial load blocked"); }
- (void)loadBiddingAd { LogAdBlock(@"BaiduMobAdExpressInterstitial loadBiddingAd blocked"); }
- (void)show { LogAdBlock(@"BaiduMobAdExpressInterstitial show blocked"); }
- (void)showFromViewController:(UIViewController *)vc { LogAdBlock(@"BaiduMobAdExpressInterstitial showFromViewController blocked"); }
%end

%hook BaiduMobAdExpressNativeView
- (id)initWithAdObject:(id)adObject { LogAdBlock(@"BaiduMobAdExpressNativeView initWithAdObject blocked"); return nil; }
- (void)render { LogAdBlock(@"BaiduMobAdExpressNativeView render blocked"); }
- (void)bubbleShow { LogAdBlock(@"BaiduMobAdExpressNativeView bubbleShow blocked"); }
- (void)showSlideGestureView { LogAdBlock(@"BaiduMobAdExpressNativeView showSlideGestureView blocked"); }
- (void)nativeAdExpressSuccessRender { LogAdBlock(@"BaiduMobAdExpressNativeView nativeAdExpressSuccessRender blocked"); }
%end

%hook BaiduMobAdRenderer
- (id)initWithAdRendererHelper:(id)helper { LogAdBlock(@"BaiduMobAdRenderer initWithAdRendererHelper blocked"); return nil; }
- (void)load { LogAdBlock(@"BaiduMobAdRenderer load blocked"); }
- (void)start { LogAdBlock(@"BaiduMobAdRenderer start blocked"); }
- (void)pause { LogAdBlock(@"BaiduMobAdRenderer pause blocked"); }
%end

%hook BaiduMobAdVideoRenderer
- (id)initWithAdRendererHelper:(id)helper { LogAdBlock(@"BaiduMobAdVideoRenderer initWithAdRendererHelper blocked"); return nil; }
- (void)load { LogAdBlock(@"BaiduMobAdVideoRenderer load blocked"); }
- (void)start { LogAdBlock(@"BaiduMobAdVideoRenderer start blocked"); }
%end

%hook BaiduMobAdHTMLRenderer
- (id)initWithAdRendererHelper:(id)helper { LogAdBlock(@"BaiduMobAdHTMLRenderer initWithAdRendererHelper blocked"); return nil; }
- (void)load { LogAdBlock(@"BaiduMobAdHTMLRenderer load blocked"); }
- (void)start { LogAdBlock(@"BaiduMobAdHTMLRenderer start blocked"); }
- (void)reload { LogAdBlock(@"BaiduMobAdHTMLRenderer reload blocked"); }
%end

%hook BaiduMobAdH5Renderer
- (void)load { LogAdBlock(@"BaiduMobAdH5Renderer load blocked"); }
- (void)playUrl { LogAdBlock(@"BaiduMobAdH5Renderer playUrl blocked"); }
%end

%hook BaiduMobAdImageRenderer
- (void)load { LogAdBlock(@"BaiduMobAdImageRenderer load blocked"); }
- (void)showPureImage { LogAdBlock(@"BaiduMobAdImageRenderer showPureImage blocked"); }
- (void)showResource { LogAdBlock(@"BaiduMobAdImageRenderer showResource blocked"); }
- (void)showImage { LogAdBlock(@"BaiduMobAdImageRenderer showImage blocked"); }
%end

%hook BaiduMobAdGifImageRenderer
- (void)showResource { LogAdBlock(@"BaiduMobAdGifImageRenderer showResource blocked"); }
- (void)showGifImage { LogAdBlock(@"BaiduMobAdGifImageRenderer showGifImage blocked"); }
%end

%hook BaiduMobAdNativeVideoView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"BaiduMobAdNativeVideoView initWithFrame blocked"); return nil; }
- (id)initVideoWithFrame:(CGRect)frame { LogAdBlock(@"BaiduMobAdNativeVideoView initVideoWithFrame blocked"); return nil; }
- (void)setAudioSessionCategory { LogAdBlock(@"BaiduMobAdNativeVideoView setAudioSessionCategory blocked"); }
%end

%hook BaiduMobAdNativeCPUVideoView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"BaiduMobAdNativeCPUVideoView initWithFrame blocked"); return nil; }
%end

%hook BaiduMobAdExpressIntViewController
- (id)initWithAdRender:(id)render { LogAdBlock(@"BaiduMobAdExpressIntViewController initWithAdRender blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"BaiduMobAdExpressIntViewController viewDidLoad blocked"); }
- (void)viewWillAppear:(BOOL)animated { LogAdBlock(@"BaiduMobAdExpressIntViewController viewWillAppear blocked"); }
%end

%hook BaiduMobAdRewardVideoRenderer
- (id)initWithAdRendererHelper:(id)helper { LogAdBlock(@"BaiduMobAdRewardVideoRenderer initWithAdRendererHelper blocked"); return nil; }
- (void)layoutDisplayArea { LogAdBlock(@"BaiduMobAdRewardVideoRenderer layoutDisplayArea blocked"); }
- (void)handleCloud { LogAdBlock(@"BaiduMobAdRewardVideoRenderer handleCloud blocked"); }
%end

%hook BaiduMobAdSmartFeedView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"BaiduMobAdSmartFeedView initWithFrame blocked"); return nil; }
%end

%hook BaiduMobAdMraidBridge
- (id)init { LogAdBlock(@"BaiduMobAdMraidBridge init blocked"); return nil; }
%end

%hook BaiduMobAdInstance
- (id)initWithDictonary:(id)dict { LogAdBlock(@"BaiduMobAdInstance initWithDictonary blocked"); return nil; }
- (id)initCpuInstanceWithDictonary:(id)dict { LogAdBlock(@"BaiduMobAdInstance initCpuInstanceWithDictonary blocked"); return nil; }
%end

%hook BaiduMobAdComponentModel
- (id)initWithOriginJson:(id)json { LogAdBlock(@"BaiduMobAdComponentModel initWithOriginJson blocked"); return nil; }
- (void)setModelWithDictionary:(id)dict { LogAdBlock(@"BaiduMobAdComponentModel setModelWithDictionary blocked"); }
%end

// ============================================================
// MARK: - GDT (广点通/Tencent Ads) SDK 拦截
// ============================================================

%hook GDTSplashAd
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTSplashAd initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAdAndShowInWindow:(UIWindow *)window { LogAdBlock(@"GDTSplashAd loadAdAndShowInWindow blocked"); }
- (void)loadAdAndShowFullScreenInWindow:(UIWindow *)window { LogAdBlock(@"GDTSplashAd loadAdAndShowFullScreenInWindow blocked"); }
%end

%hook GDTSplashAdImp
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTSplashAdImp initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTSplashAdImp loadAd blocked"); }
- (void)showAdInWindow:(UIWindow *)window { LogAdBlock(@"GDTSplashAdImp showAdInWindow blocked"); }
- (void)loadAdAndShowInWindow:(UIWindow *)window { LogAdBlock(@"GDTSplashAdImp loadAdAndShowInWindow blocked"); }
- (void)preload { LogAdBlock(@"GDTSplashAdImp preload blocked"); }
%end

%hook GDTRewardVideoAd
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTRewardVideoAd initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTRewardVideoAd loadAd blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"GDTRewardVideoAd showAdFromRootViewController blocked"); }
%end

%hook GDTUnifiedInterstitialAd
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTUnifiedInterstitialAd initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTUnifiedInterstitialAd loadAd blocked"); }
- (void)loadFullScreenAd { LogAdBlock(@"GDTUnifiedInterstitialAd loadFullScreenAd blocked"); }
%end

%hook GDTUnifiedInterstitialAdImp
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTUnifiedInterstitialAdImp initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTUnifiedInterstitialAdImp loadAd blocked"); }
%end

%hook GDTNativeExpressAd
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTNativeExpressAd initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTNativeExpressAd loadAd blocked"); }
%end

%hook GDTNativeExpressAdImp
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTNativeExpressAdImp initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTNativeExpressAdImp loadAd blocked"); }
- (void)loadAdWithAdCount:(NSInteger)count { LogAdBlock(@"GDTNativeExpressAdImp loadAdWithAdCount blocked"); }
%end

%hook GDTNativeExpressAdView
- (void)render { LogAdBlock(@"GDTNativeExpressAdView render blocked"); }
%end

%hook GDTNativeExpressAdViewImp
- (void)render { LogAdBlock(@"GDTNativeExpressAdViewImp render blocked"); }
- (void)play { LogAdBlock(@"GDTNativeExpressAdViewImp play blocked"); }
%end

%hook GDTUnifiedNativeAd
- (id)initWithPlacementId:(NSString *)placementId { LogAdBlock(@"GDTUnifiedNativeAd initWithPlacementId:%@ blocked", placementId); return nil; }
- (void)loadAd { LogAdBlock(@"GDTUnifiedNativeAd loadAd blocked"); }
- (void)loadAdWithAdCount:(NSInteger)count { LogAdBlock(@"GDTUnifiedNativeAd loadAdWithAdCount blocked"); }
%end

%hook GDTADConfiguration
- (id)init { LogAdBlock(@"GDTADConfiguration init blocked"); return nil; }
%end

// ============================================================
// MARK: - Wind/Sigmob SDK 拦截
// ============================================================

%hook WindMillRewardVideoAdManager
- (id)init { LogAdBlock(@"WindMillRewardVideoAdManager init blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"WindMillRewardVideoAdManager loadAdData blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"WindMillRewardVideoAdManager showAdFromRootViewController blocked"); }
%end

%hook WindMillInterstitialAdManager
- (id)initWithRequest:(id)request { LogAdBlock(@"WindMillInterstitialAdManager initWithRequest blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"WindMillInterstitialAdManager loadAdData blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"WindMillInterstitialAdManager showAdFromRootViewController blocked"); }
%end

%hook WindMillBannerAdManager
- (id)initWithRequest:(id)request { LogAdBlock(@"WindMillBannerAdManager initWithRequest blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"WindMillBannerAdManager loadAdData blocked"); }
- (void)showAdFromRootViewController:(UIViewController *)vc { LogAdBlock(@"WindMillBannerAdManager showAdFromRootViewController blocked"); }
%end

%hook WindMillNativeAdsManager
- (id)initWithRequest:(id)request { LogAdBlock(@"WindMillNativeAdsManager initWithRequest blocked"); return nil; }
- (void)_loadAdData { LogAdBlock(@"WindMillNativeAdsManager _loadAdData blocked"); }
- (void)loadAdDataWithCount:(NSInteger)count { LogAdBlock(@"WindMillNativeAdsManager loadAdDataWithCount blocked"); }
%end

%hook WindMillNativeAd
- (id)initWithMediatedNativeAd:(id)ad { LogAdBlock(@"WindMillNativeAd initWithMediatedNativeAd blocked"); return nil; }
%end

%hook WindMillNativeAdView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"WindMillNativeAdView initWithFrame blocked"); return nil; }
- (void)play { LogAdBlock(@"WindMillNativeAdView play blocked"); }
%end

%hook WindMillBannerView
- (id)initWithRequest:(id)request { LogAdBlock(@"WindMillBannerView initWithRequest blocked"); return nil; }
- (void)loadAdData { LogAdBlock(@"WindMillBannerView loadAdData blocked"); }
%end

%hook WindMillNativeInterstitialViewController
- (id)init { LogAdBlock(@"WindMillNativeInterstitialViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"WindMillNativeInterstitialViewController viewDidLoad blocked"); }
%end

%hook WindPlayerController
- (void)playTheIndexPath:(NSIndexPath *)indexPath { LogAdBlock(@"WindPlayerController playTheIndexPath blocked"); }
- (void)updateScrollViewPlayerToCell { LogAdBlock(@"WindPlayerController updateScrollViewPlayerToCell blocked"); }
- (void)updateNoramlPlayerWithContainerView:(UIView *)view { LogAdBlock(@"WindPlayerController updateNoramlPlayerWithContainerView blocked"); }
%end

%hook WindmillStrategyManager
- (id)init { LogAdBlock(@"WindmillStrategyManager init blocked"); return nil; }
- (void)preStrategyWithPlacementId:(NSString *)placementId { LogAdBlock(@"WindmillStrategyManager preStrategyWithPlacementId blocked"); }
- (id)getAdStrategyWithRequest:(id)request { LogAdBlock(@"WindmillStrategyManager getAdStrategyWithRequest blocked"); return nil; }
%end

%hook SigmobFullscreenAdViewController
- (id)initWithBidResponse:(id)response { LogAdBlock(@"SigmobFullscreenAdViewController initWithBidResponse blocked"); return nil; }
%end

// ============================================================
// MARK: - 通用广告视图/控制器拦截
// ============================================================

%hook CSJRewardedVideoDisplayViewController
- (id)init { LogAdBlock(@"CSJRewardedVideoDisplayViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJRewardedVideoDisplayViewController viewDidLoad blocked"); }
%end

%hook CSJVideoDetailPageViewController
- (id)init { LogAdBlock(@"CSJVideoDetailPageViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJVideoDetailPageViewController viewDidLoad blocked"); }
%end

%hook CSJExpressRewardFullScreenVM
- (id)init { LogAdBlock(@"CSJExpressRewardFullScreenVM init blocked"); return nil; }
- (void)relayoutSubViews { LogAdBlock(@"CSJExpressRewardFullScreenVM relayoutSubViews blocked"); }
%end

%hook CSJWebViewControllerViewModel
- (id)init { LogAdBlock(@"CSJWebViewControllerViewModel init blocked"); return nil; }
%end

%hook CSJPlayableWebVM
- (id)init { LogAdBlock(@"CSJPlayableWebVM init blocked"); return nil; }
%end

%hook CSJRewardedVideoWebViewControllerVM
- (id)init { LogAdBlock(@"CSJRewardedVideoWebViewControllerVM init blocked"); return nil; }
%end

%hook CSJRewardFullScreenBaseVM
- (id)init { LogAdBlock(@"CSJRewardFullScreenBaseVM init blocked"); return nil; }
%end

%hook CSJDynamicRenderTemplateStrategy
- (id)init { LogAdBlock(@"CSJDynamicRenderTemplateStrategy init blocked"); return nil; }
%end

%hook CSJNativeAd
- (id)init { LogAdBlock(@"CSJNativeAd init blocked"); return nil; }
%end

%hook CSJVideoAdView
- (id)initWithNativeAd:(id)nativeAd { LogAdBlock(@"CSJVideoAdView initWithNativeAd blocked"); return nil; }
%end

%hook CSJNativeExpressRewardedVideoAdView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"CSJNativeExpressRewardedVideoAdView initWithFrame blocked"); return nil; }
- (void)startPlayVideo { LogAdBlock(@"CSJNativeExpressRewardedVideoAdView startPlayVideo blocked"); }
%end

%hook CSJNativeExpressRewardDrawAdView
- (id)initWithFrame:(CGRect)frame { LogAdBlock(@"CSJNativeExpressRewardDrawAdView initWithFrame blocked"); return nil; }
- (void)render { LogAdBlock(@"CSJNativeExpressRewardDrawAdView render blocked"); }
- (void)replay { LogAdBlock(@"CSJNativeExpressRewardDrawAdView replay blocked"); }
%end

%hook CSJNativeExpressRewardedVideoAdDisplayViewController
- (id)init { LogAdBlock(@"CSJNativeExpressRewardedVideoAdDisplayViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJNativeExpressRewardedVideoAdDisplayViewController viewDidLoad blocked"); }
%end

%hook CSJNativeExpressRewardedVideoAdViewController
- (id)init { LogAdBlock(@"CSJNativeExpressRewardedVideoAdViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJNativeExpressRewardedVideoAdViewController viewDidLoad blocked"); }
%end

%hook CSJNativeExpressRewardDrawAdViewController
- (id)init { LogAdBlock(@"CSJNativeExpressRewardDrawAdViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJNativeExpressRewardDrawAdViewController viewDidLoad blocked"); }
%end

%hook CSJFullScreenInterstitialAdView
- (id)initWithMaterial:(id)material { LogAdBlock(@"CSJFullScreenInterstitialAdView initWithMaterial blocked"); return nil; }
%end

%hook CSJRewardedVideoAdViewController
- (id)init { LogAdBlock(@"CSJRewardedVideoAdViewController init blocked"); return nil; }
- (void)viewDidLoad { LogAdBlock(@"CSJRewardedVideoAdViewController viewDidLoad blocked"); }
%end

// ============================================================
// MARK: - 运行时动态 Hook (备用/兜底方案)
// ============================================================

static void HookClassMethod(const char *className, const char *selectorName, IMP newImp, IMP *oldImp) {
    Class cls = objc_getClass(className);
    if (!cls) {
        LogAdBlock(@"Class %s not found, skipping runtime hook", className);
        return;
    }
    SEL sel = sel_getUid(selectorName);
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        LogAdBlock(@"Method %s not found in %s, skipping", selectorName, className);
        return;
    }
    if (oldImp) {
        *oldImp = method_getImplementation(method);
    }
    method_setImplementation(method, newImp);
    LogAdBlock(@"Runtime hooked %s -> %s", className, selectorName);
}

static id __attribute__((optnone)) AdBlockReturnNil(id self, SEL _cmd) {
    LogAdBlock(@"Runtime blocked %s", sel_getName(_cmd));
    return nil;
}

static void __attribute__((optnone)) AdBlockReturnVoid(id self, SEL _cmd) {
    LogAdBlock(@"Runtime blocked %s", sel_getName(_cmd));
}

static BOOL __attribute__((optnone)) AdBlockReturnNO(id self, SEL _cmd) {
    LogAdBlock(@"Runtime blocked %s", sel_getName(_cmd));
    return NO;
}

%ctor {
    LogAdBlock(@"========================================");
    LogAdBlock(@"百度网盘去广告插件已加载 v1.0.0");
    LogAdBlock(@"========================================");

    // 运行时动态 hook 兜底 - 针对可能遗漏的类
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 通用广告加载方法兜底
        NSArray *adLoadSelectors = @[@"loadAdData", @"loadAd", @"load", @"loadBiddingAd", @"preloadAdWithType:"];
        NSArray *adShowSelectors = @[@"showAdFromRootViewController:", @"showInWindow:", @"showInWindowWithBlock:", @"show", @"showFromViewController:", @"showSplashViewInRootViewController:", @"showCardViewInRootViewController:", @"showZoomOutViewInRootViewController:"];

        int hooked = 0;
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            // 拦截所有广告SDK前缀的类
            if ([name hasPrefix:@"ABU"] || [name hasPrefix:@"CSJ"] || [name hasPrefix:@"BaiduMobAd"] || 
                [name hasPrefix:@"GDT"] || [name hasPrefix:@"Wind"] || [name hasPrefix:@"Sigmob"] ||
                [name hasPrefix:@"AWM"] || [name hasPrefix:@"Pangle"]) {

                for (NSString *selStr in adLoadSelectors) {
                    SEL sel = NSSelectorFromString(selStr);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method m = class_getInstanceMethod(classes[i], sel);
                        if (m) {
                            method_setImplementation(m, (IMP)AdBlockReturnVoid);
                            hooked++;
                        }
                    }
                }

                for (NSString *selStr in adShowSelectors) {
                    SEL sel = NSSelectorFromString(selStr);
                    if ([classes[i] instancesRespondToSelector:sel]) {
                        Method m = class_getInstanceMethod(classes[i], sel);
                        if (m) {
                            method_setImplementation(m, (IMP)AdBlockReturnVoid);
                            hooked++;
                        }
                    }
                }
            }
        }
        free(classes);
        LogAdBlock(@"Runtime兜底hook完成: %d 个方法", hooked);
    });
}
