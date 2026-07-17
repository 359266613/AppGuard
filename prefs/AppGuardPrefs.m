#import "AppGuardPrefs.h"
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#include <dlfcn.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ==========================================
// 用于打破副标题限制的扩展 Cell 控制器
// ==========================================
#import <Preferences/PSTableCell.h>

@interface MCAppProcessCell : PSTableCell
@end

@implementation MCAppProcessCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.detailTextLabel.numberOfLines = 2; // 允许2行数据折叠展示
        self.detailTextLabel.textColor = [UIColor systemGrayColor];
        self.detailTextLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
        self.textLabel.font = [UIFont systemFontOfSize:17];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    NSString *subText = [specifier propertyForKey:@"mc_subtitle"];
    if (subText) {
        self.detailTextLabel.text = subText;
    }
    [self setNeedsLayout];
}
@end


// ==========================================
// 实时刷新日志的独立 ViewController
// ==========================================
@interface MCLogViewController : UIViewController
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSString *logPath;
@property (nonatomic, assign) NSUInteger lastLogLength;
@end

@implementation MCLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"运行日志";
    self.view.backgroundColor = [UIColor blackColor];
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"🥵" style:UIBarButtonItemStylePlain target:self action:@selector(showAutoClearOptions)];
    
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.textView.textColor = [UIColor whiteColor];
    self.textView.backgroundColor = [UIColor blackColor];
    self.textView.layoutManager.allowsNonContiguousLayout = NO;
    
    [self.view addSubview:self.textView];
}

- (BOOL)canBeShownFromSuspendedState { return YES; }

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLog];
    if (!self.refreshTimer) {
        self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refreshLog) userInfo:nil repeats:YES];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)showAutoClearOptions {
    NSString *prefPath = @"/var/mobile/Library/Preferences/com.axs.appguard.plist";
#if !__has_include(<roothide.h>)
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        prefPath = [@"/var/jb" stringByAppendingPathComponent:prefPath];
    }
#else
    prefPath = jbroot(prefPath);
#endif
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath] ?: @{};
    NSNumber *limitNum = prefs[@"LogSizeLimit"];
    long long currentLimit = limitNum ? [limitNum longLongValue] : 2 * 1024 * 1024;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"自动清理日志" message:@"选择当日志达到多大时自动清空？" preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *options = @[
        @{@"title": @"1 MB", @"val": @(1 * 1024 * 1024)},
        @{@"title": @"2 MB(默认)", @"val": @(2 * 1024 * 1024)},
        @{@"title": @"5 MB", @"val": @(5 * 1024 * 1024)},
        @{@"title": @"10 MB", @"val": @(10 * 1024 * 1024)},
        @{@"title": @"从不", @"val": @(0)}
    ];
    
    for (NSDictionary *opt in options) {
        NSString *title = opt[@"title"];
        long long val = [opt[@"val"] longLongValue];
        if (currentLimit == val) {
            title = [title stringByAppendingString:@" ✓"];
        }
        
        UIAlertAction *act = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSMutableDictionary *mutPrefs = [prefs mutableCopy];
            mutPrefs[@"LogSizeLimit"] = opt[@"val"];
            [mutPrefs writeToFile:prefPath atomically:YES];
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
        }];
        [alert addAction:act];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSAttributedString *)attributedStringForLog:(NSString *)logContent {
    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] initWithString:logContent attributes:@{
        NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    }];
    
    NSArray *lines = [logContent componentsSeparatedByString:@"\n"];
    NSUInteger currentLocation = 0;
    
    for (NSString *line in lines) {
        NSRange lineRange = NSMakeRange(currentLocation, line.length);
        if ([line containsString:@"[守护]"]) {
            [attrStr addAttribute:NSForegroundColorAttributeName value:[UIColor systemPinkColor] range:lineRange];
        } else if ([line containsString:@"[配置]"]) {
            [attrStr addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1.0] range:lineRange];
        }
        currentLocation += line.length + 1;
    }
    return attrStr;
}

- (void)refreshLog {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:self.logPath];
        NSString *logContent = @"暂无日志或守护进程未启动。";
        
        if (fileHandle) {
            unsigned long long fileSize = [fileHandle seekToEndOfFile];
            unsigned long long offset = 0;
            if (fileSize > 50000) { 
                offset = fileSize - 50000;
                [fileHandle seekToFileOffset:offset];
                NSData *tailData = [fileHandle readDataToEndOfFile];
                
                const char *bytes = (const char *)tailData.bytes;
                NSUInteger nlIndex = 0;
                for (NSUInteger i = 0; i < tailData.length; i++) {
                    if (bytes[i] == '\n') {
                        nlIndex = i + 1; 
                        break;
                    }
                }
                NSData *safeData = (nlIndex > 0 && nlIndex < tailData.length) ? [tailData subdataWithRange:NSMakeRange(nlIndex, tailData.length - nlIndex)] : tailData;
                logContent = [[NSString alloc] initWithData:safeData encoding:NSUTF8StringEncoding];
                if (!logContent) {
                    logContent = [[NSString alloc] initWithData:safeData encoding:NSASCIIStringEncoding];
                }
            } else {
                [fileHandle seekToFileOffset:0];
                NSData *data = [fileHandle readDataToEndOfFile];
                logContent = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            [fileHandle closeFile];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (logContent.length != self.lastLogLength) {
                self.textView.attributedText = [self attributedStringForLog:logContent];
                self.lastLogLength = logContent.length;
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (self.textView.text.length > 0) {
                        NSRange bottom = NSMakeRange(self.textView.text.length - 1, 1);
                        [self.textView scrollRangeToVisible:bottom];
                    }
                });
            }
        });
    });
}
@end


// ==========================================
// 动态获取系统安装 App 的列表控制器（支持搜索和图标）
// ==========================================
@interface MCAppListViewController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) void (^selectCallback)(NSString *bundleID);
@property (nonatomic, strong) NSMutableArray *appData;
@property (nonatomic, strong) NSArray *filteredAppData;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation MCAppListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择应用";
    self.appData = [NSMutableArray array];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索名称或包名";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
    Class LSApplicationWorkspace_class = NSClassFromString(@"LSApplicationWorkspace");
    if (LSApplicationWorkspace_class) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id workspace = [LSApplicationWorkspace_class performSelector:NSSelectorFromString(@"defaultWorkspace")];
        NSArray *apps = [workspace performSelector:NSSelectorFromString(@"allInstalledApplications")];
        for (id app in apps) {
            NSString *bundleID = [app performSelector:NSSelectorFromString(@"applicationIdentifier")];
            NSString *name = [app performSelector:NSSelectorFromString(@"localizedName")];
            if (bundleID && name) {
                [self.appData addObject:@{@"id": bundleID, @"name": name}];
            }
        }
