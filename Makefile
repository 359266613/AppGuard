DEBUG = 0
FINALPACKAGE = 1

# Use the SDK installed by CI (16.5); keep the deployment target at iOS 14.5.
TARGET := iphone:clang:16.5:14.5
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

# Ensure the staged maintainer script is executable before dpkg-deb validates it.
before-package::
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst"
