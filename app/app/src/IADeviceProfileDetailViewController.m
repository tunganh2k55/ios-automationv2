//
//  IADeviceProfileDetailViewController.m
//  iOSAutoApp
//

#import "IADeviceProfileDetailViewController.h"
#import "IADeviceProfileManager.h"
#import "IADeviceProfile.h"
#import "IADeviceProfileValidator.h"

@interface IADeviceProfileDetailViewController ()
@property (nonatomic, strong) IADeviceProfile *profile;      // bản làm việc
@property (nonatomic, assign) BOOL editMode;
@property (nonatomic, assign) BOOL createMode;               // profile ban đầu nil
@property (nonatomic, strong) IADeviceProfileValidationResult *validation;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UITextField *> *fields;
@end

@implementation IADeviceProfileDetailViewController

- (instancetype)initWithProfile:(IADeviceProfile *)profile editing:(BOOL)editing {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _createMode = (profile == nil);
        _editMode = editing;
        _profile = profile ? [profile copy] : [self blankProfile];
        _fields = [NSMutableDictionary dictionary];
    }
    return self;
}

- (IADeviceProfile *)blankProfile {
    IADeviceProfile *p = [IADeviceProfile new];
    p.displayName = @"";
    p.deviceModel = @"";
    p.hardwareIdentifier = @"";
    p.systemVersion = @"";
    p.deviceName = @"iPhone";
    p.localeIdentifier = @"en_US";
    p.languageCode = @"en";
    p.timezoneIdentifier = @"America/New_York";
    p.screenScale = 3.0;
    return p;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.createMode ? @"Create Profile" : (self.editMode ? @"Edit Profile" : self.profile.displayName);
    self.tableView.tableHeaderView = [self buildBanner];
    if (self.editMode) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveTapped)];
    }
}

- (UIView *)buildBanner {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 58)];
    UILabel *tag = [[UILabel alloc] init];
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    tag.text = @"  LOCAL PREVIEW ONLY — không đổi thiết bị thật  ";
    tag.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    tag.textColor = [UIColor whiteColor];
    tag.backgroundColor = [UIColor systemOrangeColor];
    tag.layer.cornerRadius = 6; tag.clipsToBounds = YES;
    [h addSubview:tag];
    [NSLayoutConstraint activateConstraints:@[
        [tag.centerYAnchor constraintEqualToAnchor:h.centerYAnchor],
        [tag.leadingAnchor constraintEqualToAnchor:h.leadingAnchor constant:16],
    ]];
    return h;
}

#pragma mark - Field descriptors (edit mode)

// key, nhãn, keyboardType
- (NSArray<NSArray *> *)editFieldDescriptors {
    return @[
        @[@"displayName",        @"Display name", @(UIKeyboardTypeDefault)],
        @[@"deviceModel",        @"Device model", @(UIKeyboardTypeDefault)],
        @[@"hardwareIdentifier", @"Hardware id",  @(UIKeyboardTypeDefault)],
        @[@"systemVersion",      @"iOS version",  @(UIKeyboardTypeDecimalPad)],
        @[@"deviceName",         @"Device name",  @(UIKeyboardTypeDefault)],
        @[@"localeIdentifier",   @"Locale",       @(UIKeyboardTypeDefault)],
        @[@"languageCode",       @"Language",     @(UIKeyboardTypeDefault)],
        @[@"timezoneIdentifier", @"Timezone",     @(UIKeyboardTypeDefault)],
        @[@"screenWidth",        @"Width",        @(UIKeyboardTypeNumberPad)],
        @[@"screenHeight",       @"Height",       @(UIKeyboardTypeNumberPad)],
        @[@"screenScale",        @"Scale",        @(UIKeyboardTypeDecimalPad)],
    ];
}

- (NSString *)currentValueForKey:(NSString *)key {
    IADeviceProfile *p = self.profile;
    if ([key isEqualToString:@"screenWidth"])  return p.screenWidth  ? [NSString stringWithFormat:@"%ld", (long)p.screenWidth]  : @"";
    if ([key isEqualToString:@"screenHeight"]) return p.screenHeight ? [NSString stringWithFormat:@"%ld", (long)p.screenHeight] : @"";
    if ([key isEqualToString:@"screenScale"])  return p.screenScale  ? [NSString stringWithFormat:@"%g", p.screenScale]        : @"";
    return [p valueForKey:key] ?: @"";
}