#pragma clang diagnostic pop
        [self.appData sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
            return [obj1[@"name"] localizedStandardCompare:obj2[@"name"]];
        }];
    }
    self.filteredAppData = self.appData;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *searchText = searchController.searchBar.text.lowercaseString;
    if (searchText.length == 0) {
        self.filteredAppData = self.appData;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            NSString *appName = (NSString *)app[@"name"];
            NSString *appId = (NSString *)app[@"id"];
            return [appName.lowercaseString containsString:searchText] || [appId.lowercaseString containsString:searchText];
        }];
        self.filteredAppData = [self.appData filteredArrayUsingPredicate:pred];
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredAppData.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
    }
    NSDictionary *app = self.filteredAppData[indexPath.row];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = app[@"id"];
    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    
    cell.imageView.image = nil;
    if ([UIImage respondsToSelector:NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:")]) {
        UIImage *(*getIcon)(id, SEL, NSString *, int, CGFloat) = (UIImage *(*)(id, SEL, NSString *, int, CGFloat))[UIImage methodForSelector:NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:")];
        UIImage *icon = getIcon([UIImage class], NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:"), app[@"id"], 0, [UIScreen mainScreen].scale);
        if (icon) {
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(29, 29), NO, [UIScreen mainScreen].scale);
            [icon drawInRect:CGRectMake(0,0,29,29)];
            UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            cell.imageView.image = resized;
            cell.imageView.layer.cornerRadius = 6.0;
            cell.imageView.layer.masksToBounds = YES;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *app = self.filteredAppData[indexPath.row];
    if (self.selectCallback) {
        self.selectCallback(app[@"id"]);
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end


// ==========================================
// 进程参数编辑 - 原生圆角TableView弹窗控制器
// ==========================================
@interface MCProcessEditViewController : UITableViewController
@property (nonatomic, copy) NSString *procName;
@property (nonatomic, copy) NSDictionary *config;
@property (nonatomic, copy) void (^saveCallback)(NSString *name, NSDictionary *config);
@property (nonatomic, copy) void (^deleteCallback)(NSString *name);

@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, strong) UITextField *activeField;
@property (nonatomic, strong) UITextField *inactiveField;
@property (nonatomic, strong) UITextField *jetsamField;
@property (nonatomic, strong) UITextField *niceField;
@property (nonatomic, strong) UITextField *intervalField; // 检测周期
@property (nonatomic, strong) UITextField *remarkField;   // 备注
@property (nonatomic, strong) UISwitch *stripManagedSwitch; // 剥离系统托管开关
@end

@implementation MCProcessEditViewController

- (instancetype)init {
    UITableViewStyle style = UITableViewStyleGrouped;
    if (@available(iOS 13.0, *)) { style = 2; /* UITableViewStyleInsetGrouped */ }
    if (self = [super initWithStyle:style]) { }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.procName ? @"编辑进程" : @"添加新进程";
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"取消" style:UIBarButtonItemStylePlain target:self action:@selector(cancelAction)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(saveAction)];

    self.nameField = [self createTextField:@"目标进程名 / 包名" value:self.procName kbd:UIKeyboardTypeDefault];
    self.nameField.enabled = YES; 

    UIButton *selectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [selectBtn setTitle:@" 选择 " forState:UIControlStateNormal];
    [selectBtn addTarget:self action:@selector(selectAppAction) forControlEvents:UIControlEventTouchUpInside];
    self.nameField.rightView = selectBtn;
    self.nameField.rightViewMode = UITextFieldViewModeAlways;
    
    self.activeField = [self createTextField:@"活跃内存限制 (MB)" value:[self.config[@"MemLimitActive"] stringValue] kbd:UIKeyboardTypeNumbersAndPunctuation];
    self.inactiveField = [self createTextField:@"后台内存限制 (MB)" value:[self.config[@"MemLimitInactive"] stringValue] kbd:UIKeyboardTypeNumbersAndPunctuation];
    self.jetsamField = [self createTextField:@"内存优先级 (Jetsam)" value:[self.config[@"JetsamPriority"] stringValue] kbd:UIKeyboardTypeNumbersAndPunctuation];
    self.niceField = [self createTextField:@"进程优先级 (Nice)" value:[self.config[@"NiceValue"] stringValue] kbd:UIKeyboardTypeNumbersAndPunctuation];
    
    self.intervalField = [self createTextField:@"检测周期 (默认1800秒)" value:[self.config[@"CheckInterval"] stringValue] kbd:UIKeyboardTypeNumberPad];
    self.remarkField = [self createTextField:@"备注 (主页显示名称)" value:self.config[@"Remark"] kbd:UIKeyboardTypeDefault];

    self.stripManagedSwitch = [[UISwitch alloc] init];
    if (self.config[@"StripManaged"]) {
        self.stripManagedSwitch.on = [self.config[@"StripManaged"] boolValue];
    } else {
        self.stripManagedSwitch.on = NO;
    }

    [self.nameField addTarget:self action:@selector(checkIfSystemApp) forControlEvents:UIControlEventEditingChanged];
    [self.activeField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.inactiveField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.jetsamField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.niceField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.intervalField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.remarkField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];

    [self checkIfSystemApp]; // Initial Check

    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tapGesture.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tapGesture];
}

// 核心修复2：检查是否系统进程，非用户态APP直接置灰（加入 TrollStore 安装的应用强判定放行机制）
- (void)checkIfSystemApp {
    NSString *bundleID = self.nameField.text;
    BOOL isUser = YES;
    
    if (bundleID.length > 0) {
        if ([bundleID.lowercaseString isEqualToString:@"springboard"] ||
            [bundleID.lowercaseString isEqualToString:@"com.apple.springboard"] ||
            ![bundleID containsString:@"."]) {
            isUser = NO;
        }
        
        Class LSAppProxy_class = NSClassFromString(@"LSApplicationProxy");
        if (LSAppProxy_class) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id proxy = [LSAppProxy_class performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:") withObject:bundleID];
            if (proxy) {
                NSString *appType = [proxy performSelector:NSSelectorFromString(@"applicationType")];
                if ([appType isEqualToString:@"System"]) {
                    isUser = NO;
                }
                
                // 加入 TrollStore 绝对路径判定
                if ([proxy respondsToSelector:NSSelectorFromString(@"bundleURL")]) {
                    NSURL *bundleURL = [proxy performSelector:NSSelectorFromString(@"bundleURL")];
                    NSString *pathStr = bundleURL.path;
                    
                    // 获取 .app 所在的上级目录，精准匹配同级 _TrollStore 标识文件
                    NSString *parentDir = [pathStr stringByDeletingLastPathComponent];
                    NSString *tsMarkerPath = [parentDir stringByAppendingPathComponent:@"_TrollStore"];
                    
                    if ([[NSFileManager defaultManager] fileExistsAtPath:tsMarkerPath]) {
                        isUser = YES;
                    } else if ([pathStr rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        isUser = YES;
                    }
                }
                if ([proxy respondsToSelector:NSSelectorFromString(@"dataContainerURL")]) {
                    NSURL *dataURL = [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
                    NSString *dataStr = dataURL.path;
                    if ([dataStr rangeOfString:@"TrollStore" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        isUser = YES;
                    }
                }
            }
#pragma clang diagnostic pop
        }
    }
    
    self.stripManagedSwitch.enabled = isUser;
    if (!isUser) {
        self.stripManagedSwitch.on = NO;
    }
}

- (void)textFieldDidChange:(UITextField *)textField {
    textField.rightViewMode = (textField.text.length > 0) ? UITextFieldViewModeUnlessEditing : UITextFieldViewModeNever;
}

- (void)selectAppAction {
    MCAppListViewController *appVC = [[MCAppListViewController alloc] init];
    appVC.selectCallback = ^(NSString *bundleID) {
        self.nameField.text = bundleID;
        [self checkIfSystemApp]; // 自动更新开关状态
    };
    [self.navigationController pushViewController:appVC animated:YES];
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self.view endEditing:YES];
}

- (UITextField *)createTextField:(NSString *)placeholder value:(NSString *)val kbd:(UIKeyboardType)kt {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = placeholder;
    f.text = val;
    f.keyboardType = kt;
    f.borderStyle = UITextBorderStyleNone; 
    f.backgroundColor = [UIColor clearColor];
    f.font = [UIFont systemFontOfSize:17];
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    
    UILabel *rightLabel = [[UILabel alloc] init];
    rightLabel.text = placeholder;
    rightLabel.font = [UIFont systemFontOfSize:12];
    rightLabel.textColor = [UIColor systemGray2Color];
    [rightLabel sizeToFit];
    
    UIView *rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, rightLabel.bounds.size.width + 10, rightLabel.bounds.size.height)];
    rightLabel.frame = CGRectMake(10, 0, rightLabel.bounds.size.width, rightLabel.bounds.size.height);
    [rightView addSubview:rightLabel];
    
    f.rightView = rightView;
    f.rightViewMode = (val.length > 0) ? UITextFieldViewModeUnlessEditing : UITextFieldViewModeNever;
    
    return f;
}

- (void)cancelAction {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveAction {
    NSString *name = self.nameField.text;
    if (name.length == 0) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    NSMutableDictionary *newConfig = [NSMutableDictionary dictionary];
    if (self.activeField.text.length > 0) newConfig[@"MemLimitActive"] = @([self.activeField.text intValue]);
    if (self.inactiveField.text.length > 0) newConfig[@"MemLimitInactive"] = @([self.inactiveField.text intValue]);
    if (self.jetsamField.text.length > 0) newConfig[@"JetsamPriority"] = @([self.jetsamField.text intValue]);
    if (self.niceField.text.length > 0) newConfig[@"NiceValue"] = @([self.niceField.text intValue]);
    if (self.intervalField.text.length > 0) newConfig[@"CheckInterval"] = @([self.intervalField.text intValue]);
    if (self.remarkField.text.length > 0) newConfig[@"Remark"] = self.remarkField.text;
    
    // 写入开关状态
    newConfig[@"StripManaged"] = @(self.stripManagedSwitch.isOn);

    if (self.saveCallback) self.saveCallback(name, newConfig);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)deleteAction {
    if (self.deleteCallback) self.deleteCallback(self.procName);
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString *)tipsText {
    return @"目标说明:\n通过包名或进程名识别进程\n\n剥离系统托管:\n尝试剥离 P_MEMSTAT_MANAGED 内核标记，防止配置被系统恢复，并同时开启 ELEVATED_INACTIVE 非活跃提升保护。\n\n检测周期与备注:\n检测周期默认为30分钟检测处理一次\n备注用于主页显示名称\n\n内存限制:\n0 让插件不要设置\n-1 表示不受限制 \n\n进程优先级范围:\n-20 最高优先 到 19 最低优先, 默认为空不设置\n\n内存优先级(Jetsam)说明:\n-1 让插件不要设置优先级\n0 重新让系统接管\n10 空闲延迟 IDLE_DEFERRED\n20 后台机遇性 BACKGROUND_OPPORTUNISTIC\n30 后台 BACKGROUND\n40 邮件提升的非活跃 ELEVATED_INACTIVE\n50 电话相关 PHONE\n80 UI支持 UI_SUPPORT\n90 前台支持 FOREGROUND_SUPPORT\n100 前台 FOREGROUND\n120 音频配件 AUDIO_AND_ACCESSORY\n130 管理协调进程 CONDUCTOR\n150 Apple驱动 DRIVER_APPLE\n160 主屏主界面相关 HOME\n170 系统执行级 EXECUTIVE\n180 重要 DEFAULT\n190 关键电话 TELEPHONY\n210 最大优先级 MAX";
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.procName ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) {
        return 8; // 新增了开关所以改为 8
    }
    return 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 50.0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"进程配置";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0 && !self.procName) return [self tipsText];
    if (section == 1 && self.procName) return [self tipsText];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
    if (indexPath.section == 1) {
        cell.textLabel.text = @"删除此进程记录";
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:17];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    
    UITextField *tf = nil;
    if (indexPath.row == 0) tf = self.nameField;
    else if (indexPath.row == 1) tf = self.activeField;
    else if (indexPath.row == 2) tf = self.inactiveField;
    else if (indexPath.row == 3) tf = self.jetsamField;
    else if (indexPath.row == 4) tf = self.niceField;
    else if (indexPath.row == 5) tf = self.intervalField;
    else if (indexPath.row == 6) tf = self.remarkField;
    else if (indexPath.row == 7) {
        // 绑定剥离系统托管行
        cell.textLabel.text = @"剥离系统托管并强锁";
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.accessoryView = self.stripManagedSwitch;
        return cell;
    }
    
    if (tf) {
        [cell.contentView addSubview:tf];
        CGFloat padding = 20.0;
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:padding],
            [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-padding],
            [tf.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [tf.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor]
        ]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [self deleteAction];
    }
}

