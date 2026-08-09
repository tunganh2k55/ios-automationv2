#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "IADeviceProfileListViewController.h"   // tab Profiles (local preview only)
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <string.h>

// ============================================================================
// iOSAuto — app native trên iPhone. 3 tab: Trang chủ (scripts) · Tạo script · Cài đặt.
// Dữ liệu lấy từ daemon local http://127.0.0.1:8080/api/*.
// ============================================================================

static NSString *const kBase = @"http://127.0.0.1:8080/api/";

static NSString *LocalIP(void) {
    NSString *result = @"127.0.0.1";
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return result;
    for (struct ifaddrs *ifa = ifap; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (!(ifa->ifa_flags & IFF_UP)) continue;
        struct sockaddr_in *sa = (struct sockaddr_in *)ifa->ifa_addr;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &sa->sin_addr, ip, sizeof(ip));
        if (!strcmp(ip, "127.0.0.1")) continue;
        if (strncmp(ifa->ifa_name, "en", 2) == 0) { result = [NSString stringWithUTF8String:ip]; break; }
    }
    freeifaddrs(ifap);
    return result;
}

// ---- API helper ----
@interface Api : NSObject
+ (void)get:(NSString *)path done:(void (^)(id json, NSError *err))done;
+ (void)post:(NSString *)path body:(NSDictionary *)body done:(void (^)(id json, NSError *err))done;
@end
@implementation Api
+ (void)get:(NSString *)path done:(void (^)(id, NSError *))done {
    NSURL *u = [NSURL URLWithString:[kBase stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(j, e); });
    }] resume];
}
+ (void)post:(NSString *)path body:(NSDictionary *)body done:(void (^)(id, NSError *))done {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kBase stringByAppendingString:path]]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 8;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(j, e); });
    }] resume];
}
@end

static UIColor *AccentColor(void) { return [UIColor colorWithRed:0.39 green:0.40 blue:0.95 alpha:1]; }

// ---- Chế độ tối (lưu trong NSUserDefaults) ----
// nil = CHƯA đặt (lần đầu mở app → theo máy) · @YES = tối · @NO = sáng
static NSString *const kDarkKey = @"iosauto.darkOn";

static NSNumber *SavedDark(void) {
    return [[NSUserDefaults standardUserDefaults] objectForKey:kDarkKey];
}
// Style áp cho app: lần đầu (chưa đặt) = unspecified → theo máy khách.
static UIUserInterfaceStyle CurrentAppStyle(void) {
    NSNumber *v = SavedDark();
    if (!v) return UIUserInterfaceStyleUnspecified;
    return v.boolValue ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
}
// Áp giao diện cho toàn bộ cửa sổ của CHÍNH app (sandbox — không đổi cả máy).
static void ApplyAppStyle(void) {
    UIUserInterfaceStyle s = CurrentAppStyle();
    // iOS 15: dùng UIWindowScene.windows (UIApplication.windows đã deprecated).
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            w.overrideUserInterfaceStyle = s;
    }
}

