#!/usr/bin/env bash
#
# Build a slim llama.xcframework for Nidget iOS — iOS device (arm64) only.
#
# Ported from HomeBoy (nphil/HomeBoy) — the setup_framework_structure() and
# combine_static_libraries() functions are copied verbatim from llama.cpp's own
# build-xcframework.sh; only the device slice is built, Metal shaders embedded.
#
# Nidget difference: no submodule. llama.cpp is shallow-cloned at LLAMA_PIN below —
# HomeBoy's proven pin. Bump deliberately, never implicitly, and rebuild the
# framework release when you do. The result is copied to Frameworks/llama.xcframework
# and zipped to build/llama.xcframework.zip for the release upload.
set -e

REPO_ROOT="$(pwd)"
LLAMA_PIN="0ed235ea2c17a19fc8238668653946721ed136fd"
LLAMA_DIR="build/llama.cpp"

if [ ! -f "${LLAMA_DIR}/CMakeLists.txt" ]; then
    echo "Cloning llama.cpp at ${LLAMA_PIN}..."
    rm -rf "${LLAMA_DIR}"
    mkdir -p build
    git init -q "${LLAMA_DIR}"
    git -C "${LLAMA_DIR}" remote add origin https://github.com/ggml-org/llama.cpp
    git -C "${LLAMA_DIR}" fetch -q --depth 1 origin "${LLAMA_PIN}"
    git -C "${LLAMA_DIR}" checkout -q FETCH_HEAD
fi

# --- Options (mirrors upstream) ---
IOS_MIN_OS_VERSION=16.4

BUILD_SHARED_LIBS=OFF
LLAMA_BUILD_APP=OFF
LLAMA_BUILD_COMMON=OFF
LLAMA_BUILD_EXAMPLES=OFF
LLAMA_BUILD_TOOLS=OFF
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=OFF
LLAMA_BUILD_MTMD=ON
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_APP=${LLAMA_BUILD_APP}
    -DLLAMA_BUILD_COMMON=${LLAMA_BUILD_COMMON}
    -DLLAMA_BUILD_EXAMPLES=${LLAMA_BUILD_EXAMPLES}
    -DLLAMA_BUILD_TOOLS=${LLAMA_BUILD_TOOLS}
    -DLLAMA_BUILD_TESTS=${LLAMA_BUILD_TESTS}
    -DLLAMA_BUILD_SERVER=${LLAMA_BUILD_SERVER}
    -DLLAMA_BUILD_MTMD=${LLAMA_BUILD_MTMD}
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
)

check_required_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool is required but not found."
        exit 1
    fi
}
check_required_tool "cmake"
check_required_tool "xcrun"

# ============================================================================
# setup_framework_structure() — copied verbatim from upstream build-xcframework.sh
# ============================================================================
setup_framework_structure() {
    local build_dir=$1
    local min_os_version=$2
    local platform=$3  # "ios", "macos", "visionos", or "tvos"
    local framework_name="llama"

    echo "Creating ${platform}-style framework structure for ${build_dir}"

    if [[ "$platform" == "macos" ]]; then
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Headers
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Modules
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Resources
        ln -sf A ${build_dir}/framework/${framework_name}.framework/Versions/Current
        ln -sf Versions/Current/Headers ${build_dir}/framework/${framework_name}.framework/Headers
        ln -sf Versions/Current/Modules ${build_dir}/framework/${framework_name}.framework/Modules
        ln -sf Versions/Current/Resources ${build_dir}/framework/${framework_name}.framework/Resources
        ln -sf Versions/Current/${framework_name} ${build_dir}/framework/${framework_name}.framework/${framework_name}
        local header_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Headers/
        local module_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Modules/
    else
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Headers
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Modules
        rm -rf ${build_dir}/framework/${framework_name}.framework/Versions
        local header_path=${build_dir}/framework/${framework_name}.framework/Headers/
        local module_path=${build_dir}/framework/${framework_name}.framework/Modules/
    fi

    cp include/llama.h             ${header_path}
    cp ggml/include/ggml.h         ${header_path}
    cp ggml/include/ggml-opt.h     ${header_path}
    cp ggml/include/ggml-alloc.h   ${header_path}
    cp ggml/include/ggml-backend.h ${header_path}
    cp ggml/include/ggml-metal.h   ${header_path}
    cp ggml/include/ggml-cpu.h     ${header_path}
    cp ggml/include/ggml-blas.h    ${header_path}
    cp ggml/include/gguf.h         ${header_path}
    cp tools/mtmd/mtmd.h           ${header_path}
    cp tools/mtmd/mtmd-helper.h    ${header_path}

    cat > ${module_path}module.modulemap << EOF
framework module llama {
    umbrella "Headers"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    local platform_name=""
    local sdk_name=""
    local supported_platform=""

    case "$platform" in
        "ios")
            platform_name="iphoneos"
            sdk_name="iphoneos${min_os_version}"
            supported_platform="iPhoneOS"
            local plist_path="${build_dir}/framework/${framework_name}.framework/Info.plist"
            local device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
    esac

    cat > ${plist_path} << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
</dict>
</plist>
EOF
}

