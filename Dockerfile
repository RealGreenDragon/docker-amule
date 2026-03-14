# --- STAGE 1: Builder ---
FROM alpine:3.22.2 AS stage-build

# Git options
## *_GIT_REPO = git url
## *_GIT_REF  = branch name, tag name, or commit SHA
ARG AMULE_GIT_REPO=https://github.com/amule-project/amule.git
ARG AMULE_GIT_REF=5fd4775a403c2b29fb14ed396f9208e4fde80129
ARG AMULEWEBUI_GIT_REPO=https://github.com/MatteoRagni/AmuleWebUI-Reloaded.git
ARG AMULEWEBUI_GIT_REF=3fef80d724b71366667d7ae9de5809b878b98f75

# aMule general cmake/make options
ARG CMAKE_BUILD_TYPE=Release
ARG BUILD_TESTING=OFF
ARG MAKE_JOBS=3

# aMule core binaries options (only amuled/amuleweb/amulecmd needed in headless container)
ARG BUILD_MONOLITHIC=OFF
ARG BUILD_DAEMON=ON
ARG BUILD_REMOTEGUI=OFF
ARG BUILD_AMULECMD=ON
ARG BUILD_WEBSERVER=ON

# aMule support tools options (default OFF)
ARG BUILD_PLASMAMULE=OFF
ARG BUILD_ED2K=OFF
ARG BUILD_ALCC=OFF
ARG BUILD_ALC=OFF
ARG BUILD_CAS=OFF
ARG BUILD_WXCAS=OFF
ARG BUILD_XAS=OFF
ARG BUILD_FILEVIEW=OFF

# aMule optional libs (default OFF - disabled also BOOST as make DLs very slow...)
ARG ENABLE_BOOST=OFF
ARG ENABLE_UPNP=OFF
ARG ENABLE_IP2COUNTRY=OFF
ARG ENABLE_NLS=OFF

# aMule extra files (default OFF except man)
ARG INCLUDE_LANGS=OFF
ARG INCLUDE_MANPAGES=ON
ARG INCLUDE_DOCS=OFF

WORKDIR /src_amule

# 1. Install build dependencies
RUN apk add --no-cache \
    git \
    curl \
    cmake \
    build-base \
    pkgconf \
    bison \
    musl-dev \
    gettext-dev \
    zlib-dev \
    libpng-dev \
    wxwidgets-dev \
    crypto++-dev \
    gd-dev \
    readline-dev && \
    if [ "$BUILD_REMOTEGUI" = "ON" ]; then apk add --no-cache libsm-dev; fi && \
    if [ "$ENABLE_BOOST" = "ON" ]; then apk add --no-cache boost-dev; fi && \
    if [ "$ENABLE_UPNP" = "ON" ]; then apk add --no-cache libupnp-dev; fi && \
    if [ "$ENABLE_IP2COUNTRY" = "ON" ]; then apk add --no-cache geoip-dev; fi

# 2. Copy patch files
COPY patches /src_patches

# 3. Clone requested aMule source code and apply patches
RUN \
    # Get source code
    git init --initial-branch=main . && \
    git remote add origin ${AMULE_GIT_REPO} && \
    git fetch --depth=1 --filter=blob:none --no-tags origin ${AMULE_GIT_REF} && \
    git switch --detach FETCH_HEAD && \
    # Apply patches
    for pf in $(find /src_patches/amule -type f -name "*.patch"); do \
      echo "======================================================="; \
      echo "@ Applying patch $pf"; \
      echo "-------------------------------------------------------"; \
      patch -p1 -l --binary < "$pf" || exit 1; \
    done

