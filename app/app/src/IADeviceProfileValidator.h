//
//  IADeviceProfileValidator.h
//  iOSAutoApp
//
//  Kiểm tra profile hợp lệ + tương thích model/iOS/màn hình/locale/timezone.
//  errors → chặn Apply; warnings → chỉ cảnh báo. Không đọc thiết bị thật.
//

#import <Foundation/Foundation.h>

@class IADeviceProfile;

NS_ASSUME_NONNULL_BEGIN

@interface IADeviceProfileValidationResult : NSObject
@property (nonatomic, assign) BOOL isValid;
@property (nonatomic, copy) NSArray<NSString *> *errors;
@property (nonatomic, copy) NSArray<NSString *> *warnings;
@end

@interface IADeviceProfileValidator : NSObject

- (IADeviceProfileValidationResult *)validate:(IADeviceProfile *)profile;

/// Catalog thiết bị tĩnh (dữ liệu công khai). Mỗi phần tử là dictionary với các
/// khoá: marketing, hwid, family, w, h, scale, minIOS.
+ (NSArray<NSDictionary *> *)catalog;

/// Tra spec theo hardware identifier ("iPhone13,2"). nil nếu không có.
+ (nullable NSDictionary *)specForHardwareIdentifier:(NSString *)hwid;

/// Ngưỡng iOS major cao nhất coi là hợp lý.
+ (NSInteger)maxKnownIOSMajor;

@end

NS_ASSUME_NONNULL_END
