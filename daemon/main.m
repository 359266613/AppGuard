#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/resource.h>
#import <sys/stat.h>
#import <notify.h>
#import <errno.h>

#define PROC_ALL_PIDS 1
extern int proc_listpids(uint32_t type, uint32_t typeinfo, void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pidpath(int pid, void * buffer, uint32_t  buffersize);

#define MEMORYSTATUS_CMD_GET_PRIORITY_LIST            1
#define MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES      2
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES      8
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES      7
#define MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED       16
#define MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED       17
#define MEMORYSTATUS_SET_PRIORITY_ASSERTION           0x1
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL              0x1

// 新增底层调度头文件宏定义防闪退
#ifndef PRIO_DARWIN_ROLE
#define PRIO_DARWIN_ROLE 6
#endif
#ifndef PRIO_DARWIN_ROLE_UI_FOCAL
#define PRIO_DARWIN_ROLE_UI_FOCAL 1
#endif

typedef struct memorystatus_priority_entry {
    pid_t pid;
    int32_t priority;
    uint64_t user_data;
    int32_t limit;
    uint32_t state;
} memorystatus_priority_entry_t;

typedef struct memorystatus_priority_properties {
    int32_t  priority;
    uint64_t user_data;
} memorystatus_priority_properties_t;

typedef struct memorystatus_memlimit_properties {
    int32_t memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

extern int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// ================= 全局状态跟踪器 =================
static NSMutableDictionary *g_appliedProcesses = nil;
static NSMutableDictionary *g_appTimers = nil;
static NSMutableDictionary *g_cachedAppConfigs = nil;
static NSMutableDictionary *g_appPIDs = nil;
static NSMutableDictionary *g_statusDict = nil;
static NSMutableDictionary *g_pathBundleIDCache = nil; // 新增：全局Info.plist解析缓存

static dispatch_source_t debounceTimer = nil;
static dispatch_queue_t debounceQueue = nil;
static dispatch_queue_t workerQueue = nil; // 核心修复：独立防并发工作队列
static dispatch_source_t global1800sTimer = nil;

NSString * getPrefPath(NSString *filename) {
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

#define MCLOG(fmt, ...) do { \
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; \
    [df setDateFormat:@"MM-dd HH:mm:ss"]; \
    NSString *timeStr = [df stringFromDate:[NSDate date]]; \
    fprintf(stderr, "[%s] " fmt "\n", [timeStr UTF8String], ##__VA_ARGS__); \
    fflush(stderr); \
} while(0)

// 优化：全局极速快照，结合 C 级 API 特性，严格确保每个循环都触发 autorelease，完美避免内存激增被杀
static NSDictionary *buildRunningProcessMap() {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    @autoreleasepool {
        int numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
        if (numberOfProcesses <= 0) return map;
        
        pid_t *pids = malloc(numberOfProcesses * sizeof(pid_t));
        if (!pids) return map;
        
        // 初始化全局缓存字典
        if (!g_pathBundleIDCache) g_pathBundleIDCache = [[NSMutableDictionary alloc] init];
        
        int actualCount = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * sizeof(pid_t)) / sizeof(pid_t);
        for (int i = 0; i < actualCount; ++i) {
            @autoreleasepool { // 核心修复：每次循环即刻释放由 NSString 产生的内存
                pid_t p = pids[i];
                if (p <= 0) continue;
                
                char nameBuffer[256];
                bzero(nameBuffer, sizeof(nameBuffer));
                if (proc_name(p, nameBuffer, sizeof(nameBuffer)) > 0) {
                    NSString *pName = [NSString stringWithUTF8String:nameBuffer];
                    if (pName && pName.length > 0 && !map[pName]) {
                        map[pName] = @(p);
                    }
                }
                
                char pathBuffer[4096];
                bzero(pathBuffer, sizeof(pathBuffer));
                if (proc_pidpath(p, pathBuffer, sizeof(pathBuffer)) > 0) {
                    NSString *execPath = [NSString stringWithUTF8String:pathBuffer];
                    if (execPath) {
                        NSString *parentDir = [execPath stringByDeletingLastPathComponent];
                        if ([parentDir hasSuffix:@".app"] || [parentDir hasSuffix:@".appex"]) {
                            // 核心优化：命中缓存则直接使用，彻底消灭磁盘 I/O 瓶颈
                            NSString *bundleID = g_pathBundleIDCache[parentDir];
                            if (!bundleID) {
                                NSString *infoPlistPath = [parentDir stringByAppendingPathComponent:@"Info.plist"];
                                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                                bundleID = info[@"CFBundleIdentifier"];
                                if (bundleID && bundleID.length > 0) {
                                    g_pathBundleIDCache[parentDir] = bundleID; // 写入缓存
                                }
                            }
                            if (bundleID && bundleID.length > 0) {
                                map[bundleID] = @(p);
                            }
                        }
                    }
                }
            }
        }
        free(pids);
    }
    return map;
}

pid_t getPIDForBundleID(NSString *targetIdentifier) {
    pid_t match = 0;
    @autoreleasepool {
        int numberOfProcesses = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
        if (numberOfProcesses <= 0) return 0;
        
        pid_t *pids = malloc(numberOfProcesses * sizeof(pid_t));
        if (!pids) return 0;
        
        if (!g_pathBundleIDCache) g_pathBundleIDCache = [[NSMutableDictionary alloc] init];
        
        int actualCount = proc_listpids(PROC_ALL_PIDS, 0, pids, numberOfProcesses * sizeof(pid_t)) / sizeof(pid_t);
        for (int i = 0; i < actualCount; ++i) {
            @autoreleasepool {
                if (pids[i] <= 0) continue;
                
                char nameBuffer[256];
                bzero(nameBuffer, sizeof(nameBuffer));
                proc_name(pids[i], nameBuffer, sizeof(nameBuffer));
                if (strcmp(nameBuffer, targetIdentifier.UTF8String) == 0) {
                    match = pids[i];
                    break;
                }
                
                char pathBuffer[4096];
                bzero(pathBuffer, sizeof(pathBuffer));
                if (proc_pidpath(pids[i], pathBuffer, sizeof(pathBuffer)) > 0) {
                    NSString *execPath = [NSString stringWithUTF8String:pathBuffer];
                    if (execPath) {
                        NSString *parentDir = [execPath stringByDeletingLastPathComponent];
                        if ([parentDir hasSuffix:@".app"] || [parentDir hasSuffix:@".appex"]) {
                            // 核心优化：命中缓存则直接使用
                            NSString *bundleID = g_pathBundleIDCache[parentDir];
                            if (!bundleID) {
                                NSString *infoPlistPath = [parentDir stringByAppendingPathComponent:@"Info.plist"];
                                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                                bundleID = info[@"CFBundleIdentifier"];
                                if (bundleID && bundleID.length > 0) {
                                    g_pathBundleIDCache[parentDir] = bundleID;
                                }
                            }
                            if ([bundleID isEqualToString:targetIdentifier]) {
                                match = pids[i];
                                break;
                            }
                        }
                    }
                }
            }
        }
        free(pids);
    }
    return match;
}

void updateStatusFile(NSString *bundleID, pid_t pid, int actual_nice, int actual_jetsam) {
    if (!g_statusDict) g_statusDict = [[NSMutableDictionary alloc] init];
    
    if (pid == 0) {
        [g_statusDict removeObjectForKey:bundleID];
    } else {
        g_statusDict[bundleID] = @{
            @"pid": @(pid),
            @"n": @(actual_nice),
            @"p": @(actual_jetsam)
        };
    }
    
    NSString *path = getPrefPath(@"com.axs.appguard.status.plist");
    [g_statusDict writeToFile:path atomically:YES];
    chmod([path UTF8String], 0666);
}

int getActualJetsam(pid_t pid) {
    int list_sz = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, NULL, 0);
    if (list_sz > 0) {
        size_t alloc_sz = list_sz + sizeof(memorystatus_priority_entry_t) * 10;
        memorystatus_priority_entry_t *entries = (memorystatus_priority_entry_t *)malloc(alloc_sz);
        if (entries) {
            errno = 0;
            int actual_sz = memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST, 0, 0, entries, alloc_sz);
            int actual_jetsam = -999;
            if (actual_sz > 0) {
                int count = actual_sz / sizeof(memorystatus_priority_entry_t);
                for (int i = 0; i < count; i++) {
                    if (entries[i].pid == pid) {
                        actual_jetsam = entries[i].priority;
                        break;
                    }
                }
            }
            free(entries);
            return actual_jetsam;
        }
    }
    return -999;
}