// ============================================================================
// Chi tiết 1 script: xem/sửa · Chạy · Lưu · Xoá
// ============================================================================
@interface ScriptDetailVC : UIViewController
@property (strong) NSString *name;
@property (strong) UITextView *editor;
@property (strong) UITextView *output;
@end
@implementation ScriptDetailVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.name;
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Xoá" style:UIBarButtonItemStylePlain target:self action:@selector(del)],
        [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStylePlain target:self action:@selector(save)],
    ];

    self.editor = [[UITextView alloc] init];
    self.editor.translatesAutoresizingMaskIntoConstraints = NO;
    self.editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.editor.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.editor.layer.cornerRadius = 10;
    self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.view addSubview:self.editor];

    UIButton *run = [UIButton buttonWithType:UIButtonTypeSystem];
    run.translatesAutoresizingMaskIntoConstraints = NO;
    [run setTitle:@"▶ Chạy" forState:UIControlStateNormal];
    [run setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    run.backgroundColor = AccentColor();
    run.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    run.layer.cornerRadius = 10;
    [run addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:run];

    self.output = [[UITextView alloc] init];
    self.output.translatesAutoresizingMaskIntoConstraints = NO;
    self.output.editable = NO;
    self.output.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.output.textColor = [UIColor colorWithRed:0.65 green:0.95 blue:0.8 alpha:1];
    self.output.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.output.layer.cornerRadius = 10;
    self.output.text = @"— log chạy —";
    [self.view addSubview:self.output];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.editor.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [self.editor.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.editor.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.editor.heightAnchor constraintEqualToAnchor:g.heightAnchor multiplier:0.45],
        [run.topAnchor constraintEqualToAnchor:self.editor.bottomAnchor constant:10],
        [run.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [run.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [run.heightAnchor constraintEqualToConstant:44],
        [self.output.topAnchor constraintEqualToAnchor:run.bottomAnchor constant:10],
        [self.output.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.output.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.output.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
    ]];
    [self load];
}
- (void)load {
    [Api post:@"script_read" body:@{@"name": self.name ?: @""} done:^(id j, NSError *e) {
        if ([j[@"ok"] boolValue]) self.editor.text = j[@"content"] ?: @"";
        else self.editor.text = @"-- không đọc được file";
    }];
}
- (void)run {
    self.output.text = @"▶ đang chạy…";
    [Api post:@"script" body:@{@"code": self.editor.text ?: @""} done:^(id j, NSError *e) {
        self.output.text = j[@"output"] ?: (e ? @"(lỗi kết nối)" : @"(xong)");
    }];
}
- (void)save {
    [Api post:@"script_save" body:@{@"name": self.name ?: @"", @"content": self.editor.text ?: @""} done:^(id j, NSError *e) {
        [self toast:[j[@"ok"] boolValue] ? @"Đã lưu" : @"Lưu lỗi"];
    }];
}
- (void)del {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Xoá script?" message:self.name preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [Api post:@"script_delete" body:@{@"name": self.name ?: @""} done:^(id j, NSError *e) {
            [self.navigationController popViewControllerAnimated:YES];
        }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)toast:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}
@end

// ============================================================================
// TAB 1 — Trang chủ: logo + tên app + danh sách script trên máy
//   Mỗi dòng có nút ▶ Chạy; khi script đó đang chạy → nút thành ⏹ Dừng và các
//   dòng khác bị khoá (daemon chỉ chạy 1 script/lần). Tên script đang chạy được
//   lưu vào NSUserDefaults để khi mở lại app vẫn biết dòng nào đang chạy.
// ============================================================================
static NSString *const kRunningKey = @"iosauto.runningScript";

