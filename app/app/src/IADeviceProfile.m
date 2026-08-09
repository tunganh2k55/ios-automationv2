//
//  IADeviceProfile.m
//  iOSAutoApp
//

#import "IADeviceProfile.h"

@implementation IADeviceProfile

+ (instancetype)profileWithDictionary:(NSDictionary *)dict {
    IADeviceProfile *p = [IADeviceProfile new];
    NSString *pid = [dict[@"id"] isKindOfClass:NSString.class] ? dict[@"id"] : nil;
    p.profileId = pid.length ? pid : [[NSUUID UUID] UUIDString];
    p.displayName        = [self str:dict[@"displayName"] or:@""];
    p.deviceModel        = [self str:dict[@"deviceModel"] or:@""];
    p.hardwareIdentifier = [self str:dict[@"hardwareIdentifier"] or:@""];
    p.systemName         = [self str:dict[@"systemName"] or:@"iOS"];
    p.systemVersion      = [self str:dict[@"systemVersion"] or:@""];
    p.deviceName         = [self str:dict[@"deviceName"] or:@"iPhone"];
    p.localeIdentifier   = [self str:dict[@"localeIdentifier"] or:@""];
    p.languageCode       = [self str:dict[@"languageCode"] or:@""];
    p.timezoneIdentifier = [self str:dict[@"timezoneIdentifier"] or:@""];
    p.screenWidth  = [dict[@"screenWidth"] respondsToSelector:@selector(integerValue)]  ? [dict[@"screenWidth"] integerValue]  : 0;
    p.screenHeight = [dict[@"screenHeight"] respondsToSelector:@selector(integerValue)] ? [dict[@"screenHeight"] integerValue] : 0;
    p.screenScale  = [dict[@"screenScale"] respondsToSelector:@selector(doubleValue)]   ? [dict[@"screenScale"] doubleValue]   : 0;
    p.metadata = [dict[@"metadata"] isKindOfClass:NSDictionary.class] ? dict[@"metadata"] : @{};
    return p;
}

+ (NSString *)str:(id)v or:(NSString *)fallback {
    return [v isKindOfClass:NSString.class] ? v : fallback;
}

- (instancetype)init {
    if ((self = [super init])) {
        _profileId = [[NSUUID UUID] UUIDString];
        _systemName = @"iOS";
        _deviceName = @"iPhone";
        _metadata = @{};
    }
    return self;
}

- (NSDictionary *)dictionaryValue {
    return @{
        @"id": self.profileId ?: @"",
        @"displayName": self.displayName ?: @"",
        @"deviceModel": self.deviceModel ?: @"",
        @"hardwareIdentifier": self.hardwareIdentifier ?: @"",
        @"systemName": self.systemName ?: @"iOS",
        @"systemVersion": self.systemVersion ?: @"",
        @"deviceName": self.deviceName ?: @"iPhone",
        @"localeIdentifier": self.localeIdentifier ?: @"",
        @"languageCode": self.languageCode ?: @"",
        @"timezoneIdentifier": self.timezoneIdentifier ?: @"",
        @"screenWidth": @(self.screenWidth),
        @"screenHeight": @(self.screenHeight),
        @"screenScale": @(self.screenScale),
        @"metadata": self.metadata ?: @{},
    };
}

- (id)copyWithZone:(NSZone *)zone {
    IADeviceProfile *c = [IADeviceProfile profileWithDictionary:[self dictionaryValue]];
    return c;
}

- (IADeviceProfile *)copyWithFreshID {
    IADeviceProfile *c = [self copy];
    c.profileId = [[NSUUID UUID] UUIDString];
    return c;
}

@end
