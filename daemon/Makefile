# Match the root project and CI SDK (16.5); deploy to iOS 14.5 and later.
TARGET := iphone:clang:16.5:14.5
ARCHS = arm64 arm64e          

include $(THEOS)/makefiles/common.mk

TOOL_NAME = appguardd
appguardd_FILES = main.m
appguardd_CFLAGS = -fobjc-arc
appguardd_INSTALL_PATH = /usr/local/bin
appguardd_FRAMEWORKS = Foundation

# 仅仅多加这一行用来给守护进程提权
appguardd_CODESIGN_FLAGS = -Sdaemon.entitlements

include $(THEOS_MAKE_PATH)/tool.mk