@interface HomeVC : UITableViewController
@property (strong) NSArray *files;
@property (assign) BOOL busy;            // daemon đang chạy 1 script nào đó?
@property (strong) NSString *runningName; // tên script đang chạy (nếu do app này khởi chạy)
@property (strong) NSTimer *poll;        // theo dõi trạng thái chạy khi đang xem tab
@end
@implementation HomeVC
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Trang chủ";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Trang chủ"
            image:[UIImage systemImageNamed:@"house.fill"] tag:0];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.files = @[];
    self.runningName = [[NSUserDefaults standardUserDefaults] stringForKey:kRunningKey];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(load) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = [self buildHeader];
}
- (void)viewWillAppear:(BOOL)a {
    [super viewWillAppear:a];
    [self load];
    [self refreshRunState];
    [self startPolling];
}
- (void)viewWillDisappear:(BOOL)a { [super viewWillDisappear:a]; [self stopPolling]; }
- (UIView *)buildHeader {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
    UIImageView *logo = [[UIImageView alloc] init];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *p = [[NSBundle mainBundle] pathForResource:@"AppLogo" ofType:@"png"];
    logo.image = p ? [UIImage imageWithContentsOfFile:p] : nil;
    logo.layer.cornerRadius = 18; logo.clipsToBounds = YES;
    logo.contentMode = UIViewContentModeScaleAspectFill;
    [h addSubview:logo];

    UILabel *name = [[UILabel alloc] init];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = @"iOSAuto";
    name.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    [h addSubview:name];

    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"Tự động hoá iPhone";
    sub.font = [UIFont systemFontOfSize:14];
    sub.textColor = [UIColor secondaryLabelColor];
    [h addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [logo.centerXAnchor constraintEqualToAnchor:h.centerXAnchor],
        [logo.topAnchor constraintEqualToAnchor:h.topAnchor constant:16],
        [logo.widthAnchor constraintEqualToConstant:72],
        [logo.heightAnchor constraintEqualToConstant:72],
        [name.centerXAnchor constraintEqualToAnchor:h.centerXAnchor],
        [name.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:8],
        [sub.centerXAnchor constraintEqualToAnchor:h.centerXAnchor],
        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
    ]];
    return h;
}
- (void)load {
    [Api get:@"scripts" done:^(id j, NSError *e) {
        [self.refreshControl endRefreshing];
        NSArray *fs = [j isKindOfClass:[NSDictionary class]] ? j[@"files"] : nil;
        self.files = [fs isKindOfClass:[NSArray class]] ? fs : @[];
        [self.tableView reloadData];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"Script trên máy (%lu)", (unsigned long)self.files.count];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return self.files.count ?: 1;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    if (!self.files.count) {
        c.textLabel.text = @"Chưa có script";
        c.textLabel.textColor = [UIColor secondaryLabelColor];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSDictionary *f = self.files[ip.row];
    NSString *name = f[@"name"];
    BOOL running = self.busy && [name isEqualToString:self.runningName];
    c.textLabel.text = name;
    c.textLabel.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    long sz = [f[@"size"] longValue];
    c.detailTextLabel.text = running ? @"● đang chạy…" : [NSString stringWithFormat:@"%ld byte", sz];
    c.detailTextLabel.textColor = running ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    c.imageView.image = [UIImage systemImageNamed:@"doc.text"];

    // Nút Chạy/Dừng cho từng dòng (accessoryView). Đang bận mà không phải dòng này → khoá.
    UIButton *rb = [UIButton buttonWithType:UIButtonTypeSystem];
    rb.tag = ip.row;
    [rb setTitle:(running ? @"⏹ Dừng" : @"▶ Chạy") forState:UIControlStateNormal];
    [rb setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    rb.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    rb.backgroundColor = running ? [UIColor systemRedColor] : AccentColor();
    rb.layer.cornerRadius = 8;
    BOOL enabled = !self.busy || running;   // bận vì script khác → khoá nút
    rb.enabled = enabled;
    rb.alpha = enabled ? 1.0 : 0.4;
    [rb addTarget:self action:@selector(runTapped:) forControlEvents:UIControlEventTouchUpInside];
    [rb sizeToFit];   // tự thêm đệm quanh chữ (contentEdgeInsets đã deprecated ở iOS 15)
    rb.frame = CGRectMake(0, 0, rb.frame.size.width + 24, 34);
    c.accessoryView = rb;
    return c;
}
// Bấm nút ▶/⏹ trên 1 dòng: chạy script đó, hoặc dừng nếu nó đang chạy.
- (void)runTapped:(UIButton *)b {
    if (b.tag >= (NSInteger)self.files.count) return;
    NSString *name = self.files[b.tag][@"name"];
    if (self.busy) {
        if ([name isEqualToString:self.runningName]) [self stopRun];
        else [self alert:@"Đang chạy một script khác — dừng nó trước đã."];
        return;
    }
    // Đọc nội dung file rồi gửi chạy nền (daemon nhận code, không nhận tên).
    [Api post:@"script_read" body:@{@"name": name} done:^(id j, NSError *e) {
        if (![j[@"ok"] boolValue]) { [self alert:@"Không đọc được script."]; return; }
        NSString *code = j[@"content"] ?: @"";
        [Api post:@"script" body:@{@"code": code} done:^(id r, NSError *e2) {
            if ([r[@"ok"] boolValue]) {
                self.busy = YES;
                self.runningName = name;
                [[NSUserDefaults standardUserDefaults] setObject:name forKey:kRunningKey];
                [self.tableView reloadData];
                [self startPolling];
            } else {
                [self alert:r[@"msg"] ?: @"Không chạy được (có thể đang bận)."];
                [self refreshRunState];
            }
        }];
    }];
}
- (void)stopRun {
    [Api post:@"run/stop" body:@{} done:^(id j, NSError *e) { [self refreshRunState]; }];
}
// Hỏi daemon còn đang chạy không; cập nhật busy + dọn tên khi đã xong.
- (void)refreshRunState {
    [Api get:@"run" done:^(id j, NSError *e) {
        BOOL wasBusy = self.busy;
        self.busy = [j isKindOfClass:NSDictionary.class] && [j[@"busy"] boolValue];
        if (!self.busy) {
            if (self.runningName) [[NSUserDefaults standardUserDefaults] removeObjectForKey:kRunningKey];
            self.runningName = nil;
            [self stopPolling];
        }
        if (wasBusy != self.busy || self.busy) [self.tableView reloadData];
    }];
}
- (void)startPolling {
    if (self.poll) return;
    self.poll = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self
        selector:@selector(refreshRunState) userInfo:nil repeats:YES];
}
- (void)stopPolling { [self.poll invalidate]; self.poll = nil; }
- (void)alert:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (!self.files.count) return;
    ScriptDetailVC *d = [ScriptDetailVC new];
    d.name = self.files[ip.row][@"name"];
    [self.navigationController pushViewController:d animated:YES];
}
@end

// ============================================================================
// TAB 2 — Tạo script mới (icon cmd/terminal)
// ============================================================================
@interface NewScriptVC : UIViewController
@property (strong) UITextField *nameField;
@property (strong) UITextView *editor;
@end
@implementation NewScriptVC
- (instancetype)init {
    self = [super init];
    if (self) {
        self.title = @"Tạo script";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Tạo script"
            image:[UIImage systemImageNamed:@"terminal.fill"] tag:1];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self action:@selector(save)];

    self.nameField = [[UITextField alloc] init];
    self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameField.placeholder = @"tên_file.lua";
    self.nameField.borderStyle = UITextBorderStyleRoundedRect;
    self.nameField.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    self.nameField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.nameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.view addSubview:self.nameField];

    self.editor = [[UITextView alloc] init];
    self.editor.translatesAutoresizingMaskIntoConstraints = NO;
    self.editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.editor.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.editor.layer.cornerRadius = 10;
    self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.editor.text = @"-- Hàm: tap(x,y) swipe(x1,y1,x2,y2) input(\"..\")\n-- launch(\"bundle\") kill(\"bundle\") home() wake()\n-- sleep(giây) log(\"..\") print(..)\n\n";
    [self.view addSubview:self.editor];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.nameField.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
        [self.nameField.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.nameField.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.editor.topAnchor constraintEqualToAnchor:self.nameField.bottomAnchor constant:10],
        [self.editor.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.editor.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
        [self.editor.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
    ]];
}
- (void)save {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (name.length == 0) { [self alert:@"Nhập tên file trước (vd auto.lua)"]; return; }
    if (![name containsString:@"."]) name = [name stringByAppendingString:@".lua"];
    [Api post:@"script_save" body:@{@"name": name, @"content": self.editor.text ?: @""} done:^(id j, NSError *e) {
        if ([j[@"ok"] boolValue]) {
            [self alert:[@"Đã lưu " stringByAppendingString:name]];
            self.nameField.text = @"";
        } else [self alert:[@"Lưu lỗi: " stringByAppendingString:(j[@"msg"] ?: @"?")]];
    }];
}
- (void)alert:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}
@end

