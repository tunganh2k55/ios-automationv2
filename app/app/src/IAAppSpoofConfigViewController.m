//
//  IAAppSpoofConfigViewController.m
//  iOSAutoApp
//

#import "IAAppSpoofConfigViewController.h"
#import "IADeviceProfileManager.h"
#import "IADeviceProfileRandomizer.h"
#import "IADeviceProfileValidator.h"
#import "IADeviceProfile.h"

static NSString *const kIAApiBase = @"http://127.0.0.1:8080/api/";

@interface UIImage (IAPrivateIcon2)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

// Section layout
enum { kCfgApp = 0, kCfgMode, kCfgManual, kCfgActions, kCfgCount };

@interface IAAppSpoofConfigViewController ()
@property (nonatomic, copy)   NSString *bundleId;
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, assign) BOOL randomOn;
@property (nonatomic, copy)   NSString *selectedModel;
@property (nonatomic, copy)   NSString *selectedVersion;
@property (nonatomic, strong) NSDictionary *currentAssignment;   // gán hiện tại (nil = chưa spoof)
@end

@implementation IAAppSpoofConfigViewController

- (instancetype)initWithBundleId:(NSString *)bundleId name:(NSString *)name {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _bundleId = [bundleId copy];
        _appName = [name copy];
        self.title = name ?: bundleId;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    [self loadAssignment];
}

// Hỏi daemon app này đã spoof chưa → prefill.
- (void)loadAssignment {
    [self apiGET:@"profile/list" done:^(id json) {
        NSDictionary *as = [json isKindOfClass:NSDictionary.class] ? json[@"assignments"] : nil;
        id cur = [as isKindOfClass:NSDictionary.class] ? as[self.bundleId] : nil;
        self.currentAssignment = [cur isKindOfClass:NSDictionary.class] ? cur : nil;
        if (self.currentAssignment) {
            self.selectedModel   = self.currentAssignment[@"deviceModel"];
            self.selectedVersion = self.currentAssignment[@"systemVersion"];
        }
        [self.tableView reloadData];
    }];
}

#pragma mark - API

- (void)apiGET:(NSString *)path done:(void (^)(id json))done {
    NSURL *u = [NSURL URLWithString:[kIAApiBase stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(j); });
    }] resume];
}

- (void)apiPOST:(NSString *)path body:(NSDictionary *)body done:(void (^)(id json, NSError *err))done {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kIAApiBase stringByAppendingString:path]]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 8;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(j, e); });
    }] resume];
}

- (UIImage *)appIcon {
    @try {
        if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
            UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:self.bundleId format:2 scale:UIScreen.mainScreen.scale];
            if (img) return img;
        }
    } @catch (__unused NSException *e) {}
    return [UIImage systemImageNamed:@"app.fill"];
}

#pragma mark - Actions

- (void)randomToggled:(UISwitch *)sw {
    self.randomOn = sw.isOn;
    [self.tableView reloadData];   // ẩn/hiện phần chọn thủ công
}

- (void)pickModel {
    NSArray<NSString *> *models = [[IADeviceProfileManager sharedManager] availableDeviceModels];
    if (!models.count) { [self alert:@"Chưa có model nào."]; return; }
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Model máy" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *m in models) {
        UIAlertAction *act = [UIAlertAction actionWithTitle:m style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *_) { self.selectedModel = m; [self.tableView reloadData]; }];
        if ([m isEqualToString:self.selectedModel]) [act setValue:@YES forKey:@"checked"];
        [ac addAction:act];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:ac section:kCfgManual row:0];
}

- (void)pickVersion {
    NSArray<NSString *> *versions = [[IADeviceProfileManager sharedManager] availableIOSVersions];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Phiên bản iOS" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *v in versions) {
        UIAlertAction *act = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"iOS %@", v]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *_) { self.selectedVersion = v; [self.tableView reloadData]; }];
        if ([v isEqualToString:self.selectedVersion]) [act setValue:@YES forKey:@"checked"];
        [ac addAction:act];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:ac section:kCfgManual row:1];
}