// ================= AppData 完美复刻样式：Header、Footer 自动布局与圆角处理 =================
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (!title) return nil;
    UIView *headerView = [[UIView alloc] init];
    headerView.backgroundColor = [UIColor clearColor];
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; 
    titleLabel.textColor = [UIColor systemGrayColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:titleLabel];
    
    CGFloat padding = 15.0;
    if (@available(iOS 13.0, *)) { padding = 20.0; }
    
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:padding],
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-padding],
        [titleLabel.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor constant:-6]
    ]];
    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title && title.length > 0) {
        return 38.0;
    }
    return section == 0 ? CGFLOAT_MIN : 15.0; 
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSString *footerText = [self tableView:tableView titleForFooterInSection:section];
    if (!footerText) return nil;
    UIView *footerView = [[UIView alloc] init];
    footerView.backgroundColor = [UIColor clearColor];
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.text = footerText;
    footerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; 
    footerLabel.textColor = [UIColor systemGrayColor];
    footerLabel.numberOfLines = 0;
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [footerView addSubview:footerLabel];
    
    CGFloat padding = 15.0;
    if (@available(iOS 13.0, *)) { padding = 20.0; }
    
    [NSLayoutConstraint activateConstraints:@[
        [footerLabel.leadingAnchor constraintEqualToAnchor:footerView.leadingAnchor constant:padding],
        [footerLabel.trailingAnchor constraintEqualToAnchor:footerView.trailingAnchor constant:-padding],
        [footerLabel.topAnchor constraintEqualToAnchor:footerView.topAnchor constant:6],
        [footerLabel.bottomAnchor constraintEqualToAnchor:footerView.bottomAnchor constant:-6]
    ]];
    return footerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *footerText = [self tableView:tableView titleForFooterInSection:section];
    if (!footerText || footerText.length == 0) return CGFLOAT_MIN; 
    
    CGFloat padding = 30.0;
    if (@available(iOS 13.0, *)) { padding = 40.0; }
    CGFloat width = tableView.bounds.size.width - padding;
    CGRect rect = [footerText boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]} context:nil];
    return ceil(rect.size.height) + 12.0; 
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger numberOfRows = [tableView numberOfRowsInSection:indexPath.section];
    BOOL isFirst = (indexPath.row == 0);
    BOOL isLast = (indexPath.row == numberOfRows - 1);
    CGFloat radius = 25.0;
    CACornerMask mask = 0;
    if (isFirst && isLast) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else if (isFirst) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    } else if (isLast) {
        mask = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else {
        radius = 0; mask = 0;
    }
    cell.layer.borderWidth = 0.0;
    cell.layer.borderColor = [UIColor clearColor].CGColor;
    cell.layer.cornerRadius = radius;
    cell.layer.maskedCorners = mask;
    cell.layer.masksToBounds = YES;
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = cell.backgroundConfiguration;
        if (bg) {
            bg.cornerRadius = radius; 
            bg.strokeColor = [UIColor clearColor]; 
            bg.strokeWidth = 0.0;
            cell.backgroundConfiguration = bg;
        }
    } else {
        if (cell.backgroundView) {
            cell.backgroundView.layer.cornerRadius = radius;
            cell.backgroundView.layer.maskedCorners = mask;
            cell.backgroundView.layer.masksToBounds = YES;
            cell.backgroundView.layer.borderWidth = 0.0;
        }
    }
    if (@available(iOS 13.0, *)) { cell.layer.cornerCurve = kCACornerCurveContinuous; }
}

