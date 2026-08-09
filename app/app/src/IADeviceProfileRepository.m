//
//  IADeviceProfileRepository.m
//  iOSAutoApp
//

#import "IADeviceProfileRepository.h"
#import "IADeviceProfile.h"

NSString * const IADeviceProfilesSuiteName = @"com.iosauto.deviceprofiles";

static NSString * const kCustomProfilesKey = @"customProfiles";

@implementation IADeviceProfileRepository {
    NSUserDefaults *_store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _store = [[NSUserDefaults alloc] initWithSuiteName:IADeviceProfilesSuiteName] ?: [NSUserDefaults standardUserDefaults];
    }
    return self;
}

#pragma mark - Bundled

- (NSArray<IADeviceProfile *> *)loadBundledProfiles {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"device_profiles" ofType:@"json"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    NSArray *arr = nil;
    if (data) {
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([json isKindOfClass:NSArray.class]) arr = json;
    }
    if (!arr) arr = [self embeddedFallback]; // an toàn nếu resource chưa được copy vào .app
    NSMutableArray<IADeviceProfile *> *out = [NSMutableArray array];
    for (id d in arr) if ([d isKindOfClass:NSDictionary.class]) [out addObject:[IADeviceProfile profileWithDictionary:d]];
    return out;
}

#pragma mark - Custom (CRUD)

- (NSArray<IADeviceProfile *> *)loadCustomProfiles {
    id raw = [_store objectForKey:kCustomProfilesKey];
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<IADeviceProfile *> *out = [NSMutableArray array];
    for (id d in raw) if ([d isKindOfClass:NSDictionary.class]) [out addObject:[IADeviceProfile profileWithDictionary:d]];
    return out;
}

- (void)saveCustomProfile:(IADeviceProfile *)profile {
    NSMutableArray<IADeviceProfile *> *list = [[self loadCustomProfiles] mutableCopy];
    NSInteger found = -1;
    for (NSInteger i = 0; i < (NSInteger)list.count; i++)
        if ([list[i].profileId isEqualToString:profile.profileId]) { found = i; break; }
    if (found >= 0) list[found] = profile; else [list addObject:profile];
    [self persistCustom:list];
}

- (void)deleteCustomProfileId:(NSString *)profileId {
    NSMutableArray<IADeviceProfile *> *list = [[self loadCustomProfiles] mutableCopy];
    NSMutableArray *keep = [NSMutableArray array];
    for (IADeviceProfile *p in list) if (![p.profileId isEqualToString:profileId]) [keep addObject:p];
    [self persistCustom:keep];
}

- (NSArray<IADeviceProfile *> *)loadAllProfiles {
    NSArray<IADeviceProfile *> *bundled = [self loadBundledProfiles];
    NSArray<IADeviceProfile *> *custom = [self loadCustomProfiles];
    NSMutableSet *customIds = [NSMutableSet set];
    for (IADeviceProfile *p in custom) [customIds addObject:p.profileId];
    NSMutableArray<IADeviceProfile *> *out = [NSMutableArray array];
    for (IADeviceProfile *p in bundled) if (![customIds containsObject:p.profileId]) [out addObject:p];
    [out addObjectsFromArray:custom];
    return out;
}

#pragma mark - Private

- (void)persistCustom:(NSArray<IADeviceProfile *> *)list {
    NSMutableArray *dicts = [NSMutableArray array];
    for (IADeviceProfile *p in list) [dicts addObject:[p dictionaryValue]];
    [_store setObject:dicts forKey:kCustomProfilesKey];
}

- (NSArray *)embeddedFallback {
    return @[
        @{@"displayName":@"iPhone 12 - iOS 16 (US)", @"deviceModel":@"iPhone 12", @"hardwareIdentifier":@"iPhone13,2",
          @"systemName":@"iOS", @"systemVersion":@"16.6", @"localeIdentifier":@"en_US", @"languageCode":@"en",
          @"timezoneIdentifier":@"America/New_York", @"screenWidth":@390, @"screenHeight":@844, @"screenScale":@3},
        @{@"displayName":@"iPhone 13 Pro - iOS 16 (VN)", @"deviceModel":@"iPhone 13 Pro", @"hardwareIdentifier":@"iPhone14,2",
          @"systemName":@"iOS", @"systemVersion":@"16.3", @"localeIdentifier":@"vi_VN", @"languageCode":@"vi",
          @"timezoneIdentifier":@"Asia/Ho_Chi_Minh", @"screenWidth":@390, @"screenHeight":@844, @"screenScale":@3},
    ];
}

@end
