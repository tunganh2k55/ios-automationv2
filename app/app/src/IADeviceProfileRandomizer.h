//
//  IADeviceProfileRandomizer.h
//  iOSAutoApp
//
//  Chọn NGẪU NHIÊN một profile HỢP LỆ NGUYÊN VẸN từ tập ứng viên. Không trộn
//  từng trường (tránh tổ hợp vô lý). Trả bản sao có id mới.
//

#import <Foundation/Foundation.h>

@class IADeviceProfile;

NS_ASSUME_NONNULL_BEGIN

@interface IADeviceProfileRandomizer : NSObject

/// Chọn ngẫu nhiên 1 profile hợp lệ trong `candidates`. nil nếu không có ứng viên hợp lệ.
- (nullable IADeviceProfile *)randomProfileFrom:(NSArray<IADeviceProfile *> *)candidates;

/// Lọc trước theo dòng máy (family, vd @"iPhone13") rồi random. nil nếu không khớp.
- (nullable IADeviceProfile *)randomProfileFrom:(NSArray<IADeviceProfile *> *)candidates
                                       families:(nullable NSArray<NSString *> *)families;

@end

NS_ASSUME_NONNULL_END