@end


// ==========================================
// 设置面板主控制器 (完全集成 AppData 视觉)
// ==========================================
@interface AppGuardPrefsListController () <UIDocumentPickerDelegate, UISearchResultsUpdating, UISearchControllerDelegate>
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSString *searchText;
@end

@implementation AppGuardPrefsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 添加导航栏右侧搜索按钮
    UIBarButtonItem *searchBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSearch target:self action:@selector(showSearchBar)];
    self.navigationItem.rightBarButtonItem = searchBtn;
    
    // 初始化搜索控制器
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.delegate = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.hidesNavigationBarDuringPresentation = YES;
    self.searchController.searchBar.placeholder = @"搜索进程或备注";
    self.definesPresentationContext = YES;
}

- (void)showSearchBar {
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    [self.searchController setActive:YES];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.searchController.searchBar becomeFirstResponder];
    });
}

// ================= 搜索相关代理方法与动画 =================
- (void)willDismissSearchController:(UISearchController *)searchController {
    self.searchText = @"";
    // 优雅的淡入淡出动画恢复完整列表
    [UIView transitionWithView:self.view
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
                        [self reloadSpecifiers];
                    } completion:nil];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.navigationItem.searchController = nil;
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *newText = searchController.searchBar.text.lowercaseString ?: @"";
    if (![self.searchText isEqualToString:newText]) {
        self.searchText = newText;
        // 优雅的淡入淡出动画刷新过滤列表
        [UIView transitionWithView:self.view
                          duration:0.2
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [self reloadSpecifiers];
                        } completion:nil];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self checkAndGenerateDefaultConfig];
    
    [self refreshStatus]; // Initial fetch
    if (!self.statusTimer) {
        self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
}

// 核心修复3：直接接管点击事件实现弹窗，废弃会被吃掉的按钮机制
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
        spec = [self performSelector:@selector(specifierAtIndexPath:) withObject:indexPath];
    }
    
    if (spec && [[spec propertyForKey:@"key"] isEqualToString:@"SortBy"]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self sortProcessListFallback];
        return;
    }
    
    // 双重拦截兜底判断，完全防止点击没反应
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell && ([cell.textLabel.text containsString:@"排序"] || [cell.detailTextLabel.text containsString:@"排序"])) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        [self sortProcessListFallback];
        return;
    }
    
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

// ================= 排序菜单响应逻辑 =================
- (void)sortProcessListFallback {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    NSInteger sortType = [dict[@"SortBy"] integerValue];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"进程排序" message:@"进程列表排序方式" preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSString *title0 = (sortType == 0) ? @"默认排序🥵" : @"默认排序";
    NSString *title1 = (sortType == 1) ? @"进程优先级高到低 🥵" : @"进程优先级高到低";
    NSString *title2 = (sortType == 2) ? @"内存优先级高到低 🥵" : @"内存优先级高到低";
    
    [alert addAction:[UIAlertAction actionWithTitle:title0 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self saveSortPreference:@(0)];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:title1 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self saveSortPreference:@(1)];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:title2 style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self saveSortPreference:@(2)];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 0, 0);
        alert.popoverPresentationController.permittedArrowDirections = 0;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)saveSortPreference:(NSNumber *)sortType {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath] ?: [NSMutableDictionary dictionary];
    dict[@"SortBy"] = sortType;
    [dict writeToFile:prefPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
    [self reloadSpecifiers];
}
// ==========================================================

