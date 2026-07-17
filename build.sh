#!/bin/bash
# 记得在终端执行: chmod +x build.sh

PLIST_PATH="layout/Library/LaunchDaemons/com.axs.appguardd.plist"

echo ">>> 清理旧文件..."
make clean

echo ">>> 正在编译 Rootful (有根) 版本..."
# 确保 plist 内部是标准有根路径
sed -i '' 's|/var/jb/usr/local/bin|/usr/local/bin|g' $PLIST_PATH
make package

echo ">>> 正在编译 Rootless (无根) 版本..."
# 核心修复：把 plist 里的执行路径加上无根前缀
sed -i '' 's|/usr/local/bin|/var/jb/usr/local/bin|g' $PLIST_PATH
make package THEOS_PACKAGE_SCHEME=rootless

echo ">>> 正在编译 Roothide (隐藏越狱) 版本..."
# Roothide 工具链会自动处理路径，保持当前的 /var/jb 前缀也无妨
make package THEOS_PACKAGE_SCHEME=roothide

echo ">>> 恢复源代码文件初始状态..."
# 编译完后恢复成有根代码，保持你的源码库干净
sed -i '' 's|/var/jb/usr/local/bin|/usr/local/bin|g' $PLIST_PATH

echo ">>> 编译完成！所有版本已生成。"
