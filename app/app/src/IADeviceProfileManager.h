//
//  IADeviceProfileManager.h
//  iOSAutoApp
//
//  Điều phối cục bộ: giữ activeProfile, validate trước khi Apply Local, lưu/khôi
//  phục lựa chọn. "Apply Local" CHỈ đổi activeProfile + phát notification để màn
//  demo refresh. TUYỆT ĐỐI không gọi daemon, không đổi thiết bị thật.
//

#import <Foundation/Foundation.h>
#import "IADeviceProfileValidator.h"

@class IADeviceProfile;
@class IADeviceProfileRepository;
@class IADeviceProfileRandomizer;

NS_ASSUME_NONNULL_BEGIN

/// Phát khi activeProfile (preview cục bộ) đổi. Chỉ màn demo lắng nghe.
extern NSString * const IADeviceProfileActiveDidChangeNotification;

@interface IADeviceProfileManager : NSObject

@property (class, readonly) IADeviceProfileManager *sharedManager;

/// Profile đang preview cục bộ (nil = không áp dụng gì, chỉ hiển thị mặc định).
@property (nonatomic, strong, readonly, nullable) IADeviceProfile *activeProfile;
@property (nonatomic, strong, readonly, nullable) NSDate *lastAppliedAt;

@property (nonatomic, strong, readonly) IADeviceProfileRepository *repository;
@property (nonatomic, strong, readonly) IADeviceProfileValidator *validator;
@property (nonatomic, strong, readonly) IADeviceProfileRandomizer *randomizer;

/// Khôi phục activeProfile đã lưu (nếu còn hợp lệ). Gọi khi mở màn demo.
- (void)bootstrap;

- (NSArray<IADeviceProfile *> *)loadAllProfiles;

/// Danh sách model máy (duy nhất) từ mọi profile, sort tăng dần theo tên.
- (NSArray<NSString *> *)availableDeviceModels;

/// Danh sách phiên bản iOS (duy nhất) khả dụng cho `model`, sort mới→cũ.
/// `model` nil/rỗng → gộp mọi phiên bản của mọi model.
- (NSArray<NSString *> *)availableVersionsForModel:(nullable NSString *)model;

/// TOÀN BỘ phiên bản iOS 15.x–16.x (danh sách cố định) cho người dùng chọn tự do.
- (NSArray<NSString *> *)availableIOSVersions;

/// Dựng profile cho (model, iOS): lấy base của `model` (hardware/màn/locale) rồi đặt
/// systemVersion = `version`. nil nếu không có base cho model. Chưa validate (Apply mới validate).
- (nullable IADeviceProfile *)profileForModel:(NSString *)model version:(NSString *)version;

- (IADeviceProfileValidationResult *)validate:(IADeviceProfile *)profile;

/// Apply Local: validate → set activeProfile → lưu → notify. Trả NO + điền error nếu invalid.
- (BOOL)applyLocalProfile:(IADeviceProfile *)profile error:(NSError * _Nullable * _Nullable)error;

/// Random 1 profile hợp lệ nguyên vẹn rồi apply local. Trả profile đã chọn (nil nếu rỗng).
- (nullable IADeviceProfile *)applyRandomLocal;

/// Xoá preview, quay về hiển thị mặc định.
- (void)reset;

- (void)saveCustomProfile:(IADeviceProfile *)profile;
- (void)deleteCustomProfileId:(NSString *)profileId;

@end

NS_ASSUME_NONNULL_END