// ================= 自动生成及强制恢复配置核心逻辑 =================
- (void)performRestoreDefaultConfig {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSDictionary *defaultConfig = @{
        @"Enabled": @YES,
        @"AppConfigs": @{
            @"SpringBoard": @{@"CheckInterval": @0, @"JetsamPriority": @210, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @-19, @"Remark": @"视图"},
            @"backboardd": @{@"CheckInterval": @0, @"JetsamPriority": @210, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @-20, @"Remark": @"触控"},
            @"com.tencent.xin": @{@"CheckInterval": @0, @"JetsamPriority": @160, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @0, @"Remark": @"微信.xin"},
            @"dasd": @{@"CheckInterval": @0, @"JetsamPriority": @-1, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @1, @"Remark": @"后台刷新"},
            @"kbd": @{@"CheckInterval": @0, @"JetsamPriority": @-1, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @-18, @"Remark": @"键盘"},
            @"runningboardd": @{@"CheckInterval": @0, @"JetsamPriority": @-1, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @-17, @"Remark": @"任务调度"},
            @"sharingd": @{@"CheckInterval": @0, @"JetsamPriority": @-1, @"MemLimitActive": @0, @"MemLimitInactive": @0, @"NiceValue": @-16, @"Remark": @"分享"}
        }
    };
    [defaultConfig writeToFile:prefPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
    notify_post("com.axs.appguard/ApplyLimits");
    [self reloadSpecifiers];
}

- (void)restoreDefaultConfigAction {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"配置" message:@"恢复到默认配置？会覆盖现有配置" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self performRestoreDefaultConfig];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)checkAndGenerateDefaultConfig {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:prefPath]) {
        [self performRestoreDefaultConfig];
    }
}
// ==========================================================

- (void)refreshStatus {
    NSString *statusPath = [self getSafePathForFile:@"com.axs.appguard.status.plist"];
    NSDictionary *statusDict = [NSDictionary dictionaryWithContentsOfFile:statusPath];
    
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    NSDictionary *appConfigs = dict[@"AppConfigs"] ?: @{};

    for (PSSpecifier *spec in self.specifiers) {
        NSString *procName = [spec propertyForKey:@"processName"];
        if (procName) {
            NSDictionary *config = appConfigs[procName];
            if (!config) continue;
            NSDictionary *status = statusDict[procName];
            
            NSString *line1 = @"进程未运行";
            if (status) {
                NSString *pActual = [status[@"p"] intValue] == -999 ? @"未知" : [status[@"p"] stringValue];
                line1 = [NSString stringWithFormat:@"p=%@、n=%@、pid=%@", pActual, status[@"n"], status[@"pid"]];
            }
            
            NSString *p = config[@"JetsamPriority"] && [config[@"JetsamPriority"] description].length > 0 ? [config[@"JetsamPriority"] stringValue] : @"空";
            NSString *a = config[@"MemLimitActive"] && [config[@"MemLimitActive"] description].length > 0 ? [config[@"MemLimitActive"] stringValue] : @"空";
            NSString *i = config[@"MemLimitInactive"] && [config[@"MemLimitInactive"] description].length > 0 ? [config[@"MemLimitInactive"] stringValue] : @"空";
            NSString *n = config[@"NiceValue"] && [config[@"NiceValue"] description].length > 0 ? [config[@"NiceValue"] stringValue] : @"空";
            NSString *s = config[@"CheckInterval"] && [config[@"CheckInterval"] description].length > 0 ? [config[@"CheckInterval"] stringValue] : @"0";
            NSString *line2 = [NSString stringWithFormat:@"p=%@、a=%@、i=%@、n=%@、s=%@", p, a, i, n, s];
            
            NSString *newSubtitle = [NSString stringWithFormat:@"%@\n%@", line1, line2];
            NSString *oldSubtitle = [spec propertyForKey:@"mc_subtitle"];
            
            if (![newSubtitle isEqualToString:oldSubtitle]) {
                [spec setProperty:newSubtitle forKey:@"mc_subtitle"];
                PSTableCell *cell = [self cachedCellForSpecifier:spec];
                if (cell && [cell isKindOfClass:[MCAppProcessCell class]]) {
                    [(MCAppProcessCell *)cell refreshCellContentsWithSpecifier:spec];
                } else {
                    [self reloadSpecifier:spec];
                }
            }
        }
    }
}

