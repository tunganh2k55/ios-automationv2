# Build libvncserver cho iOS arm64

## Yêu cầu
- macOS với Xcode (hoặc cross-compile từ Linux)
- CMake 3.16+
- iOS SDK (Xcode Command Line Tools)

## Dependencies (pre-built hoặc tự build)
1. **libz** - có sẵn trong iOS SDK
2. **libjpeg-turbo** - cần build
3. **libpng** - có sẵn trong iOS SDK  
4. **OpenSSL** (optional, cho encryption)

## Bước 1: Build libjpeg-turbo

```bash
git clone https://github.com/libjpeg-turbo/libjpeg-turbo.git
cd libjpeg-turbo
mkdir build-ios && cd build-ios

cmake .. \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_INSTALL_PREFIX=$HOME/ios-libs \
  -DENABLE_SHARED=OFF \
  -DWITH_TURBOJPEG=OFF

make -j4
make install
```

## Bước 2: Build libvncserver

```bash
git clone https://github.com/LibVNC/libvncserver.git
cd libvncserver
mkdir build-ios && cd build-ios

# Cấu hình cho iOS static library
cmake .. \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DCMAKE_INSTALL_PREFIX=$HOME/ios-libs \
  -DBUILD_SHARED_LIBS=OFF \
  -DWITH_OPENSSL=OFF \
  -DWITH_GCRYPT=OFF \
  -DWITH_GNUTLS=OFF \
  -DWITH_SASL=OFF \
  -DWITH_SYSTEMD=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_EXAMPLES=OFF \
  -DWITH_TESTS=OFF \
  -DJPEG_LIBRARY=$HOME/ios-libs/lib/libjpeg.a \
  -DJPEG_INCLUDE_DIR=$HOME/ios-libs/include

make -j4
make install
```

## Bước 3: Copy vào project

```bash
# Headers
mkdir -p app/daemon/include/rfb
cp $HOME/ios-libs/include/rfb/*.h app/daemon/include/rfb/

# Static library
mkdir -p app/daemon/lib
cp $HOME/ios-libs/lib/libvncserver.a app/daemon/lib/
cp $HOME/ios-libs/lib/libjpeg.a app/daemon/lib/
```

## Bước 4: Update Makefile

Thêm vào `Makefile`:

```makefile
# VNC server support
iosautod_CFLAGS += -DHAVE_LIBVNCSERVER -Iinclude
iosautod_LDFLAGS += -Llib -lvncserver -ljpeg
```

## Thay thế: Dùng pre-built từ TrollVNC

TrollVNC đã có sẵn libvncserver build cho iOS. Có thể extract từ:
https://github.com/OwnGoalStudio/TrollVNC/releases

Hoặc build từ Makefile của họ (dùng Theos):
```bash
git clone https://github.com/OwnGoalStudio/TrollVNC.git
cd TrollVNC
make package FINALPACKAGE=1
# Libraries trong .theos/obj/debug/arm64/
```

## Test

Sau khi build xong, chạy daemon và kiểm tra:
```bash
# Trên device
iosautod &

# Kiểm tra port 5900
netstat -an | grep 5900

# Từ máy tính, kết nối VNC Viewer tới IP_DEVICE:5900
```
