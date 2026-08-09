//
//  IADeviceProfileValidator.m
//  iOSAutoApp
//

#import "IADeviceProfileValidator.h"
#import "IADeviceProfile.h"

@implementation IADeviceProfileValidationResult
@end

@implementation IADeviceProfileValidator

+ (NSInteger)maxKnownIOSMajor { return 18; }

+ (NSArray<NSDictionary *> *)catalog {
    static NSArray *cat = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cat = @[
            // iPhone 11 (iOS 13+)
            @{@"marketing":@"iPhone 11",         @"hwid":@"iPhone12,1", @"family":@"iPhone11", @"w":@414, @"h":@896, @"scale":@2.0, @"minIOS":@13},
            @{@"marketing":@"iPhone 11 Pro",     @"hwid":@"iPhone12,3", @"family":@"iPhone11", @"w":@375, @"h":@812, @"scale":@3.0, @"minIOS":@13},
            @{@"marketing":@"iPhone 11 Pro Max", @"hwid":@"iPhone12,5", @"family":@"iPhone11", @"w":@414, @"h":@896, @"scale":@3.0, @"minIOS":@13},
            // iPhone 12 (iOS 14+)
            @{@"marketing":@"iPhone 12 mini",    @"hwid":@"iPhone13,1", @"family":@"iPhone12", @"w":@375, @"h":@812, @"scale":@3.0, @"minIOS":@14},
            @{@"marketing":@"iPhone 12",         @"hwid":@"iPhone13,2", @"family":@"iPhone12", @"w":@390, @"h":@844, @"scale":@3.0, @"minIOS":@14},
            @{@"marketing":@"iPhone 12 Pro",     @"hwid":@"iPhone13,3", @"family":@"iPhone12", @"w":@390, @"h":@844, @"scale":@3.0, @"minIOS":@14},
            @{@"marketing":@"iPhone 12 Pro Max", @"hwid":@"iPhone13,4", @"family":@"iPhone12", @"w":@428, @"h":@926, @"scale":@3.0, @"minIOS":@14},
            // iPhone 13 (iOS 15+)
            @{@"marketing":@"iPhone 13 mini",    @"hwid":@"iPhone14,4", @"family":@"iPhone13", @"w":@375, @"h":@812, @"scale":@3.0, @"minIOS":@15},
            @{@"marketing":@"iPhone 13",         @"hwid":@"iPhone14,5", @"family":@"iPhone13", @"w":@390, @"h":@844, @"scale":@3.0, @"minIOS":@15},
            @{@"marketing":@"iPhone 13 Pro",     @"hwid":@"iPhone14,2", @"family":@"iPhone13", @"w":@390, @"h":@844, @"scale":@3.0, @"minIOS":@15},
            @{@"marketing":@"iPhone 13 Pro Max", @"hwid":@"iPhone14,3", @"family":@"iPhone13", @"w":@428, @"h":@926, @"scale":@3.0, @"minIOS":@15},
            // iPhone 14 (iOS 16+)
            @{@"marketing":@"iPhone 14",         @"hwid":@"iPhone14,7", @"family":@"iPhone14", @"w":@390, @"h":@844, @"scale":@3.0, @"minIOS":@16},
            @{@"marketing":@"iPhone 14 Plus",    @"hwid":@"iPhone14,8", @"family":@"iPhone14", @"w":@428, @"h":@926, @"scale":@3.0, @"minIOS":@16},
            @{@"marketing":@"iPhone 14 Pro",     @"hwid":@"iPhone15,2", @"family":@"iPhone14", @"w":@393, @"h":@852, @"scale":@3.0, @"minIOS":@16},
            @{@"marketing":@"iPhone 14 Pro Max", @"hwid":@"iPhone15,3", @"family":@"iPhone14", @"w":@430, @"h":@932, @"scale":@3.0, @"minIOS":@16},
        ];
    });
    return cat;
}

+ (NSDictionary *)specForHardwareIdentifier:(NSString *)hwid {
    for (NSDictionary *s in [self catalog]) {
        if ([s[@"hwid"] isEqualToString:hwid]) return s;
    }
    return nil;
}

