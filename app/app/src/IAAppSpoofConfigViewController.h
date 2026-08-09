//
//  IAAppSpoofConfigViewController.h
//  iOSAutoApp
//
//  Cấu hình spoof cho MỘT app: bật Random (tự chọn model+iOS) hoặc tắt để tự chọn.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IAAppSpoofConfigViewController : UITableViewController

- (instancetype)initWithBundleId:(NSString *)bundleId name:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