- (UITableViewStyle)tableViewStyle {
    if (@available(iOS 13.0, *)) {
        return 2; // UITableViewStyleInsetGrouped
    }
    return UITableViewStyleGrouped;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
        spec = [self performSelector:@selector(specifierAtIndexPath:) withObject:indexPath];
    }
    
    // 拦截排序配置框并重绘UI，使其像原生菜单单元格
    if (spec && [[spec propertyForKey:@"key"] isEqualToString:@"SortBy"]) {
        PSTableCell *cell = (PSTableCell *)[super tableView:tableView cellForRowAtIndexPath:indexPath];
        
        NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
        NSInteger sortType = [dict[@"SortBy"] integerValue];
        
        NSString *currentTitle = (sortType == 1) ? @"进程优先级高到低" : ((sortType == 2) ? @"内存优先级高到低" : @"默认排序");
        
        cell.detailTextLabel.text = currentTitle;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    
    // --- 精准拦截并把恢复配置按钮文本标红 ---
    if (spec && [[spec propertyForKey:@"isRestoreButton"] boolValue]) {
        PSTableCell *cell = (PSTableCell *)[super tableView:tableView cellForRowAtIndexPath:indexPath];
        cell.textLabel.textColor = [UIColor systemRedColor];
    }
    
    return [super tableView:tableView cellForRowAtIndexPath:indexPath];
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        BOOL isSearching = (self.searchText.length > 0);
        NSMutableArray *specs = [NSMutableArray array];
        
        NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
        NSDictionary *appConfigs = dict[@"AppConfigs"] ?: @{};
        
        NSString *statusPath = [self getSafePathForFile:@"com.axs.appguard.status.plist"];
        NSDictionary *statusDict = [NSDictionary dictionaryWithContentsOfFile:statusPath];
        
        NSUInteger insertIdx = NSNotFound;
        
        if (!isSearching) {
            specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
            
            for (NSUInteger i = 0; i < specs.count; i++) {
                PSSpecifier *s = specs[i];
                
                // 确保排序可以点击触发
                if ([[s propertyForKey:@"key"] isEqualToString:@"SortBy"]) {
                    s->action = @selector(sortProcessListFallback);
                }
                
                if ([[s propertyForKey:@"action"] isEqualToString:@"addNewProcess"]) {
                    insertIdx = i + 1; // 插入到添加按钮的下方
                }
            }
            
            if (insertIdx != NSNotFound) {
                PSSpecifier *importSpec = [PSSpecifier preferenceSpecifierNamed:@"导入配置"
                                                                          target:self
                                                                             set:NULL
                                                                             get:nil
                                                                          detail:Nil
                                                                            cell:PSButtonCell
                                                                            edit:Nil];
                importSpec->action = @selector(importConfig);
                [specs insertObject:importSpec atIndex:insertIdx];
                insertIdx++;
                
                PSSpecifier *exportSpec = [PSSpecifier preferenceSpecifierNamed:@"导出配置"
                                                                         target:self
                                                                            set:NULL
                                                                            get:nil
                                                                         detail:Nil
                                                                           cell:PSButtonCell
                                                                           edit:Nil];
                exportSpec->action = @selector(exportConfig);
                [specs insertObject:exportSpec atIndex:insertIdx];
                insertIdx++;
                
                // --- 恢复配置按钮 ---
                PSSpecifier *restoreSpec = [PSSpecifier preferenceSpecifierNamed:@"恢复配置"
                                                                          target:self
                                                                             set:NULL
                                                                             get:nil
                                                                          detail:Nil
                                                                            cell:PSButtonCell
                                                                            edit:Nil];
                restoreSpec->action = @selector(restoreDefaultConfigAction);
                [restoreSpec setProperty:@YES forKey:@"isRestoreButton"]; // 打上标记用于变红
                [specs insertObject:restoreSpec atIndex:insertIdx];
                insertIdx++;
            }
        } else {
            // 搜索模式下，用独立组直接将过滤后的进程置于顶部
            PSSpecifier *searchGroup = [PSSpecifier emptyGroupSpecifier];
            [searchGroup setProperty:@"搜索结果" forKey:@"title"];
            [specs addObject:searchGroup];
        }
        
        // --- 基于用户选择应用动态排序 ---
        NSInteger sortType = [dict[@"SortBy"] integerValue];
        
        NSArray *sortedProcNames = [appConfigs.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *key1, NSString *key2) {
            NSDictionary *config1 = appConfigs[key1];
            NSDictionary *config2 = appConfigs[key2];
            
            if (sortType == 1) { // 按 进程优先级(Nice) 从高到低 (数值越小优先级越高)
                int n1 = config1[@"NiceValue"] ? [config1[@"NiceValue"] intValue] : 20;
                int n2 = config2[@"NiceValue"] ? [config2[@"NiceValue"] intValue] : 20;
                if (n1 != n2) {
                    return n1 < n2 ? NSOrderedAscending : NSOrderedDescending;
                }
            } else if (sortType == 2) { // 按 内存优先级(Jetsam) 从高到低 (数值越大优先级越高)
                int j1 = config1[@"JetsamPriority"] ? [config1[@"JetsamPriority"] intValue] : -1;
                int j2 = config2[@"JetsamPriority"] ? [config2[@"JetsamPriority"] intValue] : -1;
                int j1_sort = (j1 == -1) ? -999 : j1;
                int j2_sort = (j2 == -1) ? -999 : j2;
                if (j1_sort != j2_sort) {
                    return j1_sort > j2_sort ? NSOrderedAscending : NSOrderedDescending;
                }
            } else { // 默认排序
                int j1 = config1[@"JetsamPriority"] ? [config1[@"JetsamPriority"] intValue] : -1;
                int j2 = config2[@"JetsamPriority"] ? [config2[@"JetsamPriority"] intValue] : -1;
                int j1_sort = (j1 == -1) ? -999 : j1;
                int j2_sort = (j2 == -1) ? -999 : j2;
                
                if (j1_sort != j2_sort) {
                    return j1_sort > j2_sort ? NSOrderedAscending : NSOrderedDescending;
                }
                
                int n1 = config1[@"NiceValue"] ? [config1[@"NiceValue"] intValue] : 20;
                int n2 = config2[@"NiceValue"] ? [config2[@"NiceValue"] intValue] : 20;
                
                if (n1 != n2) {
                    return n1 < n2 ? NSOrderedAscending : NSOrderedDescending;
                }
            }
            
            return [key1 localizedCaseInsensitiveCompare:key2];
        }];
        
        for (NSString *procName in sortedProcNames) {
            NSDictionary *config = appConfigs[procName];
            NSString *remark = config[@"Remark"];
            
            // --- 搜索状态下的精准过滤 ---
            if (isSearching) {
                BOOL matchName = [procName.lowercaseString containsString:self.searchText];
                BOOL matchRemark = remark && [remark.lowercaseString containsString:self.searchText];
                if (!matchName && !matchRemark) {
                    continue; // 未匹配直接过滤跳过
                }
            }
            
            NSString *cellTitle = (remark && remark.length > 0) ? [NSString stringWithFormat:@"%@ (%@)", remark, procName] : procName;
            
            PSSpecifier *appSpec = [PSSpecifier preferenceSpecifierNamed:cellTitle
                                                                  target:self
                                                                     set:NULL
                                                                     get:nil
                                                                  detail:Nil
                                                                    cell:PSLinkCell
                                                                    edit:Nil];
            appSpec->action = @selector(editProcess:);
            [appSpec setProperty:procName forKey:@"processName"];
            [appSpec setProperty:@YES forKey:@"enabled"];
            
            // 加载图标
            UIImage *appIcon = nil;
            if ([UIImage respondsToSelector:NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:")]) {
                UIImage *(*getIcon)(id, SEL, NSString *, int, CGFloat) = (UIImage *(*)(id, SEL, NSString *, int, CGFloat))[UIImage methodForSelector:NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:")];
                appIcon = getIcon([UIImage class], NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:"), procName, 0, [UIScreen mainScreen].scale);
            }
            
            if (!appIcon) {
                // 1. 组合原生标准路径
                NSString *bundleBase = @"/Library/PreferenceBundles/AppGuardPrefs.bundle";
                NSString *realBundlePath = bundleBase;
                
                // 2. 根据越狱环境精准转换物理路径
#if !__has_include(<roothide.h>)
                if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
                    realBundlePath = [@"/var/jb" stringByAppendingPathComponent:bundleBase];
                }
#else
                realBundlePath = jbroot(bundleBase);
#endif
                
                // 3. 用绝对物理路径强行初始化 Bundle，不仅不会迷路，还能让系统自动识别 icon@2x.png 和 icon@3x.png
                NSBundle *realBundle = [NSBundle bundleWithPath:realBundlePath];
                if (realBundle) {
                    appIcon = [UIImage imageNamed:@"icon" inBundle:realBundle compatibleWithTraitCollection:nil];
                }
                
                // 4. 终极保底：如果 NSBundle 依然傲娇，直接暴力读取真实文件
                if (!appIcon) {
                    NSString *iconFullPath = [realBundlePath stringByAppendingPathComponent:@"icon.png"];
                    appIcon = [UIImage imageWithContentsOfFile:iconFullPath];
                }
            }
            
            if (appIcon) {
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(29, 29), NO, [UIScreen mainScreen].scale);
                [appIcon drawInRect:CGRectMake(0,0,29,29)];
                UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                [appSpec setProperty:resized forKey:@"iconImage"];
            }
            
            // 将 Cell 替换为拓展子标题的 MCAppProcessCell
            [appSpec setProperty:[MCAppProcessCell class] forKey:@"cellClass"];
            
            // 初始化防止加载时的首秒空闪
            NSDictionary *status = statusDict[procName];
            NSString *line1 = @"进程未运行";
            if (status) {
                NSString *pActual = [status[@"p"] intValue] == -999 ? @"未知" : [status[@"p"] stringValue];
                line1 = [NSString stringWithFormat:@"p=%@、n=%@、pid=%@", pActual, status[@"n"], status[@"pid"]];
            }
            NSString *p = config[@"JetsamPriority"] && [config[@"JetsamPriority"] description].length > 0 ? [config[@"JetsamPriority"] stringValue] : @"空";
            NSString *a = config[@"MemLimitActive"] && [config[@"MemLimitActive"] description].length > 0 ? [config[@"MemLimitActive"] stringValue] : @"空";
            NSString *i = config[@"MemLimitInactive"] && [config[@"MemLimitInactive"] description].length > 0 ? [config[@"MemLimitInactive"] stringValue] : @"空";
            NSString *n = config[@"NiceValue"] && [config[@"NiceValue"] description].length > 0 ? [config[@"NiceValue"] stringValue] : @"空";
            NSString *s = config[@"CheckInterval"] && [config[@"CheckInterval"] description].length > 0 ? [config[@"CheckInterval"] stringValue] : @"0";
            NSString *line2 = [NSString stringWithFormat:@"p=%@、a=%@、i=%@、n=%@、s=%@", p, a, i, n, s];
            [appSpec setProperty:[NSString stringWithFormat:@"%@\n%@", line1, line2] forKey:@"mc_subtitle"];
            
            if (!isSearching && insertIdx != NSNotFound) {
                [specs insertObject:appSpec atIndex:insertIdx];
                insertIdx++;
            } else {
                [specs addObject:appSpec];
            }
        }

        // 动态创建并追加“关于我们”和跳转链接，以防篡改
        PSSpecifier *aboutGroup = [PSSpecifier preferenceSpecifierNamed:@"关于我们" target:self set:nil get:nil detail:nil cell:PSGroupCell edit:nil];
        [specs addObject:aboutGroup];
        
        PSSpecifier *sileoSpec = [PSSpecifier preferenceSpecifierNamed:@"Sileo 越狱源" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        sileoSpec.buttonAction = @selector(openSileoRepo:);
        [specs addObject:sileoSpec];
        
        PSSpecifier *tgSpec = [PSSpecifier preferenceSpecifierNamed:@"TG分享频道" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        tgSpec.buttonAction = @selector(openTelegramChannel:);
        [specs addObject:tgSpec];
        
        PSSpecifier *qqSpec = [PSSpecifier preferenceSpecifierNamed:@"QQ交流群组" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        qqSpec.buttonAction = @selector(openQQGroup:);
        [specs addObject:qqSpec];
                
        _specifiers = [specs copy];
    }
    return _specifiers;
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

- (NSString *)getSafePathForFile:(NSString *)filename {
    NSString *path = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:filename];
#if !__has_include(<roothide.h>)
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        path = [@"/var/jb" stringByAppendingPathComponent:path];
    }
#else
    path = jbroot(path);
#endif
    return path;
}

- (void)importConfig {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.apple.property-list", @"public.item"] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *url = urls.firstObject;
    
    BOOL isAccessing = [url startAccessingSecurityScopedResource];
    
    NSDictionary *importedDict = [NSDictionary dictionaryWithContentsOfURL:url];
    if (importedDict && importedDict[@"AppConfigs"]) {
        NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
        NSMutableDictionary *currentDict = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath] ?: [NSMutableDictionary dictionary];
        
        // 覆盖配置
        currentDict[@"AppConfigs"] = importedDict[@"AppConfigs"];
        
        [currentDict writeToFile:prefPath atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
        
        notify_post("com.axs.appguard/ApplyLimits");
        [self reloadSpecifiers];
        
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"成功" message:@"配置导入成功并已生效" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"失败" message:@"无效的配置文件" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
    
    if (isAccessing) {
        [url stopAccessingSecurityScopedResource];
    }
}

- (void)exportConfig {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:prefPath]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"当前配置为空" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"AppGuard_Backup.plist"];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:prefPath toPath:tmpPath error:nil];
    
    NSURL *fileURL = [NSURL fileURLWithPath:tmpPath];
    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
    
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = self.view;
        activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 0, 0);
        activityVC.popoverPresentationController.permittedArrowDirections = 0;
    }
    
    [self presentViewController:activityVC animated:YES completion:nil];
}