# ============================================================================
# combine_static_libraries() — copied verbatim from upstream build-xcframework.sh
# ============================================================================
combine_static_libraries() {
    local build_dir="$1"
    local release_dir="$2"
    local platform="$3"
    local is_simulator="$4"
    local base_dir="$(pwd)"
    local framework_name="llama"

    local output_lib=""
    if [[ "$platform" == "macos" ]]; then
        output_lib="${build_dir}/framework/${framework_name}.framework/Versions/A/${framework_name}"
    else
        output_lib="${build_dir}/framework/${framework_name}.framework/${framework_name}"
    fi

    local libs=(
        "${base_dir}/${build_dir}/src/${release_dir}/libllama.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${base_dir}/${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
    )

    local temp_dir="${base_dir}/${build_dir}/temp"
    mkdir -p "${temp_dir}"

    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null

    local sdk=""
    local archs=""
    local min_version_flag=""
    local install_name=""

    case "$platform" in
        "ios")
            if [[ "$is_simulator" == "true" ]]; then
                sdk="iphonesimulator"
                archs="arm64 x86_64"
                min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
            else
                sdk="iphoneos"
                archs="arm64"
                min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
            fi
            install_name="@rpath/llama.framework/llama"
            ;;
    esac

    local arch_flags=""
    for arch in $archs; do
        arch_flags+=" -arch $arch"
    done

    echo "Creating dynamic library for ${platform}."
    xcrun -sdk $sdk clang++ -dynamiclib \
        -isysroot $(xcrun --sdk $sdk --show-sdk-path) \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "$install_name" \
        -o "${base_dir}/${output_lib}"

    if [[ "$is_simulator" == "false" ]]; then
        if xcrun -f vtool &>/dev/null; then
            echo "Marking binary as a framework binary for iOS..."
            xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
                -output "${base_dir}/${output_lib}" "${base_dir}/${output_lib}"
        else
            echo "Warning: vtool not found."
        fi
    fi

    echo "Creating properly formatted dSYM..."
    mkdir -p "${base_dir}/${build_dir}/dSYMs"
    xcrun dsymutil "${base_dir}/${output_lib}" -o "${base_dir}/${build_dir}/dSYMs/llama.dSYM"
    cp "${base_dir}/${output_lib}" "${temp_dir}/binary_to_strip"
    xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
    mv "${temp_dir}/stripped_lib" "${base_dir}/${output_lib}"

    if [ -d "${base_dir}/${output_lib}.dSYM" ]; then
        rm -rf "${base_dir}/${output_lib}.dSYM"
    fi

    rm -rf "${temp_dir}"
}

# ============================================================================
# Build — iOS device (arm64) only
# ============================================================================
cd "${LLAMA_DIR}"

echo "Cleaning previous builds..."
rm -rf build-ios-device build-apple

echo "Building for iOS devices..."
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -DMTMD_VIDEO=OFF \
    -S .
cmake --build build-ios-device --config Release -j $(sysctl -n hw.logicalcpu) -- -quiet

echo "Setting up framework structure..."
setup_framework_structure "build-ios-device" ${IOS_MIN_OS_VERSION} "ios"

echo "Combining static libraries..."
combine_static_libraries "build-ios-device" "Release-iphoneos" "ios" "false"

echo "Creating XCFramework..."
xcrun xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-device/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-device/dSYMs/llama.dSYM \
    -output $(pwd)/build-apple/llama.xcframework

echo "Copying to repo Frameworks/ ..."
rm -rf "${REPO_ROOT}/Frameworks/llama.xcframework"
mkdir -p "${REPO_ROOT}/Frameworks"
cp -R build-apple/llama.xcframework "${REPO_ROOT}/Frameworks/llama.xcframework"

echo "Zipping for release upload..."
cd "${REPO_ROOT}"
rm -f build/llama.xcframework.zip
ditto -c -k --keepParent Frameworks/llama.xcframework build/llama.xcframework.zip

echo "Done:"
du -sh "${REPO_ROOT}/Frameworks/llama.xcframework" build/llama.xcframework.zip
