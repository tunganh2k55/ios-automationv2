//
//  IADeviceProfileRepository.h
//  iOSAutoApp
//
//  Kho profile: bundled (device_profiles.json trong .app, chỉ đọc) + custom
//  (lưu cục bộ qua NSUserDefaults suite riêng). Không mạng, không daemon.
//

#import <Foundation/Foundation.h>

@class IADeviceProfile;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const IADeviceProfilesSuiteName; // "com.iosauto.deviceprofiles"

@interface IADeviceProfileRepository : NSObject

/// Profile đóng gói sẵn (đọc từ bundle; fallback danh sách nhúng nếu thiếu file).
- (NSArray<IADeviceProfile *> *)loadBundledProfiles;

/// Profile custom do người dùng tạo (đọc từ suite defaults).
- (NSArray<IADeviceProfile *> *)loadCustomProfiles;

/// Thêm mới / cập nhật (theo profileId) 1 custom profile.
- (void)saveCustomProfile:(IADeviceProfile *)profile;

/// Xoá custom profile theo id.
- (void)deleteCustomProfileId:(NSString *)profileId;

/// Gộp bundled + custom (custom ưu tiên khi trùng id).
- (NSArray<IADeviceProfile *> *)loadAllProfiles;

@end

NS_ASSUME_NONNULL_END
