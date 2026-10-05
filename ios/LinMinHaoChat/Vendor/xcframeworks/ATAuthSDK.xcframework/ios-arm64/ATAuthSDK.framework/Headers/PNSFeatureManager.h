
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PNSFeatureManager : NSObject

/// 是否开启供应商级别缓存（默认为私网IP级缓存，开启之后缓存为供应商级别）
@property (class, nonatomic, assign) BOOL enableCacheVendorLevel;

/// 是否开启运营商类型缓存（默认不开启，开启后会缓存上一次sim卡运营商归属信息）
@property (class, nonatomic, assign) BOOL enableCacheLastVendorInfo;

/// 是否开启降低网络请求频次模式（默认NO），开启后将跳过配置、埋点等dypns域名访问，不影响登录核心功能
@property (class, nonatomic, assign) BOOL enableReduceNetworkAccess;

+ (void)enableCacheVendorLevel:(BOOL)enable;


+ (void)enableCacheLastVendorInfo:(BOOL)enable;


+ (void)enableReduceNetworkAccess:(BOOL)enable;

@end

NS_ASSUME_NONNULL_END