void verifyJetsamPriority(pid_t pid, int set_ret, int target_jetsam) {
    int actual_jetsam = getActualJetsam(pid);
    if (actual_jetsam != -999) {
        MCLOG("[内存优先级] 为:%d", actual_jetsam);
        if (target_jetsam == -999) {
            MCLOG("[内核] ：系统接管并分配真实优先级为 %d", actual_jetsam);
        } else if (actual_jetsam == target_jetsam) {
            MCLOG("[内核] ：成功");
        } else {
            MCLOG("[内核] ：已被系统覆盖 (设置:%d 实际:%d)", target_jetsam, actual_jetsam);
        }
    } else {
        MCLOG("[内存优先级] 未在内核优先级列表中找到 PID:%d", pid);
        MCLOG("[内核] ：%s", (set_ret == 0) ? "调用成功但状态丢失" : "失败");
    }
}

void protect_daemon_itself() {
    pid_t pid = getpid();
    MCLOG("[守护] PID:%d", pid);
    
    int nice_ret = setpriority(PRIO_PROCESS, pid, -20);
    int verify_nice = getpriority(PRIO_PROCESS, pid);
    MCLOG("[系统] 设定进程优先级 -> %s", (nice_ret == 0) ? "[内核: 成功]" : "[内核: 失败]");
    if (nice_ret == 0 && verify_nice == -20) {
        MCLOG("[内核] ：成功");
    } else if (nice_ret == 0) {
        MCLOG("[内核] ：已被系统覆盖 (实际: %d)", verify_nice);
    } else {
        MCLOG("[内核] ：失败");
    }
    
    memorystatus_priority_properties_t prio;
    memset(&prio, 0, sizeof(prio));
    prio.priority = 999;
    
    int ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &prio, sizeof(prio));
    if (ret == -1) {
        prio.priority = 210;
        ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &prio, sizeof(prio));
        if (ret == -1) {
            prio.priority = 21;
            ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &prio, sizeof(prio));
        }
    }
    MCLOG("[系统] 设定内存优先级(%d) -> %s", prio.priority, (ret == 0) ? "[内核] 成功" : "[内核] 失败");
    verifyJetsamPriority(pid, ret, prio.priority);
    
    MCLOG("[守护] AppGuard 后台守护进程初始化完成");
    MCLOG("========================================");
}