// Ghi 1 giá trị field vào self.profile (bản làm việc).
- (void)applyFieldValue:(NSString *)val forKey:(NSString *)key {
    val = val ?: @"";
    if ([key isEqualToString:@"screenWidth"])       self.profile.screenWidth  = val.integerValue;
    else if ([key isEqualToString:@"screenHeight"]) self.profile.screenHeight = val.integerValue;
    else if ([key isEqualToString:@"screenScale"])  self.profile.screenScale  = val.doubleValue;
    else [self.profile setValue:val forKey:key];
}

// Gõ tới đâu ghi tới đó → không phụ thuộc cell còn trên màn hình hay không.
- (void)fieldChanged:(UITextField *)tf {
    for (NSString *key in self.fields)
        if (self.fields[key] == tf) { [self applyFieldValue:tf.text forKey:key]; break; }
}

// Đồng bộ các field đang hiển thị rồi trả self.profile (field ngoài màn hình giữ giá trị ban đầu).
- (IADeviceProfile *)buildProfileFromFields {
    for (NSString *key in self.fields)
        [self applyFieldValue:self.fields[key].text forKey:key];
    if (self.profile.systemName.length == 0) self.profile.systemName = @"iOS";
    return self.profile;
}

#pragma mark - Actions

- (void)validateTapped {
    IADeviceProfile *p = self.editMode ? [self buildProfileFromFields] : self.profile;
    if (self.editMode) self.profile = p; // giữ giá trị người dùng nhập
    self.validation = [[IADeviceProfileManager sharedManager] validate:p];
    [self.tableView reloadData];
}

- (void)applyLocalTapped {
    NSError *err = nil;
    BOOL ok = [[IADeviceProfileManager sharedManager] applyLocalProfile:self.profile error:&err];
    if (ok) {
        [self toast:@"Đã Apply Local (preview)"];
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        self.validation = [[IADeviceProfileManager sharedManager] validate:self.profile];
        [self.tableView reloadData];
        [self alert:err.localizedDescription ?: @"Profile không hợp lệ."];
    }
}