// 核心修复1：完全重写读取逻辑，绕开 CFPreferences 缓存
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    return dict[[specifier propertyForKey:@"key"]] ?: [specifier propertyForKey:@"default"];
}

// 核心修复1：完全重写写入逻辑，去掉 super 调用，防止 cfprefsd 覆盖我们写入本地文件的内容
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath] ?: [NSMutableDictionary dictionary];
    [dict setObject:value forKey:[specifier propertyForKey:@"key"]];
    [dict writeToFile:prefPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
    notify_post("com.axs.appguard/ApplyLimits");
}

- (void)showProcessModalForName:(NSString *)procName config:(NSDictionary *)config {
    MCProcessEditViewController *vc = [[MCProcessEditViewController alloc] init];
    vc.procName = procName;
    vc.config = config;
    
    __weak typeof(self) weakSelf = self;
    vc.saveCallback = ^(NSString *name, NSDictionary *newConfig) {
        [weakSelf saveAppConfig:newConfig forProcess:name oldName:procName];
    };
    vc.deleteCallback = ^(NSString *name) {
        [weakSelf deleteAppConfigForProcess:name];
    };
    
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)addNewProcess {
    [self showProcessModalForName:nil config:nil];
}

- (void)editProcess:(PSSpecifier *)spec {
    NSString *procName = [spec propertyForKey:@"processName"];
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    NSDictionary *config = (dict[@"AppConfigs"] ?: @{})[procName];
    [self showProcessModalForName:procName config:config];
}