- (IADeviceProfileValidationResult *)validate:(IADeviceProfile *)p {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];

    // 1. Trường bắt buộc không rỗng.
    NSDictionary *req = @{
        @"displayName": p.displayName ?: @"",
        @"deviceModel": p.deviceModel ?: @"",
        @"hardwareIdentifier": p.hardwareIdentifier ?: @"",
        @"systemName": p.systemName ?: @"",
        @"systemVersion": p.systemVersion ?: @"",
        @"deviceName": p.deviceName ?: @"",
        @"localeIdentifier": p.localeIdentifier ?: @"",
        @"languageCode": p.languageCode ?: @"",
        @"timezoneIdentifier": p.timezoneIdentifier ?: @"",
    };
    for (NSString *k in req) {
        if ([[req[k] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] == 0)
            [errors addObject:[NSString stringWithFormat:@"Trường bắt buộc bị rỗng: %@.", k]];
    }
    if (p.screenWidth <= 0 || p.screenHeight <= 0)
        [errors addObject:[NSString stringWithFormat:@"Kích thước màn hình phải > 0 (đang %ldx%ld).", (long)p.screenWidth, (long)p.screenHeight]];

    // 2. Định dạng hardware id.
    if (![self matches:p.hardwareIdentifier pattern:@"^iPhone[0-9]{1,2},[0-9]{1,2}$"])
        [errors addObject:[NSString stringWithFormat:@"Hardware identifier sai định dạng: '%@' (mong đợi 'iPhone13,2').", p.hardwareIdentifier ?: @""]];

    // 3. Định dạng system version.
    if (![self matches:p.systemVersion pattern:@"^[0-9]{1,2}(\\.[0-9]{1,2}){0,2}$"])
        [errors addObject:[NSString stringWithFormat:@"System version sai định dạng: '%@' (mong đợi '16.6').", p.systemVersion ?: @""]];

    // 4. Model tồn tại + khớp hardware id + màn hình + iOS.
    NSDictionary *spec = [IADeviceProfileValidator specForHardwareIdentifier:p.hardwareIdentifier ?: @""];
    NSInteger major = [self majorVersion:p.systemVersion];
    if (spec) {
        NSString *marketing = spec[@"marketing"];
        if (![marketing.lowercaseString isEqualToString:(p.deviceModel ?: @"").lowercaseString])
            [warnings addObject:[NSString stringWithFormat:@"deviceModel '%@' không khớp %@ (catalog: '%@').", p.deviceModel ?: @"", p.hardwareIdentifier, marketing]];

        NSInteger sw = [spec[@"w"] integerValue], sh = [spec[@"h"] integerValue];
        BOOL portrait  = (p.screenWidth == sw && p.screenHeight == sh);
        BOOL landscape = (p.screenWidth == sh && p.screenHeight == sw);
        if (!(portrait || landscape))
            [errors addObject:[NSString stringWithFormat:@"Màn hình %ldx%ld không khớp %@ (%ldx%ld).", (long)p.screenWidth, (long)p.screenHeight, marketing, (long)sw, (long)sh]];
        if (fabs(p.screenScale - [spec[@"scale"] doubleValue]) > 0.001)
            [errors addObject:[NSString stringWithFormat:@"Screen scale %.1f không khớp %@ (%.1f).", p.screenScale, marketing, [spec[@"scale"] doubleValue]]];

        NSInteger minIOS = [spec[@"minIOS"] integerValue];
        if (major > 0 && major < minIOS)
            [errors addObject:[NSString stringWithFormat:@"iOS %@ thấp hơn mức tối thiểu của %@ (iOS %ld).", p.systemVersion, marketing, (long)minIOS]];
        if (major > [IADeviceProfileValidator maxKnownIOSMajor])
            [errors addObject:[NSString stringWithFormat:@"iOS %@ cao hơn mức đã biết (iOS %ld).", p.systemVersion, (long)[IADeviceProfileValidator maxKnownIOSMajor]]];
    } else {
        [errors addObject:[NSString stringWithFormat:@"Không nhận diện được thiết bị từ hardware id '%@'.", p.hardwareIdentifier ?: @""]];
        if (major > 0 && (major < 12 || major > [IADeviceProfileValidator maxKnownIOSMajor]))
            [errors addObject:[NSString stringWithFormat:@"iOS %@ nằm ngoài khoảng hợp lý (12..%ld).", p.systemVersion, (long)[IADeviceProfileValidator maxKnownIOSMajor]]];
    }

    // 5. Timezone hợp lệ.
    if (p.timezoneIdentifier.length && [NSTimeZone timeZoneWithName:p.timezoneIdentifier] == nil)
        [errors addObject:[NSString stringWithFormat:@"Timezone không hợp lệ: '%@'.", p.timezoneIdentifier]];

    // 6. Locale hợp lệ.
    if (![self isValidLocale:p.localeIdentifier])
        [errors addObject:[NSString stringWithFormat:@"Locale không hợp lệ: '%@'.", p.localeIdentifier ?: @""]];

    // 7. Language code hợp lệ.
    if (![self isValidLanguageCode:p.languageCode])
        [errors addObject:[NSString stringWithFormat:@"Language code không hợp lệ: '%@'.", p.languageCode ?: @""]];

    // 8. Screen scale hợp lý.
    if (fabs(p.screenScale - 2.0) > 0.001 && fabs(p.screenScale - 3.0) > 0.001)
        [warnings addObject:[NSString stringWithFormat:@"Screen scale bất thường: %.1f (thường 2 hoặc 3).", p.screenScale]];

    // 9. Coherence language <-> locale, region <-> timezone (chỉ warning).
    NSString *localeLang = [self languageComponentOf:p.localeIdentifier];
    if (localeLang && p.languageCode.length && ![localeLang.lowercaseString isEqualToString:p.languageCode.lowercaseString])
        [warnings addObject:[NSString stringWithFormat:@"languageCode '%@' không khớp locale '%@'.", p.languageCode, p.localeIdentifier]];

    NSString *region = [self regionComponentOf:p.localeIdentifier];
    NSDictionary *regionTZ = @{ @"US":@[@"America/"], @"GB":@[@"Europe/London"], @"JP":@[@"Asia/Tokyo"],
                                @"VN":@[@"Asia/Ho_Chi_Minh", @"Asia/Saigon"], @"KR":@[@"Asia/Seoul"],
                                @"FR":@[@"Europe/Paris"], @"DE":@[@"Europe/Berlin"] };
    NSArray *prefixes = region ? regionTZ[region.uppercaseString] : nil;
    if (prefixes) {
        BOOL ok = NO;
        for (NSString *pre in prefixes) if ([p.timezoneIdentifier hasPrefix:pre]) { ok = YES; break; }
        if (!ok) [warnings addObject:[NSString stringWithFormat:@"Timezone '%@' không phổ biến với vùng '%@'.", p.timezoneIdentifier ?: @"", region]];
    }

    IADeviceProfileValidationResult *r = [IADeviceProfileValidationResult new];
    r.errors = errors;
    r.warnings = warnings;
    r.isValid = (errors.count == 0);
    return r;
}