// ============================================================================
// QUÉT QR — camera bắt mã QR license (AVFoundation). Trả chuỗi qua block onCode.
// ============================================================================
@interface QRScannerVC : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (copy) void (^onCode)(NSString *code);
@property (strong) AVCaptureSession *session;
@property (strong) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic) BOOL done;
@end
@implementation QRScannerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = @"Quét QR license";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    [self setupCamera];
}
- (void)setupCamera {
    self.session = [[AVCaptureSession alloc] init];
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *err = nil;
    AVCaptureDeviceInput *in = dev ? [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err] : nil;
    if (!in) { [self failMsg:@"Không mở được camera"]; return; }
    if ([self.session canAddInput:in]) [self.session addInput:in];
    AVCaptureMetadataOutput *out = [[AVCaptureMetadataOutput alloc] init];
    if ([self.session canAddOutput:out]) [self.session addOutput:out];
    [out setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    if ([out.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode])
        out.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];

    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preview.frame = self.view.layer.bounds;
    [self.view.layer addSublayer:self.preview];

    // Khung ngắm + hướng dẫn.
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(20, 90, self.view.bounds.size.width - 40, 40)];
    hint.text = @"Đưa mã QR license vào khung";
    hint.textColor = [UIColor whiteColor];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [self.view addSubview:hint];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [self.session startRunning]; });
}
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; self.preview.frame = self.view.layer.bounds; }
- (void)failMsg:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self cancel]; }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray *)objs fromConnection:(AVCaptureConnection *)c {
    if (self.done || objs.count == 0) return;
    AVMetadataMachineReadableCodeObject *o = objs.firstObject;
    NSString *val = [o isKindOfClass:AVMetadataMachineReadableCodeObject.class] ? o.stringValue : nil;
    if (!val.length) return;
    self.done = YES;
    [self.session stopRunning];
    void (^cb)(NSString *) = self.onCode;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(val); }];
}
@end

