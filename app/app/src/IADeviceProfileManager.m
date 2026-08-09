//
//  IADeviceProfileManager.m
//  iOSAutoApp
//

#import "IADeviceProfileManager.h"
#import "IADeviceProfile.h"
#import "IADeviceProfileRepository.h"
#import "IADeviceProfileRandomizer.h"

NSString * const IADeviceProfileActiveDidChangeNotification = @"IADeviceProfileActiveDidChangeNotification";

static NSString * const kActiveIdKey = @"activeProfileId";
static NSString * const kLastAppliedKey = @"lastAppliedAt";
static NSString * const kErrorDomain = @"IADeviceProfile";

@implementation IADeviceProfileManager {
    NSUserDefaults *_store;
    IADeviceProfile *_activeProfile;
    NSDate *_lastAppliedAt;
}

+ (IADeviceProfileManager *)sharedManager {
    static IADeviceProfileManager *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[IADeviceProfileManager alloc] initPrivate]; });
    return shared;
}

- (instancetype)initPrivate {
    if ((self = [super init])) {
        _repository = [IADeviceProfileRepository new];
        _validator = [IADeviceProfileValidator new];
        _randomizer = [IADeviceProfileRandomizer new];
        _store = [[NSUserDefaults alloc] initWithSuiteName:IADeviceProfilesSuiteName] ?: [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (IADeviceProfile *)activeProfile { return _activeProfile; }
- (NSDate *)lastAppliedAt { return _lastAppliedAt; }

- (void)bootstrap {
    _lastAppliedAt = [_store objectForKey:kLastAppliedKey];
    NSString *savedId = [_store stringForKey:kActiveIdKey];
    if (savedId.length == 0) { _activeProfile = nil; return; }
    IADeviceProfile *found = nil;
    for (IADeviceProfile *p in [self loadAllProfiles])
        if ([p.profileId isEqualToString:savedId]) { found = p; break; }
    if (found && [[self.validator validate:found] isValid]) {
        _activeProfile = found;
    } else {
        // Profile không còn / không hợp lệ → dọn về mặc định.
        _activeProfile = nil;
        [_store removeObjectForKey:kActiveIdKey];
    }
}

- (NSArray<IADeviceProfile *> *)loadAllProfiles {
    return [self.repository loadAllProfiles];
}

- (NSArray<NSString *> *)availableDeviceModels {
    NSMutableOrderedSet *models = [NSMutableOrderedSet orderedSet];
    for (IADeviceProfile *p in [self loadAllProfiles])
        if (p.deviceModel.length) [models addObject:p.deviceModel];
    return [models.array sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a localizedStandardCompare:b];
    }];
}

- (NSArray<NSString *> *)availableVersionsForModel:(NSString *)model {
    NSMutableOrderedSet *versions = [NSMutableOrderedSet orderedSet];
    for (IADeviceProfile *p in [self loadAllProfiles]) {
        if (model.length && ![p.deviceModel isEqualToString:model]) continue;
        if (p.systemVersion.length) [versions addObject:p.systemVersion];
    }
    return [versions.array sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a options:NSNumericSearch]; // mới → cũ
    }];
}

- (NSArray<NSString *> *)availableIOSVersions {
    return @[
        @"15.0", @"15.0.1", @"15.0.2", @"15.1", @"15.1.1", @"15.2", @"15.2.1", @"15.3", @"15.3.1",
        @"15.4", @"15.4.1", @"15.5", @"15.6", @"15.6.1", @"15.7", @"15.7.1", @"15.7.2", @"15.7.3",
        @"15.7.4", @"15.7.5", @"15.7.6", @"15.7.7", @"15.7.8", @"15.8", @"15.8.1", @"15.8.2",
        @"15.8.3", @"15.8.4", @"15.8.5",
        @"16", @"16.0", @"16.0.1", @"16.0.2", @"16.1", @"16.1.1", @"16.1.2", @"16.2", @"16.3",
        @"16.3.1", @"16.4", @"16.4.1", @"16.5", @"16.5.1", @"16.6", @"16.6.1", @"16.7", @"16.7.1",
        @"16.7.2", @"16.7.3", @"16.7.4", @"16.7.5", @"16.7.6", @"16.7.7", @"16.7.8", @"16.7.9",
        @"16.7.10",
    ];
}

- (IADeviceProfile *)profileForModel:(NSString *)model version:(NSString *)version {
    if (!model.length || !version.length) return nil;
    IADeviceProfile *base = nil;
    for (IADeviceProfile *p in [self loadAllProfiles])
        if ([p.deviceModel isEqualToString:model]) { base = p; break; }
    if (!base) return nil;
    IADeviceProfile *out = [base copyWithFreshID];   // giữ hardware/màn/locale/timezone của model
    out.systemName = @"iOS";
    out.systemVersion = version;
    out.displayName = [NSString stringWithFormat:@"%@ - iOS %@", model, version];
    return out;
}

- (IADeviceProfileValidationResult *)validate:(IADeviceProfile *)profile {
    return [self.validator validate:profile];
}

- (BOOL)applyLocalProfile:(IADeviceProfile *)profile error:(NSError * _Nullable *)error {
    IADeviceProfileValidationResult *r = [self.validator validate:profile];
    if (!r.isValid) {
        if (error) {
            NSString *msg = r.errors.firstObject ?: @"Profile không hợp lệ.";
            *error = [NSError errorWithDomain:kErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    }
    _activeProfile = profile;
    [self persistActive];
    [self notifyChange];
    return YES;
}

- (IADeviceProfile *)applyRandomLocal {
    IADeviceProfile *picked = [self.randomizer randomProfileFrom:[self loadAllProfiles]];
    if (!picked) return nil;
    _activeProfile = picked;
    [self persistActive];
    [self notifyChange];
    return picked;
}

- (void)reset {
    _activeProfile = nil;
    _lastAppliedAt = [NSDate date];
    [_store removeObjectForKey:kActiveIdKey];
    [_store setObject:_lastAppliedAt forKey:kLastAppliedKey];
    [self notifyChange];
}

- (void)saveCustomProfile:(IADeviceProfile *)profile {
    [self.repository saveCustomProfile:profile];
}

- (void)deleteCustomProfileId:(NSString *)profileId {
    [self.repository deleteCustomProfileId:profileId];
    if ([_activeProfile.profileId isEqualToString:profileId]) [self reset];
}

#pragma mark - Private

- (void)persistActive {
    _lastAppliedAt = [NSDate date];
    [_store setObject:_activeProfile.profileId forKey:kActiveIdKey];
    [_store setObject:_lastAppliedAt forKey:kLastAppliedKey];
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:IADeviceProfileActiveDidChangeNotification object:self];
}

@end
