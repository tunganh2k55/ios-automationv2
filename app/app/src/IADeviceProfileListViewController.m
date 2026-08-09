//
//  IADeviceProfileListViewController.m
//  iOSAutoApp
//
//  Tab Profiles = DANH SÁCH APP đã cài (icon + tên + bundleId). App đã spoof có dấu
//  tích ✓ xanh. Chọn 1 app → màn cấu hình (Random hoặc tự chọn Model + iOS).
//

#import "IADeviceProfileListViewController.h"
#import "IAAppSpoofConfigViewController.h"

static NSString *const kIAApiBase = @"http://127.0.0.1:8080/api/";

@interface UIImage (IAPrivateIcon3)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bid format:(int)fmt scale:(CGFloat)scale;
@end

@interface IADeviceProfileListViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;    // @[{bundleId,name}]
@property (nonatomic, strong) NSSet<NSString *> *spoofedIds;    // bundleId đã có gán
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation IADeviceProfileListViewController

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = @"Profiles";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Profiles"
            image:[UIImage systemImageNamed:@"square.stack.3d.up"] tag:3];
        _apps = @[];
        _spoofedIds = [NSSet set];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(load) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self load]; }

#pragma mark - Load

- (void)load {
    [self.spinner startAnimating];
    dispatch_group_t g = dispatch_group_create();
    __block NSArray *apps = nil;
    __block NSSet *spoofed = nil;

    dispatch_group_enter(g);
    [self apiGET:@"apps" done:^(id json) {   // chỉ app "User" (cài từ App Store/sideload); Safari thêm ở normalizeApps
        NSArray *a = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
        apps = [a isKindOfClass:NSArray.class] ? a : @[];
        dispatch_group_leave(g);
    }];

    dispatch_group_enter(g);
    [self apiGET:@"profile/list" done:^(id json) {
        NSDictionary *as = [json isKindOfClass:NSDictionary.class] ? json[@"assignments"] : nil;
        // as có thể chứa key nội bộ "_global"/"_targets"; app đã spoof = _targets (fallback: key không '_').
        if ([as isKindOfClass:NSDictionary.class]) {
            NSArray *tg = [as[@"_targets"] isKindOfClass:NSArray.class] ? as[@"_targets"] : nil;
            if (tg) {
                spoofed = [NSSet setWithArray:tg];
            } else {
                NSMutableArray *keys = [NSMutableArray array];
                for (NSString *k in as.allKeys) if (![k hasPrefix:@"_"]) [keys addObject:k];
                spoofed = [NSSet setWithArray:keys];
            }
        } else {
            spoofed = [NSSet set];
        }
        dispatch_group_leave(g);
    }];

    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        [self.spinner stopAnimating];
        [self.refreshControl endRefreshing];
        self.spoofedIds = spoofed ?: [NSSet set];
        self.apps = [self normalizeApps:apps];
        [self.tableView reloadData];
    });
}

// Chuẩn hoá + thêm Safari (system app, thường vắng trong /api/apps) + sort theo tên.
- (NSArray<NSDictionary *> *)normalizeApps:(NSArray *)raw {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id a in raw) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        NSString *bid = a[@"bundleId"]; if (!bid.length || [seen containsObject:bid]) continue;
        [seen addObject:bid];
        NSString *name = [a[@"name"] length] ? a[@"name"] : bid;
        [out addObject:@{@"bundleId": bid, @"name": name}];
    }
    if (![seen containsObject:@"com.apple.mobilesafari"])
        [out addObject:@{@"bundleId": @"com.apple.mobilesafari", @"name": @"Safari"}];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        return [x[@"name"] localizedCaseInsensitiveCompare:y[@"name"]];
    }];
    return out;
}

- (void)apiGET:(NSString *)path done:(void (^)(id json))done {
    NSURL *u = [NSURL URLWithString:[kIAApiBase stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(j); });
    }] resume];
}

- (UIImage *)iconForBundleId:(NSString *)bid {
    @try {
        if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
            UIImage *img = [UIImage _applicationIconImageForBundleIdentifier:bid format:2 scale:UIScreen.mainScreen.scale];
            if (img) return img;
        }
    } @catch (__unused NSException *e) {}
    return [UIImage systemImageNamed:@"app.fill"];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 1; }

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"App đã cài (%lu)", (unsigned long)self.apps.count];
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return @"Chọn 1 app để giả lập định danh thiết bị. Dấu ✓ xanh = đang spoof.";
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.apps.count ?: 1; }

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip { return 58; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"app"];
    if (!self.apps.count) {
        c.textLabel.text = @"Không lấy được danh sách app";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.detailTextLabel.text = @"Kéo xuống để thử lại — daemon đã chạy chưa?";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *app = self.apps[ip.row];
    NSString *bid = app[@"bundleId"];
    c.textLabel.text = app[@"name"];
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    c.detailTextLabel.text = bid;
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];

    c.imageView.image = [self iconForBundleId:bid];
    c.imageView.layer.cornerRadius = 8; c.imageView.clipsToBounds = YES;
    c.imageView.contentMode = UIViewContentModeScaleAspectFit;

    if ([self.spoofedIds containsObject:bid]) {
        UIImageView *tick = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        tick.tintColor = [UIColor systemGreenColor];
        c.accessoryView = tick;
    } else {
        c.accessoryView = nil;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (!self.apps.count) return;
    NSDictionary *app = self.apps[ip.row];
    IAAppSpoofConfigViewController *vc =
        [[IAAppSpoofConfigViewController alloc] initWithBundleId:app[@"bundleId"] name:app[@"name"]];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