// Tách license key từ nội dung QR: QR web là text nhiều dòng có dòng "Key: XXXX";
// nếu không có, dùng nguyên chuỗi (trường hợp QR chỉ chứa key).
static NSString *IAExtractKey(NSString *scanned) {
    if (!scanned.length) return @"";
    for (NSString *line in [scanned componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange r = [t rangeOfString:@"Key:" options:NSCaseInsensitiveSearch];
        if (r.location == 0)
            return [[t substringFromIndex:r.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return [scanned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Tính "hạn dùng" từ chuỗi ISO expiresAt của license.
//   null/không parse được kiểu ngày → "Vĩnh viễn" (license không hết hạn).
//   còn hạn → "Còn N ngày (dd/MM/yyyy)"; hết hạn trong hôm nay → "Hết hạn hôm nay"; quá hạn → "Đã hết hạn".
// Đếm theo NGÀY LỊCH (không theo giờ): qua mỗi nửa đêm giảm 1 ngày — nên kích hoạt chiều 27/7
// thì 28/7 hiện "Còn 6 ngày", không còn lệ thuộc giờ kích hoạt như cách ceil() theo 24h trước đây.
static NSString *IADaysLeft(id iso) {
    if (![iso isKindOfClass:NSString.class] || [(NSString *)iso length] == 0) return @"Vĩnh viễn";
    NSISO8601DateFormatter *f = [[NSISO8601DateFormatter alloc] init];
    NSDate *d = [f dateFromString:iso];
    if (!d) {
        f.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        d = [f dateFromString:iso];
    }
    if (!d) return iso;   // không parse được → hiện nguyên chuỗi
    if ([d timeIntervalSinceNow] <= 0) return @"Đã hết hạn";
    // Luôn tính theo GIỜ VIỆT NAM (UTC+7) bất kể timezone thiết bị (máy có thể đang ở
    // US/Pacific…). VN không có DST nên dùng offset cố định +7h.
    NSTimeZone *vn = [NSTimeZone timeZoneForSecondsFromGMT:7 * 3600];
    NSCalendar *cal = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    cal.timeZone = vn;
    NSDate *today0 = [cal startOfDayForDate:[NSDate date]];
    NSDate *exp0 = [cal startOfDayForDate:d];
    long days = [cal components:NSCalendarUnitDay fromDate:today0 toDate:exp0 options:0].day;
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"dd/MM/yyyy"; df.timeZone = vn;
    NSString *date = [df stringFromDate:d];
    if (days <= 0) return [NSString stringWithFormat:@"Hết hạn hôm nay (%@)", date];   // còn hiệu lực tới cuối hôm nay
    return [NSString stringWithFormat:@"Còn %ld ngày (%@)", days, date];
}

// ============================================================================
// KÍCH HOẠT BẢN QUYỀN — nhập license hoặc quét QR; gọi daemon /api/license/activate.
// ============================================================================
@interface ActivationVC : UIViewController
@property (strong) UILabel *statusLabel;
@property (strong) UILabel *machineLabel;
@property (strong) UITextField *keyField;
@property (strong) UIButton *activateBtn;
@property (strong) NSString *machineId;
@end
@implementation ActivationVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Bản quyền";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.statusLabel = [self label:16 weight:UIFontWeightSemibold];
    self.statusLabel.numberOfLines = 0;

    UILabel *midCap = [self label:12 weight:UIFontWeightRegular];
    midCap.text = @"Machine ID (serial) — đăng ký giá trị này trên web:";
    midCap.textColor = [UIColor secondaryLabelColor];
    self.machineLabel = [self label:14 weight:UIFontWeightMedium];
    self.machineLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    self.machineLabel.numberOfLines = 0;
    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [copyBtn setTitle:@"Sao chép Machine ID" forState:UIControlStateNormal];
    [copyBtn addTarget:self action:@selector(copyMid) forControlEvents:UIControlEventTouchUpInside];

    self.keyField = [[UITextField alloc] init];
    self.keyField.placeholder = @"Nhập license key (VD IOSA-XXXX-XXXX-XXXX)";
    self.keyField.borderStyle = UITextBorderStyleRoundedRect;
    self.keyField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.keyField.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    self.keyField.clearButtonMode = UITextFieldViewModeWhileEditing;

    self.activateBtn = [self filledButton:@"Kích hoạt" color:AccentColor() action:@selector(activate)];
    UIButton *scanBtn = [self filledButton:@"⧉ Quét QR" color:[UIColor systemGrayColor] action:@selector(scan)];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.statusLabel, [self spacer:6], midCap, self.machineLabel, copyBtn,
        [self spacer:10], self.keyField, self.activateBtn, scanBtn ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
    ]];
}
- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)w {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:size weight:w];
    return l;
}
- (UIView *)spacer:(CGFloat)h {
    UIView *v = [[UIView alloc] init];
    [v.heightAnchor constraintEqualToConstant:h].active = YES;
    return v;
}
- (UIButton *)filledButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = color;
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 10;
    [b.heightAnchor constraintEqualToConstant:46].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self loadStatus]; }
