//
//  IADeviceProfile.h
//  iOSAutoApp
//
//  Model hồ sơ thiết bị — THUẦN DỮ LIỆU, chỉ dùng preview cục bộ trong app.
//  KHÔNG đọc/ghi thông tin thiết bị thật, KHÔNG gửi ra daemon hay dịch vụ nào.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IADeviceProfile : NSObject <NSCopying>

@property (nonatomic, copy) NSString *profileId;          // UUID string
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *deviceModel;        // "iPhone 12"
@property (nonatomic, copy) NSString *hardwareIdentifier; // "iPhone13,2"
@property (nonatomic, copy) NSString *systemName;         // "iOS"
@property (nonatomic, copy) NSString *systemVersion;      // "16.6"
@property (nonatomic, copy) NSString *deviceName;         // "iPhone"
@property (nonatomic, copy) NSString *localeIdentifier;   // "en_US"
@property (nonatomic, copy) NSString *languageCode;       // "en"
@property (nonatomic, copy) NSString *timezoneIdentifier; // "America/New_York"
@property (nonatomic, assign) NSInteger screenWidth;      // point
@property (nonatomic, assign) NSInteger screenHeight;     // point
@property (nonatomic, assign) double screenScale;         // 2.0 | 3.0
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *metadata;

/// Tạo profile từ dictionary (đọc JSON / plist). Thiếu `id` → cấp UUID mới.
+ (instancetype)profileWithDictionary:(NSDictionary *)dict;

/// Serialize ra dictionary (ghi plist / log). Chỉ chứa kiểu property-list.
- (NSDictionary *)dictionaryValue;

/// Bản sao có cùng dữ liệu nhưng `profileId` mới (dùng khi random ra bản độc lập).
- (IADeviceProfile *)copyWithFreshID;

@end

NS_ASSUME_NONNULL_END