# 4. CMake configure and compile
# CMAKE_BUILD_TYPE    --> Release/Debug
# DCMAKE_CXX_STANDARD --> 14: Force using C++14 standard
# CMAKE_CXX_FLAGS     --> -Wno-*: Ignore specific compiling warnings
RUN cmake -B build \
    #### Configure
    # aMule general configure options
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE} \
    -DCMAKE_CXX_STANDARD=14 \
    -DCMAKE_CXX_FLAGS="-Wno-dev -Wno-deprecated-declarations -Wno-register -Wno-unused-local-typedefs" \
    -DBUILD_TESTING=${BUILD_TESTING} \
    # aMule Core options
    -DBUILD_MONOLITHIC=${BUILD_MONOLITHIC} \
    -DBUILD_DAEMON=${BUILD_DAEMON} \
    -DBUILD_REMOTEGUI=${BUILD_REMOTEGUI} \
    -DBUILD_AMULECMD=${BUILD_AMULECMD} \
    -DBUILD_WEBSERVER=${BUILD_WEBSERVER} \
    # aMule Tools options
    -DBUILD_PLASMAMULE=${BUILD_PLASMAMULE} \
    -DBUILD_ED2K=${BUILD_ED2K} \
    -DBUILD_ALC=${BUILD_ALC} \
    -DBUILD_ALCC=${BUILD_ALCC} \
    -DBUILD_CAS=${BUILD_CAS} \
    -DBUILD_WXCAS=${BUILD_WXCAS} \
    -DBUILD_XAS=${BUILD_XAS} \
    -DBUILD_FILEVIEW=${BUILD_FILEVIEW} \
    # aMule optional libs
    -DENABLE_BOOST=${ENABLE_BOOST} \
    -DENABLE_UPNP=${ENABLE_UPNP} \
    -DENABLE_IP2COUNTRY=${ENABLE_IP2COUNTRY} \
    -DENABLE_NLS=${ENABLE_NLS} && \
    #### Fix SVNDATE in config.h
    export AMULE_GIT_REV=$(git rev-parse HEAD) && \
    echo "@ Set SVNDATE to \"rev. ${AMULE_GIT_REV}\"" && \
    sed -i "s/^#define SVNDATE .*/#define SVNDATE \"rev. ${AMULE_GIT_REV}\"/" /src_amule/build/config.h && \
    #### Compile
    make -C build -j${MAKE_JOBS} && \
    #### Install
    make -C build install DESTDIR=/install && \
    #### Create build marker files
    if [ "$ENABLE_UPNP" = "ON" ]; then touch /install/usr/share/amule/.build_upnp; fi && \
    if [ "$ENABLE_IP2COUNTRY" = "ON" ]; then touch /install/usr/share/amule/.build_ip2country; fi && \
    if [ "$ENABLE_NLS" = "ON" ]; then touch /install/usr/share/amule/.build_nls; fi

# 5. Remove unwanted files
RUN \
    # 5A. Binaries stripping (release only)
    if [ "$CMAKE_BUILD_TYPE" = "Release" ]; then find /install/usr/bin -type f -exec strip --strip-all {} \; 2>/dev/null || true; fi && \
    # 5B. Remove Langs (locale and man)
    if [ "$INCLUDE_LANGS" = "OFF" ]; then rm -rf /install/usr/share/locale; fi && \
    if [ "$INCLUDE_LANGS" = "OFF" ]; then find /install/usr/share/man -mindepth 1 -maxdepth 1 -type d ! -name 'man1' -exec rm -rf {} +; fi && \
    # 5C. Remove Man pages
    if [ "$INCLUDE_MANPAGES" = "OFF" ]; then rm -rf /install/usr/share/man; fi && \
    # 5D. Remove Documentation
    if [ "$INCLUDE_DOCS" = "OFF" ]; then rm -rf /install/usr/share/doc; fi && \
    # 5E. Remove skins
    if [ "$BUILD_REMOTEGUI" = "OFF" ]; then rm -rf /install/usr/share/skins; fi && \
    # 5F. Remove pixmaps
    if [ "$BUILD_REMOTEGUI" = "OFF" ]; then rm -rf /install/usr/share/pixmaps; fi && \
    # 5G. Remove webserver
    if [ "$BUILD_WEBSERVER" = "OFF" ]; then rm -rf /install/usr/share/amule/webserver; fi && \
    # 5H. Remove applications
    rm -rf /install/usr/share/applications

WORKDIR /src_amule_webui

# 6. Clone requested AmuleWebUI-Reloaded code and install it
RUN \
    if [ "$BUILD_WEBSERVER" = "ON" ]; then \
      # Init source code folder
      git init --initial-branch=main AmuleWebUI-Reloaded && \
      ( \
        # Get source code
        cd AmuleWebUI-Reloaded && \
        git remote add origin "${AMULEWEBUI_GIT_REPO}" && \
        git fetch --depth=1 --filter=blob:none --no-tags origin "${AMULEWEBUI_GIT_REF}" && \
        git switch --detach FETCH_HEAD && \
        # Apply patches
        for pf in $(find /src_patches/amule_webui_reloaded -type f -name "*.patch"); do \
          echo "======================================================="; \
          echo "@ Applying patch $pf"; \
          echo "-------------------------------------------------------"; \
          patch -p1 -l --binary < "$pf" || exit 1; \
        done && \
        # Remove unused files
        rm -rf .git doc-images README.md \
      ) && \
      # Install webui
      mv AmuleWebUI-Reloaded /install/usr/share/amule/webserver; \
    fi