#pragma mark - Helpers

- (BOOL)matches:(NSString *)value pattern:(NSString *)pattern {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSRange r = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return r.location != NSNotFound;
}

- (NSInteger)majorVersion:(NSString *)version {
    if (![version isKindOfClass:NSString.class] || version.length == 0) return 0;
    NSArray *parts = [version componentsSeparatedByString:@"."];
    return parts.count ? [parts[0] integerValue] : 0;
}

- (NSString *)languageComponentOf:(NSString *)localeId {
    if (![localeId isKindOfClass:NSString.class] || localeId.length == 0) return nil;
    NSString *n = [localeId stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    NSArray *parts = [n componentsSeparatedByString:@"_"];
    return parts.count ? parts[0] : nil;
}

- (NSString *)regionComponentOf:(NSString *)localeId {
    if (![localeId isKindOfClass:NSString.class] || localeId.length == 0) return nil;
    NSString *n = [localeId stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    NSArray *parts = [n componentsSeparatedByString:@"_"];
    return parts.count >= 2 ? parts[1] : nil;
}

- (BOOL)isValidLocale:(NSString *)identifier {
    NSString *lang = [self languageComponentOf:identifier];
    if (!lang) return NO;
    if ([[NSLocale availableLocaleIdentifiers] containsObject:identifier]) return YES;
    NSString *n = [identifier stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if ([[NSLocale availableLocaleIdentifiers] containsObject:n]) return YES;
    return lang.length >= 2;
}

- (BOOL)isValidLanguageCode:(NSString *)code {
    if (![code isKindOfClass:NSString.class]) return NO;
    if (code.length != 2 && code.length != 3) return NO;
    static NSSet *known = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        known = [NSSet setWithArray:@[@"en",@"vi",@"ja",@"ko",@"fr",@"de",@"es",@"pt",@"it",@"nl",
                                      @"ru",@"zh",@"th",@"id",@"ms",@"ar",@"hi",@"tr",@"pl",@"sv"]];
    });
    return [known containsObject:code.lowercaseString];
}

@end