// 优化：通过传入PID直接执行恢复，不再调用重型PID检索，0开销
void restoreDefaultsForProcess(NSString *processIdentifier, pid_t pid) {
    updateStatusFile(processIdentifier, 0, 0, 0);
    if (pid == 0) return; 
    
    MCLOG("----------------------------------------");
    MCLOG("[恢复] 目标: %s PID: %d", processIdentifier.UTF8String, pid);
    
    setpriority(PRIO_PROCESS, pid, 0);
    
    memorystatus_memlimit_properties_t write_mem;
    memset(&write_mem, 0, sizeof(write_mem));
    write_mem.memlimit_active = 0;
    write_mem.memlimit_inactive = 0;
    memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &write_mem, sizeof(write_mem));
    
    int manage = 1;
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, &manage, sizeof(manage));
    
    memorystatus_priority_properties_t prio_props;
    memset(&prio_props, 0, sizeof(prio_props));
    prio_props.priority = 0;
    memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0, &prio_props, sizeof(prio_props));
    
    MCLOG("[守护] %s PID:%d", processIdentifier.UTF8String, pid);
}

void applyLimitsForApp(NSString *targetProc, NSDictionary *config, pid_t pid) {
    if (pid == 0) return;
    
    // ================== 1. 活跃/非活跃限制 (MemLimit) ==================
    int targetActive = 0;
    if (config[@"MemLimitActive"] && [config[@"MemLimitActive"] description].length > 0) {
        targetActive = [config[@"MemLimitActive"] intValue];
    }
    
    int targetInactive = 0;
    if (config[@"MemLimitInactive"] && [config[@"MemLimitInactive"] description].length > 0) {
        targetInactive = [config[@"MemLimitInactive"] intValue];
    }
    
    memorystatus_memlimit_properties_t write_mem;
    memset(&write_mem, 0, sizeof(write_mem));
    write_mem.memlimit_active = targetActive;
    write_mem.memlimit_inactive = targetInactive;
    
    if (targetActive > 0) write_mem.memlimit_active_attr |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    if (targetInactive > 0) write_mem.memlimit_inactive_attr |= MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
    
    errno = 0;
    int set_ret = memorystatus_control(MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES, pid, 0, &write_mem, sizeof(write_mem));
    
    if (set_ret == 0) {
        memorystatus_memlimit_properties_t read_mem;
        memset(&read_mem, 0, sizeof(read_mem));
        memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES, pid, 0, &read_mem, sizeof(read_mem));
        MCLOG("[内存限制] 目标 Act:%d Inact:%d | 最终 Act:%d Inact:%d -> [成功]", 
              targetActive, targetInactive, read_mem.memlimit_active, read_mem.memlimit_inactive);
        
        BOOL activeMatch = ((targetActive == 0 || targetActive == -1) && read_mem.memlimit_active > 0) || (read_mem.memlimit_active == targetActive);
        BOOL inactiveMatch = ((targetInactive == 0 || targetInactive == -1) && read_mem.memlimit_inactive > 0) || (read_mem.memlimit_inactive == targetInactive);

        if (activeMatch && inactiveMatch) {
            MCLOG("[内核] ：成功");
        } else {
            MCLOG("[内核] ：已被系统覆盖");
        }
    } else {
        MCLOG("[内存限制] 目标 Act:%d Inact:%d -> [失败] err:%d", targetActive, targetInactive, errno);
        MCLOG("[内核] ：失败");
    }
    
    // ================== 2. 进程优先级 (CPU Nice) ==================
    int targetNice = 0;
    if (config[@"NiceValue"] && [config[@"NiceValue"] description].length > 0) {
        targetNice = [config[@"NiceValue"] intValue];
        if (targetNice < -20) targetNice = -20;
        if (targetNice > 20) targetNice = 20;
    }
    
    errno = 0;
    int currentNice = getpriority(PRIO_PROCESS, pid);
    if (currentNice != -1 || errno == 0) {
        if (currentNice != targetNice) {
            int nice_ret = setpriority(PRIO_PROCESS, pid, targetNice);
            if (nice_ret == 0) {
                int verify_nice = getpriority(PRIO_PROCESS, pid);
                MCLOG("[进程优先级] 当前:%d 目标:%d -> [成功]", currentNice, targetNice);
                if (verify_nice == targetNice) {
                    MCLOG("[内核] ：成功");
                } else {
                    MCLOG("[内核] ：已被系统覆盖 (实际: %d)", verify_nice);
                }
            } else {
                MCLOG("[进程优先级] 当前:%d 目标:%d -> [失败] err:%d", currentNice, targetNice, errno);
                MCLOG("[内核] ：失败");
            }
        } else {
            MCLOG("[进程优先级] 目标已是 %d", targetNice);
        }
    } else {
        MCLOG("[进程优先级] 读取状态失败 err:%d", errno);
    }
    
    // ================== 3. 内存优先级 (Jetsam Priority) ==================
    int targetJetsam = 0;
    if (config[@"JetsamPriority"] && [config[@"JetsamPriority"] description].length > 0) {
        targetJetsam = [config[@"JetsamPriority"] intValue];
    }
    
    if (targetJetsam == -1) {
        MCLOG("[内存优先级] 目标:-1 -> 未设置, 跳过");
    } else if (targetJetsam == 0) {
        int manage = 1;
        memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, &manage, sizeof(manage));
        
        memorystatus_priority_properties_t prio_props;
        memset(&prio_props, 0, sizeof(prio_props));
        prio_props.priority = 0; 
        int ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0, &prio_props, sizeof(prio_props));
        
        MCLOG("[内存优先级] 目标:0 -> [恢复默认, 系统接管]");
        verifyJetsamPriority(pid, ret, -999);
    } else {
        int scaledJetsam = targetJetsam;
        BOOL isScaled = NO;
        
        int unmanage = 0;
        memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, &unmanage, sizeof(unmanage));
        
        memorystatus_priority_properties_t prio_props;
        memset(&prio_props, 0, sizeof(prio_props));
        prio_props.priority = scaledJetsam;
        
        errno = 0;
        int jetsam_ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &prio_props, sizeof(prio_props));
        
        // 核心修复：完美内核动态探测法。
        // 如果系统拒绝了高目标值（返回 -1），且目标值可以被缩放，则自动除以 10 再次下发
        if (jetsam_ret == -1 && targetJetsam > 0 && targetJetsam != 999) {
            scaledJetsam = targetJetsam / 10;
            isScaled = YES;
            prio_props.priority = scaledJetsam;
            jetsam_ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, MEMORYSTATUS_SET_PRIORITY_ASSERTION, &prio_props, sizeof(prio_props));
        }
        
        if (isScaled) {
            MCLOG("[环境适配] 目标 %d -> 实际 %d", targetJetsam, scaledJetsam);
        }
        
        MCLOG("[系统] 内存优先级:%d -> [%s]", scaledJetsam, (jetsam_ret == 0) ? "内核: 成功" : "内核: 失败");
        verifyJetsamPriority(pid, jetsam_ret, scaledJetsam);
    }

    // ================== 5. 状态剥离 P_MEMSTAT_MANAGED & 核心强制锁 (内核对抗机制) ==================
    if (config[@"StripManaged"] != nil) {
        BOOL strip = [config[@"StripManaged"] boolValue];
        int manageFlag = strip ? 0 : 1;
        errno = 0;
        int manage_ret = memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, pid, 0, &manageFlag, sizeof(manageFlag));
        
        int actual_managed = memorystatus_control(MEMORYSTATUS_CMD_GET_PROCESS_IS_MANAGED, pid, 0, NULL, 0);
        
        if (strip) {
            // 1. 强制剥离冷冻状态限制 (防止内核将其加入休眠冻结列表)
            int freezeFlag = 0;
            memorystatus_control(18 /* MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE */, pid, 0, &freezeFlag, sizeof(freezeFlag));
            // 2. 提升非活跃频段保护 (对抗后台 IDLE 强制降级)
            memorystatus_control(14 /* MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_ENABLE */, pid, 0, NULL, 0);
            // 3. 锁定 CPU UI 焦点角色 (欺骗系统 CPU 调度器始终保留挂起权)
            setpriority(PRIO_DARWIN_ROLE, pid, PRIO_DARWIN_ROLE_UI_FOCAL);
        } else {
            int freezeFlag = 1;
            memorystatus_control(18 /* MEMORYSTATUS_CMD_SET_PROCESS_IS_FREEZABLE */, pid, 0, &freezeFlag, sizeof(freezeFlag));
            memorystatus_control(15 /* MEMORYSTATUS_CMD_ELEVATED_INACTIVEJETSAMPRIORITY_DISABLE */, pid, 0, NULL, 0);
        }
        
        MCLOG("[状态剥离] 目标: %s -> [操作: %s] [内核]: %d)", strip ? "剥离系统托管并开启强锁" : "恢复系统托管", (manage_ret == 0) ? "成功" : "失败", actual_managed);
    }
    
    // ================== 4. 记录真实状态供 UI 读取 ==================
    int actual_nice = getpriority(PRIO_PROCESS, pid);
    int actual_jetsam = getActualJetsam(pid);
    updateStatusFile(targetProc, pid, actual_nice, actual_jetsam);
    
    MCLOG("[守护] %s PID:%d 完成", targetProc.UTF8String, pid);
}