# --- STAGE 2: Runtime ---
FROM alpine:3.22.2 AS stage-run

LABEL maintainer="RealGreenDragon"

# Env variables
ENV TZ=UTC

# Docker Buildx automatic options
ARG TARGETARCH

# S6-Overlay Options
ARG S6_OVERLAY_VERSION=3.2.1.0

# 1. Copy aMule files and check aMule binaries
COPY --from=stage-build /install/usr /usr

# 2. Copy S6-Overlay services files
COPY etc /etc

# 3. Install Runtime packages and S6-Overlay
RUN apk add --no-cache \
    # Install core aMule dependencies
    wxwidgets \
    crypto++ \
    musl \
    libpng \
    libgcc \
    libstdc++ \
    readline \
    zlib \
    # Install other runtime packages
    pwgen \
    coreutils \
    curl \
    tzdata \
    # Install S6-Overlay install-only dependencies
    xz && \
    # Install optional aMule libs
    if [ -f /usr/share/amule/.build_upnp ]; then apk add --no-cache libupnp; rm -f /usr/share/amule/.build_upnp; fi && \
    if [ -f /usr/share/amule/.build_ip2country ]; then apk add --no-cache geoip; rm -f /usr/share/amule/.build_ip2country; fi && \
    if [ -f /usr/share/amule/.build_nls ]; then apk add --no-cache libintl; rm -f /usr/share/amule/.build_nls; fi && \
    # Install S6-Overlay for TARGETARCH
    case "${TARGETARCH}" in \
        "amd64")   S6_ARCH="x86_64" ;; \
        "386")     S6_ARCH="i686" ;; \
        "arm")     S6_ARCH="armhf" ;; \
        "arm64")   S6_ARCH="aarch64" ;; \
        "ppc64")   S6_ARCH="powerpc64" ;; \
        "ppc64le") S6_ARCH="powerpc64le" ;; \
        "riscv64") S6_ARCH="riscv64" ;; \
        "s390x")   S6_ARCH="s390x" ;; \
        *)         echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac && \
    echo "Downloading S6 Overlay ${S6_OVERLAY_VERSION} for ${S6_ARCH}..." && \
    curl -fsSL -o /tmp/s6-overlay-noarch.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz && \
    curl -fsSL -o /tmp/s6-overlay-${S6_ARCH}.tar.xz https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-${S6_ARCH}.tar.xz && \
    rm -f /tmp/s6-overlay-*.tar.xz && \
    # Cleanup S6-Overlay install-only dependencies
    apk del --no-cache xz

# 4. Check aMule binaries
RUN echo "Checking all aMule binaries for needed libs" && \
    find /usr/bin -mindepth 1 -maxdepth 1 -type f \( \
      -name "alc" -o \
      -name "alcc" -o \
      -name "amule" -o \
      -name "amulecmd" -o \
      -name "amuled" -o \
      -name "amulegui" -o \
      -name "amuleweb" -o \
      -name "cas" -o \
      -name "ed2k" -o \
      -name "fileview" -o \
      -name "wxcas" \
    \) -exec sh -c 'echo "@ $1"; out=$(ldd "$1" 2>&1); echo "$out"; if echo "$out" | grep -q -E "not found|Error"; then exit 1; fi' _ {} \;

# 5. Set /home/amule as workdir
WORKDIR /home/amule

# 6. Expose aMule standard ports
# 4662/tcp (ED2K), 4672/udp (ED2K), 4665/udp (Kad)
EXPOSE 4662 4672/udp 4665/udp

# 7. Use S6-Overlay /init entrypoint
ENTRYPOINT ["/init"]

# HELP
#
# => Build Docker image
# docker buildx build -t greendragon/amule:myprod .
#
# => Build multi-arch Docker image
# docker buildx create --use
# docker buildx build -t greendragon/amule:myprod --platform linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64/v8,linux/ppc64le,linux/riscv64,linux/s390x .
#