- (void)loadStatus {
    [Api get:@"license" done:^(id j, NSError *e) {
        NSDictionary *d = [j isKindOfClass:NSDictionary.class] ? j : nil;
        BOOL act = [d[@"activated"] boolValue];
        self.machineId = d[@"machineId"] ?: @"—";
        self.machineLabel.text = self.machineId;
        NSString *plan = [d[@"app"][@"plan"] isKindOfClass:NSString.class] ? d[@"app"][@"plan"] : nil;
        if (act) {
            NSString *base = plan ? [NSString stringWithFormat:@"✓ Đã kích hoạt · gói %@", plan] : @"✓ Đã kích hoạt";
            self.statusLabel.text = [NSString stringWithFormat:@"%@\nHạn dùng: %@", base, IADaysLeft(d[@"app"][@"expiresAt"])];
            self.statusLabel.textColor = [UIColor systemGreenColor];
        } else {
            self.statusLabel.text = @"✗ Chưa kích hoạt — nhập key hoặc quét QR để kích hoạt.";
            self.statusLabel.textColor = [UIColor systemRedColor];
        }
    }];
}
- (void)copyMid {
    if (self.machineId.length) { [UIPasteboard generalPasteboard].string = self.machineId; [self toast:@"Đã copy Machine ID"]; }
}
- (void)activate { [self doActivateWithKey:self.keyField.text]; }
- (void)doActivateWithKey:(NSString *)key {
    NSString *k = [(key ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (k.length < 4) { [self toast:@"Nhập license key trước"]; return; }
    self.keyField.text = k;
    self.activateBtn.enabled = NO;
    [self.activateBtn setTitle:@"Đang kích hoạt…" forState:UIControlStateNormal];
    [Api post:@"license/activate" body:@{@"key": k} done:^(id j, NSError *e) {
        self.activateBtn.enabled = YES;
        [self.activateBtn setTitle:@"Kích hoạt" forState:UIControlStateNormal];
        BOOL ok = [j[@"ok"] boolValue];
        NSString *msg = j[@"msg"] ?: (e ? @"Lỗi kết nối daemon" : @"?");
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:(ok ? @"Thành công" : @"Chưa kích hoạt được") message:msg preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [self loadStatus];
            if (ok && self.navigationController) [self.navigationController popViewControllerAnimated:YES];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    }];
}
- (void)scan {
    AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (st == AVAuthorizationStatusAuthorized) { [self presentScanner]; return; }
    if (st == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (granted) [self presentScanner]; else [self toast:@"Cần quyền camera để quét QR"]; });
        }];
        return;
    }
    [self toast:@"Cần cấp quyền camera trong Cài đặt để quét QR"];
}
- (void)presentScanner {
    QRScannerVC *sc = [[QRScannerVC alloc] init];
    __weak typeof(self) ws = self;
    sc.onCode = ^(NSString *code) {
        NSString *key = IAExtractKey(code);
        ws.keyField.text = key;
        [ws doActivateWithKey:key];
    };
    UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:sc];
    nc.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nc animated:YES completion:nil];
}
- (void)toast:(NSString *)m {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:m preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}
@end