- (void)saveAppConfig:(NSDictionary *)config forProcess:(NSString *)name oldName:(NSString *)oldName {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *appConfigs = [(dict[@"AppConfigs"] ?: @{}) mutableCopy];
    
    // 如果修改了标识名，旧的删掉
    if (oldName && ![oldName isEqualToString:name]) [appConfigs removeObjectForKey:oldName];
    appConfigs[name] = config;
    dict[@"AppConfigs"] = appConfigs;
    
    [dict writeToFile:prefPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
    
    notify_post("com.axs.appguard/ApplyLimits");
    [self reloadSpecifiers]; 
}

- (void)deleteAppConfigForProcess:(NSString *)name {
    NSString *prefPath = [self getSafePathForFile:@"com.axs.appguard.plist"];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *appConfigs = [(dict[@"AppConfigs"] ?: @{}) mutableCopy];
    
    [appConfigs removeObjectForKey:name];
    dict[@"AppConfigs"] = appConfigs;
    
    [dict writeToFile:prefPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:prefPath error:nil];
    
    notify_post("com.axs.appguard/ApplyLimits");
    [self reloadSpecifiers];
}

- (void)showLog {
    MCLogViewController *logVC = [[MCLogViewController alloc] init];
    logVC.logPath = [self getSafePathForFile:@"AppGuard.log"];
    [self.navigationController pushViewController:logVC animated:YES];
}

- (void)clearLog {
    NSString *logPath = [self getSafePathForFile:@"AppGuard.log"];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        if (@available(iOS 13.0, *)) { [fileHandle truncateAtOffset:0 error:nil]; } 
        else { [fileHandle truncateFileAtOffset:0]; }
        [fileHandle closeFile];
    } else {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:[NSData data] attributes:nil];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:logPath error:nil];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"提示" message:@"日志已清空！" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"  style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ================= 主列表界面完全套用 AppData 高度、圆角与动态计算机制 =================
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
        spec = [self performSelector:@selector(specifierAtIndexPath:) withObject:indexPath];
    }
    
    // 根据 Cell 种类的不同（判断是否有动态子标题传入），智能计算列表高度
    if (spec && [spec propertyForKey:@"mc_subtitle"]) {
        return 72.0; // 展开为三行文字总高：Title + 2行 Subtitle
    }
    return 50.0; // 其他所有主页面按钮恢复厚重风格 50.0
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    NSString *title = [(id<UITableViewDataSource>)self tableView:tableView titleForHeaderInSection:section];
    if (!title || title.length == 0) return nil;
    UIView *headerView = [[UIView alloc] init];
    headerView.backgroundColor = [UIColor clearColor];
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]; 
    titleLabel.textColor = [UIColor systemGrayColor];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:titleLabel];
    
    CGFloat padding = 15.0;
    if (@available(iOS 13.0, *)) { padding = 20.0; }
    
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:padding],
        [titleLabel.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-padding],
        [titleLabel.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor constant:-6]
    ]];
    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    NSString *title = [(id<UITableViewDataSource>)self tableView:tableView titleForHeaderInSection:section];
    if (title && title.length > 0) {
        return 38.0;
    }
    return section == 0 ? CGFLOAT_MIN : 15.0; 
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    NSString *footerText = [(id<UITableViewDataSource>)self tableView:tableView titleForFooterInSection:section];
    if (!footerText) return nil;
    UIView *footerView = [[UIView alloc] init];
    footerView.backgroundColor = [UIColor clearColor];
    UILabel *footerLabel = [[UILabel alloc] init];
    footerLabel.text = footerText;
    footerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]; 
    footerLabel.textColor = [UIColor systemGrayColor];
    footerLabel.numberOfLines = 0;
    footerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [footerView addSubview:footerLabel];
    
    CGFloat padding = 15.0;
    if (@available(iOS 13.0, *)) { padding = 20.0; }
    
    [NSLayoutConstraint activateConstraints:@[
        [footerLabel.leadingAnchor constraintEqualToAnchor:footerView.leadingAnchor constant:padding],
        [footerLabel.trailingAnchor constraintEqualToAnchor:footerView.trailingAnchor constant:-padding],
        [footerLabel.topAnchor constraintEqualToAnchor:footerView.topAnchor constant:6],
        [footerLabel.bottomAnchor constraintEqualToAnchor:footerView.bottomAnchor constant:-6]
    ]];
    return footerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    NSString *footerText = [(id<UITableViewDataSource>)self tableView:tableView titleForFooterInSection:section];
    if (!footerText || footerText.length == 0) return CGFLOAT_MIN; 
    
    CGFloat padding = 30.0;
    if (@available(iOS 13.0, *)) { padding = 40.0; }
    CGFloat width = tableView.bounds.size.width - padding;
    CGRect rect = [footerText boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]} context:nil];
    return ceil(rect.size.height) + 12.0; 
}

// 核心修复4：完美还原 AppData 的视觉效果（药丸状圆圆角渲染）
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger numberOfRows = [tableView numberOfRowsInSection:indexPath.section];
    BOOL isFirst = (indexPath.row == 0);
    BOOL isLast = (indexPath.row == numberOfRows - 1);
    
    CGFloat radius = 25.0;
    CACornerMask mask = 0;
    
    if (isFirst && isLast) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else if (isFirst) {
        mask = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    } else if (isLast) {
        mask = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    } else {
        radius = 0;
        mask = 0;
    }
    
    cell.layer.borderWidth = 0.0;
    cell.layer.borderColor = [UIColor clearColor].CGColor;
    cell.layer.cornerRadius = radius;
    cell.layer.maskedCorners = mask;
    cell.layer.masksToBounds = YES;
    
    if (@available(iOS 14.0, *)) {
        UIBackgroundConfiguration *bg = cell.backgroundConfiguration;
        if (bg) {
            bg.cornerRadius = radius; 
            bg.strokeColor = [UIColor clearColor]; 
            bg.strokeWidth = 0.0;
            cell.backgroundConfiguration = bg;
        }
    } else {
        if (cell.backgroundView) {
            cell.backgroundView.layer.cornerRadius = radius;
            cell.backgroundView.layer.maskedCorners = mask;
            cell.backgroundView.layer.masksToBounds = YES;
            cell.backgroundView.layer.borderWidth = 0.0;
        }
    }
    
    if (@available(iOS 13.0, *)) {
        cell.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

- (void)openURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if ([UIApplication.sharedApplication canOpenURL:url]) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

- (void)openSileoRepo { [self openURLString:@"https://axs66.github.io/pro"]; }
- (void)openSileoRepo:(PSSpecifier *)specifier { [self openSileoRepo]; }
- (void)openTelegramChannel { [self openURLString:@"https://t.me/wxfx8"]; }
- (void)openTelegramChannel:(PSSpecifier *)specifier { [self openTelegramChannel]; }
- (void)openQQGroup { [self openURLString:@"http://qm.qq.com/cgi-bin/qm/qr?_wv=1027&k=b9yIV3X8xKi3ZZUC7YXIr1YasKOzjYnm&authKey=ReN7wx79FV6Y4EIowsWSljNRUTSaGfgwWlmRzuvpWpBxl%2BCEKz%2BMNP3JePx1mMQ8&noverify=0&group_code=1001525693"]; }
- (void)openQQGroup:(PSSpecifier *)specifier { [self openQQGroup]; }

@end
