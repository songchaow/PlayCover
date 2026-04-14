//
//  PlayCover.swift
//  PlayTools
//

import Foundation
import UIKit

public class PlayCover: NSObject {

    static let shared = PlayCover()
    var menuController: MenuController?

    @objc static public func launch() {
        let runtimeBundleId = Bundle.main.bundleIdentifier
            ?? "playtools.runtime.\(ProcessInfo.processInfo.processIdentifier)"
        RuntimeLaunchDiagnostics.record(event: "playcover_launch_enter", bundleId: runtimeBundleId)

        quitWhenClose()
        RuntimeLaunchDiagnostics.record(event: "playcover_quit_observer_installed", bundleId: runtimeBundleId)

        AKInterface.initialize()
        RuntimeLaunchDiagnostics.record(event: "playcover_akinterface_initialized", bundleId: runtimeBundleId)

        PlayScreen.shared.initialize()
        RuntimeLaunchDiagnostics.record(event: "playcover_screen_initialized", bundleId: runtimeBundleId)

        PlayInput.shared.initialize()
        RuntimeLaunchDiagnostics.record(event: "playcover_input_initialized", bundleId: runtimeBundleId)

        DiscordIPC.shared.initialize()
        RuntimeLaunchDiagnostics.record(event: "playcover_discord_initialized", bundleId: runtimeBundleId)

        // 初始化 Metal 截帧服务
        MetalCaptureService.shared.initialize()
        RuntimeLaunchDiagnostics.record(event: "playcover_metal_capture_initialized", bundleId: runtimeBundleId)

        let shouldPreloadCaptureForSourceAttribution =
            PlaySettings.shared.metalCaptureEnabled && PlaySettings.shared.shaderSourceReplacementEnabled
        let shouldPreloadCaptureEarly = PlaySettings.shared.metalCaptureEnabled
        let capturePreloadedEarly =
            MetalCaptureService.shared.prepareForEarlyCaptureIfNeeded()
        RuntimeLaunchDiagnostics.record(
            event: "playcover_capture_library_preload_checked",
            bundleId: runtimeBundleId,
            details: [
                "needed": shouldPreloadCaptureEarly ? "true" : "false",
                "loaded": capturePreloadedEarly ? "true" : "false",
                "sourceAttributionNeeded": shouldPreloadCaptureForSourceAttribution ? "true" : "false",
            ]
        )

        // E-003 / E-004f3: 安装 makeLibrary swizzle（运行时 shader corpus 导出 + 源码替换入口）
        // 若启用了 capture + replacement，上面的 preload 必须先于 swizzle / replacement 发生。
        LibrarySourceInjectionService.shared.installIfNeeded()
        RuntimeLaunchDiagnostics.record(event: "playcover_library_injection_installed", bundleId: runtimeBundleId)

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

        if PlaySettings.shared.rootWorkDir {
            // Change the working directory to / just like iOS
            FileManager.default.changeCurrentDirectoryPath("/")
            RuntimeLaunchDiagnostics.record(event: "playcover_working_directory_changed", bundleId: runtimeBundleId, details: ["cwd": "/"])
        }

        RuntimeLaunchDiagnostics.record(
            event: "playcover_launch_complete",
            bundleId: runtimeBundleId,
            details: [
                "injectMetalCaptureEnvironment": PlaySettings.shared.injectMetalCaptureEnvironment ? "true" : "false",
                "metalCaptureEnabled": PlaySettings.shared.metalCaptureEnabled ? "true" : "false",
                "shaderSourceReplacementEnabled": PlaySettings.shared.shaderSourceReplacementEnabled ? "true" : "false",
            ]
        )
    }

    @objc static public func initMenu(menu: NSObject) {
        guard let menuBuilder = menu as? UIMenuBuilder else { return }
        shared.menuController = MenuController(with: menuBuilder)
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
                DispatchQueue.main.async(execute: AKInterface.shared!.terminateApplication)

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
}