void checkLogSizeAndClearIfNeeded() {
    NSString *logPath = getPrefPath(@"AppGuard.log");
    NSString *prefPath = getPrefPath(@"com.axs.appguard.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    NSNumber *limitNum = prefs[@"LogSizeLimit"];
    long long limitBytes = limitNum ? [limitNum longLongValue] : 2 * 1024 * 1024; // 默认 2MB
    
    if (limitBytes <= 0) return; // 0 代表从不
    
    struct stat st;
    if (stat([logPath UTF8String], &st) == 0) {
        if (st.st_size > limitBytes) {
            // 清空并重新打开
            freopen([logPath UTF8String], "w", stdout);
            freopen([logPath UTF8String], "w", stderr);
            MCLOG("[守护] 日志大小超过设定限制(%.1fMB)，已自动清空。", limitBytes / 1024.0 / 1024.0);
        }
    }
}

void executeMemoryLimits() {
    checkLogSizeAndClearIfNeeded();
    
    if (!g_appTimers) g_appTimers = [[NSMutableDictionary alloc] init];
    if (!g_appliedProcesses) g_appliedProcesses = [[NSMutableDictionary alloc] init];
    if (!g_cachedAppConfigs) g_cachedAppConfigs = [[NSMutableDictionary alloc] init];
    if (!g_appPIDs) g_appPIDs = [[NSMutableDictionary alloc] init];

    NSString *prefPath = getPrefPath(@"com.axs.appguard.plist");
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
    BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : NO;
    
    if (!enabled) {
        for (dispatch_source_t timer in g_appTimers.allValues) {
            dispatch_source_cancel(timer);
        }
        [g_appTimers removeAllObjects];
        [g_cachedAppConfigs removeAllObjects];

        if (g_appliedProcesses.count > 0) {
            MCLOG("----------------------------------------");
            MCLOG("[配置] 生效开关已关闭，已挂起守护进程并还原默认状态");
            NSArray *keys = g_appliedProcesses.allKeys;
            [g_appliedProcesses removeAllObjects]; // 立即清空缓存以防重入
            
            // 线程安全：先拷贝出此时的 PID，再清空全局字典
            NSDictionary *snapPIDs = [g_appPIDs copy];
            [g_appPIDs removeAllObjects]; 
            
            // 核心修复：直接使用内存里的历史PID进行极速恢复，彻底告别 CPU 满载
            dispatch_async(workerQueue, ^{
                @autoreleasepool {
                    for (NSString *proc in keys) {
                        @autoreleasepool {
                            pid_t pid = [snapPIDs[proc] intValue];
                            if (pid != 0) {
                                restoreDefaultsForProcess(proc, pid);
                            } else {
                                updateStatusFile(proc, 0, 0, 0);
                            }
                        }
                    }
                }
            });
        } else {
            [g_appPIDs removeAllObjects];
        }
        return; 
    }

    NSDictionary *appConfigs = prefs[@"AppConfigs"];
    if (!appConfigs) appConfigs = @{};

    NSArray *trackedProcs = [g_appliedProcesses.allKeys copy];
    NSMutableArray *removedProcs = [NSMutableArray array];
    NSMutableDictionary *removedPIDs = [NSMutableDictionary dictionary]; // 记录将被移除的PID
    
    for (NSString *procIdentifier in trackedProcs) {
        if (!appConfigs[procIdentifier]) {
            [removedProcs addObject:procIdentifier];
            removedPIDs[procIdentifier] = g_appPIDs[procIdentifier] ?: @(0);
            
            dispatch_source_t oldTimer = g_appTimers[procIdentifier];
            if (oldTimer) {
                dispatch_source_cancel(oldTimer);
                [g_appTimers removeObjectForKey:procIdentifier];
            }
            [g_cachedAppConfigs removeObjectForKey:procIdentifier];
            [g_appliedProcesses removeObjectForKey:procIdentifier];
            [g_appPIDs removeObjectForKey:procIdentifier];
        }
    }
    if (removedProcs.count > 0) {
        MCLOG("----------------------------------------");
        MCLOG("[配置] 已有进程从列表移除，已恢复默认");
        dispatch_async(workerQueue, ^{
            @autoreleasepool {
                for (NSString *proc in removedProcs) {
                    @autoreleasepool {
                        pid_t pid = [removedPIDs[proc] intValue]; // 直接利用旧缓存PID极速还原
                        if (pid != 0) {
                            restoreDefaultsForProcess(proc, pid);
                        } else {
                            updateStatusFile(proc, 0, 0, 0);
                        }
                    }
                }
            }
        });
    }

    if ([appConfigs count] == 0) return;
    
    NSDictionary *runningMap = buildRunningProcessMap();
    
    for (NSString *targetProc in appConfigs) {
        NSDictionary *config = appConfigs[targetProc];
        NSDictionary *cachedConfig = g_cachedAppConfigs[targetProc];
        
        pid_t currentPid = [runningMap[targetProc] intValue];
        pid_t lastPid = [g_appPIDs[targetProc] intValue];
        
        BOOL configChanged = !(cachedConfig && [config isEqualToDictionary:cachedConfig]);
        BOOL pidChanged = (currentPid != lastPid);
        
        if (!configChanged && !pidChanged) {
            continue;
        }
        
        g_cachedAppConfigs[targetProc] = config;
        g_appPIDs[targetProc] = @(currentPid);
        g_appliedProcesses[targetProc] = @(YES);
        
        int interval = config[@"CheckInterval"] ? [config[@"CheckInterval"] intValue] : 0;
        if (interval < 0) interval = 0; 

        if (pidChanged) {
            MCLOG("----------------------------------------");
            if (currentPid == 0) {
                MCLOG("[进程] 目标: %s 已退出", targetProc.UTF8String);
                updateStatusFile(targetProc, 0, 0, 0);
            } else {
                MCLOG("[进程] 目标: %s 已启动 PID: %d ", targetProc.UTF8String, currentPid);
                applyLimitsForApp(targetProc, config, currentPid);
            }
        } else if (configChanged && currentPid != 0) {
            MCLOG("----------------------------------------");
            MCLOG("[配置] 目标: %s PID: %d", targetProc.UTF8String, currentPid);
            applyLimitsForApp(targetProc, config, currentPid);
        }

        dispatch_source_t existTimer = g_appTimers[targetProc];
        if (existTimer) {
            dispatch_source_cancel(existTimer);
            [g_appTimers removeObjectForKey:targetProc];
        }
        
        if (interval > 0) {
            dispatch_source_t appTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, debounceQueue);
            dispatch_source_set_timer(appTimer, dispatch_time(DISPATCH_TIME_NOW, interval * NSEC_PER_SEC), interval * NSEC_PER_SEC, 1ull * NSEC_PER_SEC);
            dispatch_source_set_event_handler(appTimer, ^{
                pid_t activePid = getPIDForBundleID(targetProc);
                pid_t cachedPid = [g_appPIDs[targetProc] intValue];
                
                if (activePid != cachedPid) {
                    MCLOG("----------------------------------------");
                    if (activePid == 0) {
                        MCLOG("[进程] 目标: %s 已退出", targetProc.UTF8String);
                        updateStatusFile(targetProc, 0, 0, 0);
                    } else {
                        MCLOG("[进程] 目标: %s 已启动 PID: %d ", targetProc.UTF8String, activePid);
                        applyLimitsForApp(targetProc, config, activePid);
                    }
                    g_appPIDs[targetProc] = @(activePid);
                } else if (activePid != 0) {
                    MCLOG("----------------------------------------");
                    MCLOG("[守护] 目标: %s | 检测: %ds | PID: %d", targetProc.UTF8String, interval, activePid);
                    applyLimitsForApp(targetProc, config, activePid);
                }
            });
            dispatch_resume(appTimer);
            g_appTimers[targetProc] = appTimer;
        }
    }
}

