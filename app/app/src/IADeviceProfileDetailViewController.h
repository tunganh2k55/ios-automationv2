//
//  IADeviceProfileDetailViewController.h
//  iOSAutoApp
//
//  Chi tiết 1 profile (LOCAL PREVIEW ONLY) + tạo/sửa custom profile.
//

#import <UIKit/UIKit.h>

@class IADeviceProfile;

NS_ASSUME_NONNULL_BEGIN

@interface IADeviceProfileDetailViewController : UITableViewController

/// - profile = nil, editing = YES → tạo mới.
/// - profile != nil, editing = NO → xem chi tiết.
/// - profile != nil, editing = YES → chỉnh sửa.
- (instancetype)initWithProfile:(nullable IADeviceProfile *)profile editing:(BOOL)editing;

@end

NS_ASSUME_NONNULL_END
