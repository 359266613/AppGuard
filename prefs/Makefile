TARGET := iphone:clang:15.6:14.5
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AppGuardPrefs

AppGuardPrefs_FILES = AppGuardPrefs.m
AppGuardPrefs_FRAMEWORKS = UIKit Foundation
AppGuardPrefs_PRIVATE_FRAMEWORKS = Preferences
AppGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
AppGuardPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
