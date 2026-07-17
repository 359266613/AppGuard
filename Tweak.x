#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

%hook SpringBoard

- (void)frontDisplayDidChange:(id)newDisplay {
    %orig;
    
    // 写入 syslog 供 Console.app 查看
    NSLog(@"[AppGuard] Tweak observed display change, notifying Daemon...");
    
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.axs.appguard/ApplyLimits"),
        NULL,
        NULL,
        YES
    );
}

%end
