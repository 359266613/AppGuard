DEBUG = 0
FINALPACKAGE = 1

# 强制使用 14.5 SDK，避免最新的 Xcode SDK 编译 arm64e 导致 iOS 14 闪退！
TARGET := iphone:clang:15.6:14.5
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppGuard
AppGuard_FILES = Tweak.x
AppGuard_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
# 确保包含你的设置面板和守护进程目录
SUBPROJECTS += prefs daemon
include $(THEOS_MAKE_PATH)/aggregate.mk
