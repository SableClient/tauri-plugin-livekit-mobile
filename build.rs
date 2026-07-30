const COMMANDS: &[&str] = &[
    "getNativeCallCapabilities",
    "connectNativeCall",
    "disconnectNativeCall",
    "setNativeCallMicrophoneEnabled",
    "setNativeCallCameraEnabled",
    "switchNativeCallCamera",
    "setNativeCallRemoteVideoOverlay",
    "clearNativeCallRemoteVideoOverlay",
    "setNativeCallEncryptionKey",
    "getNativeCallState",
];

/// Must match `platforms: [.iOS(...)]` in `ios/Package.swift`.
#[cfg(target_os = "macos")]
const IOS_DEPLOYMENT_TARGET: &str = "14.0";

fn main() {
    // `ios_path` is deliberately unset: it links via swift-rs, which builds for
    // the host destination (it never passes `--triple`), so SwiftPM picks the
    // macOS slices of LiveKit's xcframeworks and fails on `AppKit/AppKit.h`.
    // `link_ios_package` does the same job with an explicit `--triple`.
    tauri_plugin::Builder::new(COMMANDS)
        .android_path("android")
        .build();

    #[cfg(target_os = "macos")]
    link_ios_package();
}

#[cfg(target_os = "macos")]
fn link_ios_package() {
    use std::{env, path::PathBuf, process::Command};

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("ios") {
        return;
    }

    // (sdk, `--triple` value, SwiftPM's output directory for that triple)
    let (sdk, triple, build_dir) = match env::var("TARGET").unwrap().as_str() {
        "aarch64-apple-ios" => (
            "iphoneos",
            format!("arm64-apple-ios{IOS_DEPLOYMENT_TARGET}"),
            "arm64-apple-ios",
        ),
        "aarch64-apple-ios-sim" => (
            "iphonesimulator",
            format!("arm64-apple-ios{IOS_DEPLOYMENT_TARGET}-simulator"),
            "arm64-apple-ios-simulator",
        ),
        "x86_64-apple-ios" => (
            "iphonesimulator",
            format!("x86_64-apple-ios{IOS_DEPLOYMENT_TARGET}-simulator"),
            "x86_64-apple-ios-simulator",
        ),
        _ => return,
    };

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let package_dir = manifest_dir.join("ios");

    // `ios/Package.swift` depends on the Tauri Swift API at `../.tauri/tauri-api`.
    println!("cargo:rerun-if-env-changed=DEP_TAURI_IOS_LIBRARY_PATH");
    let tauri_api_src = env::var("DEP_TAURI_IOS_LIBRARY_PATH").expect(
        "missing `DEP_TAURI_IOS_LIBRARY_PATH` environment variable. \
         Make sure `tauri` is a dependency of the plugin.",
    );
    let tauri_api_dst = manifest_dir.join(".tauri").join("tauri-api");
    let _ = std::fs::remove_dir_all(&tauri_api_dst);
    copy_dir(
        std::path::Path::new(&tauri_api_src),
        &tauri_api_dst,
        &[".build", "Package.resolved", "Tests"],
    );

    let sdk_path = Command::new("xcrun")
        .args(["--sdk", sdk, "--show-sdk-path"])
        .output()
        .expect("failed to run `xcrun --show-sdk-path`");
    assert!(sdk_path.status.success(), "`xcrun` failed for sdk {sdk}");
    let sdk_path = String::from_utf8(sdk_path.stdout)
        .unwrap()
        .trim()
        .to_string();

    let configuration = if env::var("DEBUG").map(|v| v == "true").unwrap_or_default() {
        "debug"
    } else {
        "release"
    };
    let build_path = PathBuf::from(env::var("OUT_DIR").unwrap()).join("swift");

    let status = Command::new("swift")
        .current_dir(&package_dir)
        // Cargo exports SDKROOT, which would override `--sdk` for nested swiftc.
        .env_remove("SDKROOT")
        .args(["build", "-c", configuration])
        .args(["--sdk", &sdk_path])
        .args(["--triple", &triple])
        .args(["--build-path", &build_path.to_string_lossy()])
        .status()
        .expect("failed to run `swift build`");
    assert!(status.success(), "failed to build the iOS Swift package");

    let lib_dir = build_path.join(build_dir).join(configuration);
    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    // LiveKit's binary XCFrameworks land as .framework bundles next to the
    // static library; consumers link them from this directory.
    println!("cargo:rustc-link-search=framework={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=tauri-plugin-livekit-mobile");
    // Narrow: `swift build` rewrites `ios/Package.resolved`, so watching `ios/`
    // wholesale would rebuild every run.
    println!(
        "cargo:rerun-if-changed={}",
        package_dir.join("Sources").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        package_dir.join("Package.swift").display()
    );
}

#[cfg(target_os = "macos")]
fn copy_dir(source: &std::path::Path, target: &std::path::Path, ignore: &[&str]) {
    std::fs::create_dir_all(target).expect("failed to create directory");
    for entry in std::fs::read_dir(source).expect("failed to read directory") {
        let entry = entry.expect("failed to read directory entry");
        let name = entry.file_name();
        if ignore.iter().any(|i| *i == name.to_string_lossy()) {
            continue;
        }
        let dest = target.join(&name);
        if entry
            .file_type()
            .expect("failed to read file type")
            .is_dir()
        {
            copy_dir(&entry.path(), &dest, ignore);
        } else {
            std::fs::copy(entry.path(), &dest).expect("failed to copy file");
        }
    }
}