- (void)editTapped {
    IADeviceProfileDetailViewController *vc =
        [[IADeviceProfileDetailViewController alloc] initWithProfile:self.profile editing:YES];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)saveTapped {
    IADeviceProfile *p = [self buildProfileFromFields];
    self.profile = p;
    IADeviceProfileValidationResult *r = [[IADeviceProfileManager sharedManager] validate:p];
    self.validation = r;
    if (!r.isValid) { [self.tableView reloadData]; [self alert:r.errors.firstObject ?: @"Không hợp lệ."]; return; }
    [[IADeviceProfileManager sharedManager] saveCustomProfile:p];
    [self toast:@"Đã lưu custom profile"];
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Table (chia 2 nhánh view/edit)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t {
    if (self.editMode) return self.validation ? 3 : 2;   // fields / [validation] / actions
    return self.validation ? 5 : 4;                       // thiết bị / khu vực / màn hình / [validation] / actions
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    if (self.editMode) {
        if (s == 0) return @"Thuộc tính";
        if (s == 1 && self.validation) return self.validation.isValid ? @"Hợp lệ" : @"Không hợp lệ";
        return nil;
    }
    switch (s) {
        case 0: return @"Thiết bị";
        case 1: return @"Khu vực";
        case 2: return @"Màn hình";
        case 3: return self.validation ? (self.validation.isValid ? @"Hợp lệ" : @"Không hợp lệ") : nil;
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (self.editMode) {
        if (s == 0) return [self editFieldDescriptors].count;
        if (s == 1 && self.validation) return MAX((NSInteger)1, (NSInteger)(self.validation.errors.count + self.validation.warnings.count));
        return 2; // Validate / Save
    }
    switch (s) {
        case 0: return 4;  // model, hwid, iOS, deviceName
        case 1: return 3;  // locale, language, timezone
        case 2: return 2;  // size, scale
        case 3:
            if (self.validation) return MAX((NSInteger)1, (NSInteger)(self.validation.errors.count + self.validation.warnings.count));
            return 3; // actions
        default: return 3; // actions
    }
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (self.editMode) return [self editCellAt:ip];
    return [self viewCellAt:ip];
}

// ---- EDIT MODE ----
- (UITableViewCell *)editCellAt:(NSIndexPath *)ip {
    if (ip.section == 0) {
        NSArray *d = [self editFieldDescriptors][ip.row];
        NSString *key = d[0];
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *lbl = [[UILabel alloc] init];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        lbl.text = d[1];
        lbl.font = [UIFont systemFontOfSize:15];
        lbl.textColor = [UIColor secondaryLabelColor];
        [c.contentView addSubview:lbl];

        UITextField *tf = [[UITextField alloc] init];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.text = [self currentValueForKey:key];
        tf.textAlignment = NSTextAlignmentRight;
        tf.keyboardType = (UIKeyboardType)[d[2] integerValue];
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.placeholder = d[1];
        [tf addTarget:self action:@selector(fieldChanged:) forControlEvents:UIControlEventEditingChanged];
        [c.contentView addSubview:tf];
        self.fields[key] = tf;

        [NSLayoutConstraint activateConstraints:@[
            [lbl.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
            [lbl.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
            [lbl.widthAnchor constraintEqualToConstant:110],
            [tf.leadingAnchor constraintEqualToAnchor:lbl.trailingAnchor constant:8],
            [tf.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
            [tf.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
            [tf.heightAnchor constraintEqualToConstant:34],
        ]];
        return c;
    }
    if (ip.section == 1 && self.validation) return [self validationCellAt:ip.row];
    // actions
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (ip.row == 0) { c.textLabel.text = @"Validate"; c.textLabel.textColor = self.view.tintColor; }
    else            { c.textLabel.text = @"Save custom profile"; c.textLabel.textColor = self.view.tintColor; }
    return c;
}

// ---- VIEW MODE ----
- (UITableViewCell *)viewCellAt:(NSIndexPath *)ip {
    IADeviceProfile *p = self.profile;
    if (ip.section == 3 && self.validation) return [self validationCellAt:ip.row];

    NSInteger actionSection = self.validation ? 4 : 3;
    if (ip.section == actionSection) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        if (ip.row == 0)      { c.textLabel.text = @"Validate"; c.textLabel.textColor = self.view.tintColor; }
        else if (ip.row == 1) { c.textLabel.text = @"Apply Local (preview)"; c.textLabel.textColor = self.view.tintColor; }
        else                  { c.textLabel.text = @"Edit"; c.textLabel.textColor = self.view.tintColor; }
        return c;
    }

    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    NSArray *row = nil;
    if (ip.section == 0) {
        NSArray *rows = @[ @[@"Device model", p.deviceModel ?: @""],
                           @[@"Hardware id", p.hardwareIdentifier ?: @""],
                           @[@"iOS", [NSString stringWithFormat:@"%@ %@", p.systemName ?: @"iOS", p.systemVersion ?: @""]],
                           @[@"Device name", p.deviceName ?: @""] ];
        row = rows[ip.row];
    } else if (ip.section == 1) {
        NSArray *rows = @[ @[@"Locale", p.localeIdentifier ?: @""],
                           @[@"Language", p.languageCode ?: @""],
                           @[@"Timezone", p.timezoneIdentifier ?: @""] ];
        row = rows[ip.row];
    } else {
        NSArray *rows = @[ @[@"Screen size", [NSString stringWithFormat:@"%ld × %ld", (long)p.screenWidth, (long)p.screenHeight]],
                           @[@"Screen scale", [NSString stringWithFormat:@"%.1f", p.screenScale]] ];
        row = rows[ip.row];
    }
    c.textLabel.text = row[0];
    c.detailTextLabel.text = row[1];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return c;
}

- (UITableViewCell *)validationCellAt:(NSInteger)row {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.textLabel.numberOfLines = 0;
    c.textLabel.font = [UIFont systemFontOfSize:12.5];
    NSInteger ec = self.validation.errors.count;
    if (self.validation.errors.count == 0 && self.validation.warnings.count == 0) {
        c.textLabel.text = @"✓ Không có lỗi/cảnh báo.";
        c.textLabel.textColor = [UIColor systemGreenColor];
    } else if (row < ec) {
        c.textLabel.text = [@"✗ " stringByAppendingString:self.validation.errors[row]];
        c.textLabel.textColor = [UIColor systemRedColor];
    } else {
        c.textLabel.text = [@"⚠︎ " stringByAppendingString:self.validation.warnings[row - ec]];
        c.textLabel.textColor = [UIColor systemOrangeColor];
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (self.editMode) {
        NSInteger actions = self.validation ? 2 : 1;
        if (ip.section == actions) { if (ip.row == 0) [self validateTapped]; else [self saveTapped]; }
        return;
    }
    NSInteger actionSection = self.validation ? 4 : 3;
    if (ip.section == actionSection) {
        if (ip.row == 0)      [self validateTapped];
        else if (ip.row == 1) [self applyLocalTapped];
        else                  [self editTapped];
    }
}

#pragma mark - Small UI

- (void)alert:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)toast:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

@end