void applyMemoryLimits() {
    if (!debounceQueue) debounceQueue = dispatch_queue_create("com.axs.appguard.debounce", DISPATCH_QUEUE_SERIAL);
    if (!workerQueue) workerQueue = dispatch_queue_create("com.axs.appguard.worker", DISPATCH_QUEUE_SERIAL);
    
    dispatch_async(debounceQueue, ^{
        if (debounceTimer) {
            dispatch_source_cancel(debounceTimer);
            debounceTimer = nil;
        }
        debounceTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, debounceQueue);
        // 核心修复：把 1.5 秒改成 0.15 秒，实现视觉上的立刻生效
        dispatch_source_set_timer(debounceTimer, dispatch_time(DISPATCH_TIME_NOW, 0.15 * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(debounceTimer, ^{
            executeMemoryLimits();
        });
        dispatch_resume(debounceTimer);
    });
}

// ================= 新增：全局1800s定时器，处理CheckInterval=0的进程 =================
void setupGlobal1800sTimer() {
    if (!debounceQueue) debounceQueue = dispatch_queue_create("com.axs.appguard.debounce", DISPATCH_QUEUE_SERIAL);
    if (!workerQueue) workerQueue = dispatch_queue_create("com.axs.appguard.worker", DISPATCH_QUEUE_SERIAL);
    
    if (!global1800sTimer) {
        global1800sTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, debounceQueue);
        // 周期设为 1800 秒 (30分钟)
        dispatch_source_set_timer(global1800sTimer, dispatch_time(DISPATCH_TIME_NOW, 1800 * NSEC_PER_SEC), 1800 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(global1800sTimer, ^{
            NSString *prefPath = getPrefPath(@"com.axs.appguard.plist");
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:prefPath];
            BOOL enabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue] : NO;
            if (!enabled) return;
            
            NSDictionary *appConfigs = prefs[@"AppConfigs"];
            if (!appConfigs || appConfigs.count == 0) return;
            
            MCLOG("========================================");
            MCLOG("[守护] 开始执行 1800s ");
            
            NSArray *keys = appConfigs.allKeys;
            // 核心修复：放到防杀单线程队列，自带内存池安全释放，保证上千任务不涨内存
            dispatch_async(workerQueue, ^{
                @autoreleasepool {
                    NSDictionary *runningMap = buildRunningProcessMap(); // 获取全局快照，秒级性能
                    for (NSString *targetProc in keys) {
                        @autoreleasepool {
                            NSDictionary *config = appConfigs[targetProc];
                            int interval = config[@"CheckInterval"] ? [config[@"CheckInterval"] intValue] : 0;
                            if (interval <= 0) { // 等于0交由此守护处理
                                pid_t activePid = [runningMap[targetProc] intValue];
                                if (activePid != 0) {
                                    applyLimitsForApp(targetProc, config, activePid);
                                } else {
                                    updateStatusFile(targetProc, 0, 0, 0);
                                }
                                dispatch_async(debounceQueue, ^{
                                    g_appPIDs[targetProc] = @(activePid);
                                });
                            }
                        }
                    }
                    MCLOG("[全局守护] 1800s 周期巡检完成。");
                    MCLOG("========================================");
                }
            });
        });
        dispatch_resume(global1800sTimer);
    }
}

// ================= 自动生成默认配置 =================
void checkAndGenerateDefaultConfig() {
    NSString *prefPath = getPrefPath(@"com.axs.appguard.plist");
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:prefPath]) return;
    
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
    chmod([prefPath UTF8String], 0666);
    MCLOG("[配置] 已生成默认预设参数");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *logPath = getPrefPath(@"AppGuard.log");
        
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:logPath]) {
            [fm createFileAtPath:logPath contents:[NSData data] attributes:nil];
        }
        chmod([logPath UTF8String], 0666);
        
        freopen([logPath UTF8String], "a+", stdout);
        freopen([logPath UTF8String], "a+", stderr);
        
        MCLOG("========================================");
        
        // --- 调用生成默认配置 ---
        checkAndGenerateDefaultConfig();
        
        protect_daemon_itself();
        
        applyMemoryLimits();
        setupGlobal1800sTimer();
        
        int token;
        notify_register_dispatch("com.axs.appguard/ApplyLimits", &token, dispatch_get_main_queue(), ^(int t) {
            applyMemoryLimits();
        });
        
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