- (void)applyTapped {
    IADeviceProfileManager *mgr = [IADeviceProfileManager sharedManager];
    IADeviceProfile *p = nil;
    if (self.randomOn) {
        p = [mgr.randomizer randomProfileFrom:[mgr loadAllProfiles]];   // profile hợp lệ nguyên vẹn
        if (!p) { [self alert:@"Không có profile hợp lệ để random."]; return; }
        self.selectedModel = p.deviceModel; self.selectedVersion = p.systemVersion;
    } else {
        if (!self.selectedModel.length)   { [self alert:@"Hãy chọn Model máy."]; return; }
        if (!self.selectedVersion.length) { [self alert:@"Hãy chọn Phiên bản iOS."]; return; }
        p = [mgr profileForModel:self.selectedModel version:self.selectedVersion];
        if (!p) { [self alert:@"Không dựng được profile."]; return; }
        IADeviceProfileValidationResult *r = [mgr validate:p];
        if (!r.isValid) { [self alert:r.errors.firstObject ?: @"Lựa chọn không hợp lệ."]; return; }
    }
    NSDictionary *body = @{
        @"bundleId":           self.bundleId ?: @"",
        @"deviceModel":        p.deviceModel ?: @"",
        @"hardwareIdentifier": p.hardwareIdentifier ?: @"",
        @"systemName":         p.systemName ?: @"iOS",
        @"systemVersion":      p.systemVersion ?: @"",
        @"deviceName":         p.deviceName ?: @"iPhone",
        @"localeIdentifier":   p.localeIdentifier ?: @"",
        @"languageCode":       p.languageCode ?: @"",
        @"timezoneIdentifier": p.timezoneIdentifier ?: @"",
        @"screenWidth":        @(p.screenWidth),
        @"screenHeight":       @(p.screenHeight),
        @"screenScale":        @(p.screenScale),
    };
    [self apiPOST:@"profile/apply" body:body done:^(id j, NSError *e) {
        BOOL ok = [j[@"ok"] boolValue];
        if (ok) self.currentAssignment = body;
        [self.tableView reloadData];
        NSString *msg = [j[@"msg"] isKindOfClass:NSString.class] ? j[@"msg"]
                        : (e ? @"Lỗi kết nối daemon" : (ok ? @"Đã áp dụng" : @"Áp dụng lỗi"));
        [self alert:[NSString stringWithFormat:@"%@\n%@ · iOS %@", msg, p.deviceModel, p.systemVersion]];
    }];
}

- (void)removeSpoof {
    [self apiPOST:@"profile/clear" body:@{@"bundleId": self.bundleId ?: @""} done:^(id j, NSError *e) {
        self.currentAssignment = nil;
        self.selectedModel = nil; self.selectedVersion = nil;
        [self.tableView reloadData];
        [self alert:@"Đã xoá spoof cho app này (mở lại app để trở về mặc định)."];
    }];
}

- (void)alert:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)presentSheet:(UIAlertController *)ac section:(NSInteger)s row:(NSInteger)r {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:r inSection:s]];
    ac.popoverPresentationController.sourceView = cell ?: self.view;
    ac.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return kCfgCount; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == kCfgApp)     return 1;
    if (s == kCfgMode)    return 1;
    if (s == kCfgManual)  return self.randomOn ? 0 : 2;   // Model / iOS (ẩn khi Random)
    return self.currentAssignment ? 2 : 1;                // Áp dụng [+ Xoá spoof]
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (s == kCfgApp)    return @"App";
    if (s == kCfgMode)   return @"Chế độ";
    if (s == kCfgManual) return self.randomOn ? nil : @"Chọn thủ công";
    return @"Hành động";
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == kCfgApp) {
        if (self.currentAssignment)
            return [NSString stringWithFormat:@"Đang spoof: %@ · iOS %@",
                    self.currentAssignment[@"deviceModel"], self.currentAssignment[@"systemVersion"]];
        return @"Chưa spoof — chọn cấu hình bên dưới rồi Áp dụng.";
    }
    if (s == kCfgMode) return @"Bật Random để daemon tự chọn model + iOS hợp lệ. Tắt để tự chọn.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == kCfgApp) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = self.appName ?: self.bundleId;
        c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        c.detailTextLabel.text = self.bundleId;
        c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        c.imageView.image = [self appIcon];
        c.imageView.layer.cornerRadius = 8; c.imageView.clipsToBounds = YES;
        c.imageView.contentMode = UIViewContentModeScaleAspectFit;
        if (self.currentAssignment) {
            UIImageView *tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
            tick.tintColor = [UIColor systemGreenColor];
            c.accessoryView = tick;
        }
        return c;
    }
    if (ip.section == kCfgMode) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"mode"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = @"🎲 Ngẫu nhiên (Random)";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = self.randomOn;
        [sw addTarget:self action:@selector(randomToggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    if (ip.section == kCfgManual) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"sel"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        BOOL isModel = (ip.row == 0);
        c.textLabel.text = isModel ? @"Model máy" : @"Phiên bản iOS";
        NSString *val = isModel ? self.selectedModel
                                : (self.selectedVersion ? [NSString stringWithFormat:@"iOS %@", self.selectedVersion] : nil);
        c.detailTextLabel.text = val ?: (isModel ? @"Chọn model…" : @"Chọn iOS…");
        c.detailTextLabel.textColor = val ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        return c;
    }
    // kCfgActions
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"act"];
    if (ip.row == 0) {
        c.textLabel.text = @"✓ Áp dụng";
        c.textLabel.textColor = self.view.tintColor;
    } else {
        c.textLabel.text = @"↺ Xoá spoof";
        c.textLabel.textColor = [UIColor systemRedColor];
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == kCfgManual) {
        if (ip.row == 0) [self pickModel]; else [self pickVersion];
    } else if (ip.section == kCfgActions) {
        if (ip.row == 0) [self applyTapped]; else [self removeSpoof];
    }
}

@end
