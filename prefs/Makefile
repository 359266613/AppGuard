# Match the SDK installed by CI; 14.5 is the deployment target, not the SDK.
TARGET := iphone:clang:16.5:14.5
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AppGuardPrefs

AppGuardPrefs_FILES = AppGuardPrefs.m
AppGuardPrefs_FRAMEWORKS = UIKit Foundation
AppGuardPrefs_PRIVATE_FRAMEWORKS = Preferences
AppGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
AppGuardPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