// ============================================================================
// TAB 3 — Cài đặt: bản quyền, giao diện, thông tin máy
// ============================================================================
@interface SettingsVC : UITableViewController
@property (strong) NSArray *rows;        // info @[title,value]
@property (strong) NSDictionary *statusDict;
@property (strong) NSDictionary *lic;    // trạng thái license
@end
@implementation SettingsVC
- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"Cài đặt";
        self.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Cài đặt"
            image:[UIImage systemImageNamed:@"gearshape.fill"] tag:2];
    }
    return self;
}
- (void)viewDidLoad { [super viewDidLoad]; self.rows = @[]; [self build]; }
- (void)viewWillAppear:(BOOL)a { [super viewWillAppear:a]; [self load]; [self loadLicense]; }
- (void)load {
    [Api get:@"status" done:^(id j, NSError *e) {
        self.statusDict = [j isKindOfClass:[NSDictionary class]] ? j : nil; [self build];
    }];
}
- (void)loadLicense {
    [Api get:@"license" done:^(id j, NSError *e) {
        self.lic = [j isKindOfClass:[NSDictionary class]] ? j : nil; [self build];
    }];
}
- (void)build {
    NSDictionary *s = self.statusDict;
    NSDictionary *dev = s[@"device"];
    NSString *name = dev[@"name"] ?: @"iPhone";
    NSString *model = dev[@"model"] ?: @"—";
    NSString *ios = dev[@"ios"] ?: @"—";
    NSString *serial = [dev[@"serial"] isKindOfClass:NSString.class] && [dev[@"serial"] length]
                       ? dev[@"serial"] : @"— (không lấy được)";
    NSString *ip = s[@"ip"] ?: LocalIP();
    NSNumber *port = s[@"port"] ?: @8080;
    NSNumber *usbPort = [s[@"usbPort"] isKindOfClass:NSNumber.class] ? s[@"usbPort"] : nil;
    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
    NSString *mid = [self.lic[@"machineId"] isKindOfClass:NSString.class] && [self.lic[@"machineId"] length]
                    ? self.lic[@"machineId"] : @"— (đang lấy)";

    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[
        @[@"Thiết bị", name],
        @[@"Model", model],
        @[@"iOS", ios],
        @[@"Serial (SN)", serial],
        @[@"IP", [NSString stringWithFormat:@"%@:%@", ip, port]],
    ]];
    // USB Port: chỉ hiện khi cổng USB đang bật (daemon bind 127.0.0.1:usbPort qua usbmuxd).
    // Cắm cáp vào PC + chạy iproxy → truy cập http://localhost:<usbPort> mà không cần cùng LAN.
    if (usbPort.intValue > 0)
        [rows addObject:@[@"USB Port", [NSString stringWithFormat:@"localhost:%@", usbPort]]];
    [rows addObjectsFromArray:@[
        @[@"Phiên bản app", ver],
        @[@"Machine ID", mid],
    ]];
    self.rows = rows;
    [self.tableView reloadData];
}
// Chuỗi trạng thái license để hiển thị.
- (NSString *)licenseStatusText {
    if (![self.lic isKindOfClass:NSDictionary.class]) return @"Đang kiểm tra…";
    if ([self.lic[@"activated"] boolValue]) {
        NSString *plan = [self.lic[@"app"][@"plan"] isKindOfClass:NSString.class] ? self.lic[@"app"][@"plan"] : nil;
        return plan ? [NSString stringWithFormat:@"Đã kích hoạt · gói %@", plan] : @"Đã kích hoạt";
    }
    return @"Chưa kích hoạt";
}
- (BOOL)licenseActivated { return [self.lic[@"activated"] boolValue]; }
// Các dòng thông tin bản quyền (Trạng thái + Hạn dùng khi đã kích hoạt). Nút Kích hoạt là dòng CUỐI.
- (NSArray *)licRows {
    NSMutableArray *r = [NSMutableArray arrayWithObject:@[@"Trạng thái", [self licenseStatusText]]];
    if ([self licenseActivated])
        [r addObject:@[@"Hạn dùng", IADaysLeft(self.lic[@"app"][@"expiresAt"])]];
    return r;
}

