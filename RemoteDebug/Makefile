# 仅用于 macOS（有 Xcode 时）。Windows 请用 GitHub Actions 或在线 CI。
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)

SRC := src/RemoteDebug.m src/RDIndexHTML.m src/RDHook.m src/RDAutomation.m src/RDTool.m src/RDFloat.m
OUT := build/RemoteDebug.dylib

all: $(OUT)

$(OUT): $(SRC)
	@mkdir -p build
	xcrun --sdk iphoneos clang \
	  -arch arm64 \
	  -miphoneos-version-min=14.0 \
	  -isysroot "$(SDK)" \
	  -dynamiclib -fobjc-arc -O2 -Wall -Wno-unused-function \
	  -install_name @executable_path/RemoteDebug.dylib \
	  -framework Foundation -framework UIKit -framework JavaScriptCore -framework AudioToolbox -framework CoreGraphics -framework CoreFoundation \
	  -o $@ $(SRC)
	@ldid -S $@ 2>/dev/null || true
	@echo "built: $@"

clean:
	rm -rf build

.PHONY: all clean
