//
//  IADeviceProfileRandomizer.m
//  iOSAutoApp
//

#import "IADeviceProfileRandomizer.h"
#import "IADeviceProfile.h"
#import "IADeviceProfileValidator.h"

@implementation IADeviceProfileRandomizer {
    IADeviceProfileValidator *_validator;
}

- (instancetype)init {
    if ((self = [super init])) {
        _validator = [IADeviceProfileValidator new];
    }
    return self;
}

- (IADeviceProfile *)randomProfileFrom:(NSArray<IADeviceProfile *> *)candidates {
    return [self randomProfileFrom:candidates families:nil];
}

- (IADeviceProfile *)randomProfileFrom:(NSArray<IADeviceProfile *> *)candidates
                              families:(NSArray<NSString *> *)families {
    NSMutableArray<IADeviceProfile *> *pool = [NSMutableArray array];
    for (IADeviceProfile *p in candidates) {
        if (![[_validator validate:p] isValid]) continue;
        if (families.count) {
            NSDictionary *spec = [IADeviceProfileValidator specForHardwareIdentifier:p.hardwareIdentifier ?: @""];
            if (!spec || ![families containsObject:spec[@"family"]]) continue;
        }
        [pool addObject:p];
    }
    if (pool.count == 0) return nil;
    NSUInteger idx = arc4random_uniform((uint32_t)pool.count);
    return [pool[idx] copyWithFreshID];
}

@end