// Section 0 = Bản quyền · 1 = Giao diện · 2 = Thông tin
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return [self licRows].count + 1;   // (trạng thái [+ hạn dùng]) + nút kích hoạt
    if (s == 1) return 1;      // chế độ tối
    return self.rows.count;    // thông tin
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"Bản quyền" : s == 1 ? @"Giao diện" : @"Thông tin";
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return [self licenseActivated] ? nil
        : @"Thiết bị chưa kích hoạt — app, web UI và script đều bị khoá. Bấm \"Kích hoạt bản quyền\" để nhập key hoặc quét QR.";
    if (s == 1) return nil;
    return @"Điều khiển đầy đủ (xem màn, tap, swipe): mở IP ở trên bằng trình duyệt trên máy tính cùng mạng LAN.";
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    // --- Section 0: Bản quyền ---
    if (ip.section == 0) {
        NSArray *lr = [self licRows];
        if (ip.row < (NSInteger)lr.count) {   // dòng thông tin (Trạng thái / Hạn dùng)
            NSArray *row = lr[ip.row];
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"licst"];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            c.textLabel.text = row[0];
            c.detailTextLabel.text = row[1];
            c.detailTextLabel.textColor = [row[0] isEqualToString:@"Trạng thái"]
                ? ([self licenseActivated] ? [UIColor systemGreenColor] : [UIColor systemRedColor])
                : [UIColor secondaryLabelColor];
            return c;
        }
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"licact"];
        c.textLabel.text = [self licenseActivated] ? @"Quản lý bản quyền" : @"Kích hoạt bản quyền";
        c.textLabel.textColor = AccentColor();
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    // --- Section 1: 1 dòng "Chế độ tối" + UISwitch ---
    if (ip.section == 1) {
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"sw"];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.text = @"Chế độ tối";
        UISwitch *sw = [[UISwitch alloc] init];
        NSNumber *v = SavedDark();
        sw.on = v ? v.boolValue : (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
        [sw addTarget:self action:@selector(darkToggled:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }
    // --- Section 2: các dòng thông tin ---
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"c"];
    NSArray *row = self.rows[ip.row];
    c.textLabel.text = row[0];
    c.detailTextLabel.text = row[1];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if ([row[0] isEqualToString:@"IP"] || [row[0] isEqualToString:@"USB Port"]) {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.detailTextLabel.textColor = AccentColor();
    }
    if ([row[0] isEqualToString:@"Machine ID"] || [row[0] isEqualToString:@"Serial (SN)"]) {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;   // chạm để copy
    }
    if ([row[0] isEqualToString:@"Thiết bị"]) {
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}
- (void)darkToggled:(UISwitch *)sw {
    BOOL on = sw.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kDarkKey];
    ApplyAppStyle();   // đổi giao diện app này ngay (chắc chắn)
    // Best-effort: nhờ daemon+tweak đổi Dark Mode TOÀN MÁY (2=tối, 1=sáng).
    [Api post:@"appearance" body:@{@"mode": @(on ? 2 : 1)} done:^(id j, NSError *e) { /* im lặng nếu không có daemon */ }];
}
- (void)editDeviceName:(NSString *)current {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Đổi tên thiết bị"
        message:@"Tên hiển thị trong app và tiêu đề web UI." preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = current; tf.placeholder = @"vd: SE2";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) ws = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *n = [ac.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [Api post:@"device" body:@{@"name": n ?: @""} done:^(id j, NSError *e) { [ws load]; }];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    // Bản quyền: dòng cuối = nút Kích hoạt/Quản lý → mở màn kích hoạt.
    if (ip.section == 0) {
        if (ip.row == (NSInteger)[self licRows].count)
            [self.navigationController pushViewController:[ActivationVC new] animated:YES];
        return;
    }
    if (ip.section != 2) return;
    NSArray *row = self.rows[ip.row];
    if ([row[0] isEqualToString:@"Thiết bị"]) { [self editDeviceName:row[1]]; return; }
    if ([row[0] isEqualToString:@"IP"] || [row[0] isEqualToString:@"Machine ID"]
        || [row[0] isEqualToString:@"USB Port"] || [row[0] isEqualToString:@"Serial (SN)"]) {
        [UIPasteboard generalPasteboard].string = row[1];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil
            message:[@"Đã copy " stringByAppendingString:row[0]] preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:ac animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    }
}
@end

// ============================================================================
// AppDelegate — UITabBarController 3 tab
// ============================================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UITabBarController *tab;
@end
@implementation AppDelegate
- (UINavigationController *)wrap:(UIViewController *)vc {
    UINavigationController *nc = [[UINavigationController alloc] initWithRootViewController:vc];
    nc.navigationBar.prefersLargeTitles = YES;
    return nc;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    self.tab = [[UITabBarController alloc] init];
    self.tab.viewControllers = @[
        [self wrap:[HomeVC new]],
        [self wrap:[NewScriptVC new]],
        [self wrap:[SettingsVC new]],
        [self wrap:[IADeviceProfileListViewController new]],  // tab 4: Device Profiles (local preview only)
    ];
    self.tab.tabBar.tintColor = AccentColor();

    self.window.rootViewController = self.tab;
    self.window.tintColor = AccentColor();
    self.window.overrideUserInterfaceStyle = CurrentAppStyle(); // lần đầu = theo máy; sau đó theo lựa chọn đã lưu
    [self.window makeKeyAndVisible];
    [self gateOnLicense];   // chưa kích hoạt → nhảy vào tab Cài đặt
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application { [self gateOnLicense]; }
// Hỏi daemon: chưa kích hoạt → chuyển sang tab Cài đặt (index 2) để người dùng thấy cần active.
- (void)gateOnLicense {
    [Api get:@"license" done:^(id j, NSError *e) {
        BOOL activated = [j isKindOfClass:NSDictionary.class] && [j[@"activated"] boolValue];
        if (!activated && self.tab.selectedIndex != 2) self.tab.selectedIndex = 2;
    }];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
