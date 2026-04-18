//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    private static let immediateAKInterfaceDelay = "0.00"
    var menuController: MenuController?

    @objc static public func launch() {
        let runtimeBundleId = Bundle.main.bundleIdentifier
            ?? "playtools.runtime.\(ProcessInfo.processInfo.processIdentifier)"
        let playSettings = PlaySettings.shared
        let appliesMinimalStartupCompat = playSettings.appliesMinimalStartupCompat
        RuntimeLaunchDiagnostics.record(event: "playcover_launch_enter", bundleId: runtimeBundleId)

        if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_startup_compat_profile_applied",
                bundleId: runtimeBundleId,
                details: [
                    "profile": "minimal-startup",
                    "playChain": playSettings.playChain ? "true" : "false",
                    "rootWorkDir": playSettings.rootWorkDir ? "true" : "false",
                    "metalCaptureEnabled": playSettings.metalCaptureEnabled ? "true" : "false",
                    "injectMetalCaptureEnvironment": playSettings.injectMetalCaptureEnvironment ? "true" : "false",
                    "shaderSourceReplacementEnabled": playSettings.shaderSourceReplacementEnabled ? "true" : "false",
                    "librarySourceInjectionEnabled": playSettings.shouldInstallLibrarySourceInjection ? "true" : "false",
                ]
            )
        }

        quitWhenClose()
        RuntimeLaunchDiagnostics.record(event: "playcover_quit_observer_installed", bundleId: runtimeBundleId)

        initializeAKInterface(bundleId: runtimeBundleId, playSettings: playSettings)

        if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_screen_skipped",
                bundleId: runtimeBundleId,
                details: ["reason": "startup_compat_profile"]
            )
        } else {
            PlayScreen.shared.initialize()
            RuntimeLaunchDiagnostics.record(event: "playcover_screen_initialized", bundleId: runtimeBundleId)
        }

        if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_input_skipped",
                bundleId: runtimeBundleId,
                details: ["reason": "startup_compat_profile"]
            )
        } else {
            PlayInput.shared.initialize()
            RuntimeLaunchDiagnostics.record(event: "playcover_input_initialized", bundleId: runtimeBundleId)
        }

        if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_discord_skipped",
                bundleId: runtimeBundleId,
                details: ["reason": "startup_compat_profile"]
            )
        } else {
            DiscordIPC.shared.initialize()
            RuntimeLaunchDiagnostics.record(event: "playcover_discord_initialized", bundleId: runtimeBundleId)
        }

        // 初始化 Metal 截帧服务
        let shouldPreloadCaptureForSourceAttribution =
            playSettings.metalCaptureEnabled && playSettings.shaderSourceReplacementEnabled
        let shouldPreloadCaptureEarly = playSettings.metalCaptureEnabled
        let capturePreloadedEarly: Bool

        if playSettings.metalCaptureEnabled {
            MetalCaptureService.shared.initialize()
            RuntimeLaunchDiagnostics.record(event: "playcover_metal_capture_initialized", bundleId: runtimeBundleId)
            capturePreloadedEarly = MetalCaptureService.shared.prepareForEarlyCaptureIfNeeded()
        } else {
            capturePreloadedEarly = false
            if appliesMinimalStartupCompat {
                RuntimeLaunchDiagnostics.record(
                    event: "playcover_metal_capture_skipped",
                    bundleId: runtimeBundleId,
                    details: ["reason": "startup_compat_profile"]
                )
            }
        }

        RuntimeLaunchDiagnostics.record(
            event: "playcover_capture_library_preload_checked",
            bundleId: runtimeBundleId,
            details: [
                "needed": shouldPreloadCaptureEarly ? "true" : "false",
                "loaded": capturePreloadedEarly ? "true" : "false",
                "sourceAttributionNeeded": shouldPreloadCaptureForSourceAttribution ? "true" : "false",
                "suppressedByCompatProfile": appliesMinimalStartupCompat ? "true" : "false",
            ]
        )

        // E-003 / E-004f3: 安装 makeLibrary swizzle（运行时 shader corpus 导出 + 源码替换入口）
        // 若启用了 capture + replacement，上面的 preload 必须先于 swizzle / replacement 发生。
        if playSettings.shouldInstallLibrarySourceInjection {
            LibrarySourceInjectionService.shared.installIfNeeded()
            RuntimeLaunchDiagnostics.record(event: "playcover_library_injection_installed", bundleId: runtimeBundleId)
        } else if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_library_injection_skipped",
                bundleId: runtimeBundleId,
                details: ["reason": "startup_compat_profile"]
            )
        }

        NSLog("%@", "[PlayTools] PlayCover.launch bundleId=\(runtimeBundleId)")
        RuntimeLaunchDiagnostics.record(event: "playcover_bridge_listener_start_requested", bundleId: runtimeBundleId)
        let runtimePort = BridgeListener.shared.start(bundleId: runtimeBundleId)
        if runtimePort > 0 {
            NSLog("%@", "[PlayTools] BridgeListener launched on port \(runtimePort)")
            RuntimeLaunchDiagnostics.record(
                event: "playcover_bridge_listener_start_succeeded",
                bundleId: runtimeBundleId,
                details: ["localPort": String(runtimePort)]
            )
        } else {
            NSLog("%@", "[PlayTools] BridgeListener launch returned port 0")
            RuntimeLaunchDiagnostics.record(event: "playcover_bridge_listener_start_failed", bundleId: runtimeBundleId)
        }

        if playSettings.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
            RuntimeLaunchDiagnostics.record(event: "playcover_working_directory_changed", bundleId: runtimeBundleId, details: ["cwd": "/"])
        } else if appliesMinimalStartupCompat {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_working_directory_preserved",
                bundleId: runtimeBundleId,
                details: ["cwd": FileManager.default.currentDirectoryPath]
            )
        }

        RuntimeLaunchDiagnostics.record(
            event: "playcover_launch_complete",
            bundleId: runtimeBundleId,
            details: [
                "injectMetalCaptureEnvironment": playSettings.injectMetalCaptureEnvironment ? "true" : "false",
                "metalCaptureEnabled": playSettings.metalCaptureEnabled ? "true" : "false",
                "shaderSourceReplacementEnabled": playSettings.shaderSourceReplacementEnabled ? "true" : "false",
            ]
        )
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
    }

    /// HOK-013: 供 PlayLoader.m 的 `pt_ngr_preheat_slot_once()` 回调使用，
    /// 把 NGR `__common` slot 预热事件落盘到 `launch-events.jsonl`。
    ///
    /// 只在 `com.tencent.ngr` 进程内被调用（gate 在 C 侧），但这里仍以
    /// `Bundle.main.bundleIdentifier` 作为事件 `bundleId`，保证
    /// `RuntimeLaunchDiagnostics` 的 per-bundle 日志路径与其它事件一致。
    @objc static public func recordHOK013PreheatDiagnostic(details: [String: String]) {
        let runtimeBundleId = Bundle.main.bundleIdentifier
            ?? "playtools.runtime.\(ProcessInfo.processInfo.processIdentifier)"
        RuntimeLaunchDiagnostics.record(
            event: "hok013_ngr_slot_preheat",
            bundleId: runtimeBundleId,
            details: details
        )
    }

    static public func quitWhenClose() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSWindowWillCloseNotification"),
            object: nil,
            queue: OperationQueue.main
        ) { notif in
            if PlayScreen.shared.nsWindow?.isEqual(notif.object) ?? false {
                // Step 1: Resign active
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneWillResignActive?(scene)
                    NotificationCenter.default.post(name: UIScene.willDeactivateNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillResignActive?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                                object: UIApplication.shared)

                // Step 2: Enter background
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidEnterBackground?(scene)
                    NotificationCenter.default.post(name: UIScene.didEnterBackgroundNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationDidEnterBackground?(UIApplication.shared)
                NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                                object: UIApplication.shared)

                // Step 2.5: End UIBackgroundTask
                // There is an expiration handler, but idk how to invoke it. Skip for now.

                // Step 3: Terminate
                for scene in UIApplication.shared.connectedScenes {
                    scene.delegate?.sceneDidDisconnect?(scene)
                    NotificationCenter.default.post(name: UIScene.didDisconnectNotification,
                                                    object: scene)
                }
                UIApplication.shared.delegate?.applicationWillTerminate?(UIApplication.shared)
                BridgeListener.shared.stop()
                // Some apps will freeze or crash when click close button if we send willTerminateNotification.
                // The developer documentation says this is a "may be called method", so it can be safely skipped.
                // https://developer.apple.com/documentation/uikit/uiapplicationdelegate/1623111-applicationwillterminate
                // swiftlint:disable:previous line_length
//                NotificationCenter.default.post(name: UIApplication.willTerminateNotification,
//                                                object: UIApplication.shared)
                terminateApplicationIfPossible()

                // Step 3.5: End BGTask
                // BGTask typically runs in another process and is tricky to terminate.
                // It may run into infinite loops, end up silently heating the device up.
                // This actually happens for ToF. Hope future developers can solve this.
            }
        }
    }

    static func delay(_ delay: Double, closure: @escaping () -> Void) {
        let when = DispatchTime.now() + delay
        DispatchQueue.main.asyncAfter(deadline: when, execute: closure)
    }

    private static func initializeAKInterface(bundleId: String, playSettings: PlaySettings) {
        guard let akInterfaceInitializationDelay = playSettings.akInterfaceInitializationDelay else {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_akinterface_initialize_started",
                bundleId: bundleId,
                details: [
                    "delaySeconds": immediateAKInterfaceDelay,
                    "mode": "immediate",
                ]
            )
            AKInterface.initialize()
            RuntimeLaunchDiagnostics.record(
                event: "playcover_akinterface_initialized",
                bundleId: bundleId,
                details: [
                    "delaySeconds": immediateAKInterfaceDelay,
                    "mode": "immediate",
                ]
            )
            return
        }

        let formattedDelay = formatDelaySeconds(akInterfaceInitializationDelay)
        RuntimeLaunchDiagnostics.record(
            event: "playcover_akinterface_delayed",
            bundleId: bundleId,
            details: [
                "delaySeconds": formattedDelay,
                "mode": "scheduled",
                "reason": "startup_compat_profile",
            ]
        )
        delay(akInterfaceInitializationDelay) {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_akinterface_initialize_started",
                bundleId: bundleId,
                details: [
                    "delaySeconds": formattedDelay,
                    "mode": "delayed",
                ]
            )
            AKInterface.initialize()
            RuntimeLaunchDiagnostics.record(
                event: "playcover_akinterface_initialized",
                bundleId: bundleId,
                details: [
                    "delaySeconds": formattedDelay,
                    "mode": "delayed",
                ]
            )
        }
    }

    private static func terminateApplicationIfPossible() {
        if let akInterface = AKInterface.shared {
            DispatchQueue.main.async(execute: akInterface.terminateApplication)
            return
        }

        if let akInterfaceInitializationDelay = PlaySettings.shared.akInterfaceInitializationDelay {
            RuntimeLaunchDiagnostics.record(
                event: "playcover_akinterface_terminate_skipped",
                bundleId: PlaySettings.shared.bundleIdentifier,
                details: [
                    "delaySeconds": formatDelaySeconds(akInterfaceInitializationDelay),
                    "reason": "akinterface_not_initialized_yet",
                ]
            )
            return
        }

        DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)
    }

    private static func formatDelaySeconds(_ delay: TimeInterval) -> String {
        String(format: "%.2f", delay)
    }
}
