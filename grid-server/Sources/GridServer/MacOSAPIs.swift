//
// MacOSAPIs.swift
// GridServer
//
// Private macOS API bindings for SkyLight framework (dynamically loaded)
//

import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox  // For ProcessSerialNumber (deprecated but still functional)

// MARK: - Dynamic Library Loading

private let SkyLightFramework: UnsafeMutableRawPointer? = {
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    return dlopen(path, RTLD_LAZY)
}()

private func loadSymbol<T>(_ name: String) -> T? {
    guard let handle = SkyLightFramework else { return nil }
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
}

// MARK: - Function Type Definitions

typealias SLSMainConnectionID_t = @convention(c) () -> Int32
typealias SLSRegisterConnectionNotifyProc_t = @convention(c) (Int32, @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void, UInt32, UnsafeMutableRawPointer?) -> CGError
typealias SLSCopyManagedDisplays_t = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SLSCopyManagedDisplaySpaces_t = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias SLSManagedDisplayGetCurrentSpace_t = @convention(c) (Int32, CFString) -> UInt64
typealias SLSCopyManagedDisplayForWindow_t = @convention(c) (Int32, UInt32) -> Unmanaged<CFString>?
typealias SLSSpaceGetType_t = @convention(c) (Int32, UInt64) -> Int32
typealias SLSSpaceCopyName_t = @convention(c) (Int32, UInt64) -> Unmanaged<CFString>?
typealias SLSCopySpacesForWindows_t = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
typealias SLSCopyWindowsWithOptionsAndTags_t = @convention(c) (Int32, UInt32, CFArray?, UInt32, UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<UInt64>?) -> Unmanaged<CFArray>?
typealias SLSGetWindowBounds_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
typealias SLSGetWindowLevel_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> CGError
typealias SLSGetWindowSubLevel_t = @convention(c) (Int32, UInt32) -> Int32
typealias SLSGetWindowAlpha_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Float>) -> CGError
typealias SLSGetWindowOwner_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> CGError
typealias SLSWindowIsOrderedIn_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<UInt8>) -> CGError
typealias SLSGetWindowTransform_t = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGAffineTransform>) -> CGError
typealias SLSConnectionGetPID_t = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> CGError
typealias SLSSpaceSetCompatID_t = @convention(c) (Int32, UInt64, Int32) -> CGError
typealias SLSSetWindowListWorkspace_t = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> CGError
typealias SLSMoveWindowsToManagedSpace_t = @convention(c) (Int32, CFArray, UInt64) -> Void

// MARK: - Process Serial Number APIs (for yabai-style focus)
// Note: ProcessSerialNumber is imported from Carbon.HIToolbox

typealias SLPSSetFrontProcessWithOptions_t = @convention(c) (
    UnsafePointer<ProcessSerialNumber>, UInt32, UInt32
) -> CGError

typealias SLPSPostEventRecordTo_t = @convention(c) (
    UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> CGError

typealias GetProcessForPID_t = @convention(c) (
    pid_t, UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

/// kCPSUserGenerated - mode flag for user-initiated focus
let kCPSUserGenerated: UInt32 = 0x200

// MARK: - Loaded Functions

private let _SLSMainConnectionID: SLSMainConnectionID_t? = loadSymbol("SLSMainConnectionID")
private let _SLSRegisterConnectionNotifyProc: SLSRegisterConnectionNotifyProc_t? = loadSymbol("SLSRegisterConnectionNotifyProc")
private let _SLSCopyManagedDisplays: SLSCopyManagedDisplays_t? = loadSymbol("SLSCopyManagedDisplays")
private let _SLSCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpaces_t? = loadSymbol("SLSCopyManagedDisplaySpaces")
private let _SLSManagedDisplayGetCurrentSpace: SLSManagedDisplayGetCurrentSpace_t? = loadSymbol("SLSManagedDisplayGetCurrentSpace")
private let _SLSCopyManagedDisplayForWindow: SLSCopyManagedDisplayForWindow_t? = loadSymbol("SLSCopyManagedDisplayForWindow")
private let _SLSSpaceGetType: SLSSpaceGetType_t? = loadSymbol("SLSSpaceGetType")
private let _SLSSpaceCopyName: SLSSpaceCopyName_t? = loadSymbol("SLSSpaceCopyName")
private let _SLSCopySpacesForWindows: SLSCopySpacesForWindows_t? = loadSymbol("SLSCopySpacesForWindows")
private let _SLSCopyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTags_t? = loadSymbol("SLSCopyWindowsWithOptionsAndTags")
private let _SLSGetWindowBounds: SLSGetWindowBounds_t? = loadSymbol("SLSGetWindowBounds")
private let _SLSGetWindowLevel: SLSGetWindowLevel_t? = loadSymbol("SLSGetWindowLevel")
private let _SLSGetWindowSubLevel: SLSGetWindowSubLevel_t? = loadSymbol("SLSGetWindowSubLevel")
private let _SLSGetWindowAlpha: SLSGetWindowAlpha_t? = loadSymbol("SLSGetWindowAlpha")
private let _SLSGetWindowOwner: SLSGetWindowOwner_t? = loadSymbol("SLSGetWindowOwner")
private let _SLSWindowIsOrderedIn: SLSWindowIsOrderedIn_t? = loadSymbol("SLSWindowIsOrderedIn")
private let _SLSGetWindowTransform: SLSGetWindowTransform_t? = loadSymbol("SLSGetWindowTransform")
private let _SLSConnectionGetPID: SLSConnectionGetPID_t? = loadSymbol("SLSConnectionGetPID")
private let _SLSSpaceSetCompatID: SLSSpaceSetCompatID_t? = loadSymbol("SLSSpaceSetCompatID")
private let _SLSSetWindowListWorkspace: SLSSetWindowListWorkspace_t? = loadSymbol("SLSSetWindowListWorkspace")
private let _SLSMoveWindowsToManagedSpace: SLSMoveWindowsToManagedSpace_t? = loadSymbol("SLSMoveWindowsToManagedSpace")

// SLPS APIs for yabai-style focus
private let _SLPSSetFrontProcessWithOptions: SLPSSetFrontProcessWithOptions_t? =
    loadSymbol("_SLPSSetFrontProcessWithOptions")
private let _SLPSPostEventRecordTo: SLPSPostEventRecordTo_t? =
    loadSymbol("SLPSPostEventRecordTo")

// GetProcessForPID from HIServices/Carbon
private let HIServicesFramework: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
}()

private let _GetProcessForPID: GetProcessForPID_t? = {
    guard let handle = HIServicesFramework else { return nil }
    guard let sym = dlsym(handle, "GetProcessForPID") else { return nil }
    return unsafeBitCast(sym, to: GetProcessForPID_t.self)
}()

// MARK: - Wrapper Functions

func SLSMainConnectionID() -> Int32 {
    return _SLSMainConnectionID?() ?? 0
}

func SLSRegisterConnectionNotifyProc(_ cid: Int32, _ handler: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void, _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError {
    return _SLSRegisterConnectionNotifyProc?(cid, handler, event, context) ?? .failure
}

func SLSCopyManagedDisplays(_ cid: Int32) -> CFArray? {
    return _SLSCopyManagedDisplays?(cid)?.takeRetainedValue()
}

func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray? {
    return _SLSCopyManagedDisplaySpaces?(cid)?.takeRetainedValue()
}

func SLSManagedDisplayGetCurrentSpace(_ cid: Int32, _ displayRef: CFString) -> UInt64 {
    return _SLSManagedDisplayGetCurrentSpace?(cid, displayRef) ?? 0
}

func SLSCopyManagedDisplayForWindow(_ cid: Int32, _ wid: UInt32) -> CFString? {
    return _SLSCopyManagedDisplayForWindow?(cid, wid)?.takeRetainedValue()
}

func SLSSpaceGetType(_ cid: Int32, _ sid: UInt64) -> Int32 {
    return _SLSSpaceGetType?(cid, sid) ?? 0
}

func SLSSpaceCopyName(_ cid: Int32, _ sid: UInt64) -> CFString? {
    return _SLSSpaceCopyName?(cid, sid)?.takeRetainedValue()
}

func SLSCopySpacesForWindows(_ cid: Int32, _ selector: Int32, _ windowList: CFArray) -> CFArray? {
    return _SLSCopySpacesForWindows?(cid, selector, windowList)?.takeRetainedValue()
}

func SLSCopyWindowsWithOptionsAndTags(_ cid: Int32, _ owner: UInt32, _ spaces: CFArray?, _ options: UInt32, _ setTags: UnsafeMutablePointer<UInt64>?, _ clearTags: UnsafeMutablePointer<UInt64>?) -> CFArray? {
    return _SLSCopyWindowsWithOptionsAndTags?(cid, owner, spaces, options, setTags, clearTags)?.takeRetainedValue()
}

func SLSGetWindowBounds(_ cid: Int32, _ wid: UInt32, _ frame: UnsafeMutablePointer<CGRect>) -> CGError {
    return _SLSGetWindowBounds?(cid, wid, frame) ?? .failure
}

func SLSGetWindowLevel(_ cid: Int32, _ wid: UInt32, _ level: UnsafeMutablePointer<Int32>) -> CGError {
    return _SLSGetWindowLevel?(cid, wid, level) ?? .failure
}

func SLSGetWindowSubLevel(_ cid: Int32, _ wid: UInt32) -> Int32 {
    return _SLSGetWindowSubLevel?(cid, wid) ?? 0
}

func SLSGetWindowAlpha(_ cid: Int32, _ wid: UInt32, _ alpha: UnsafeMutablePointer<Float>) -> CGError {
    return _SLSGetWindowAlpha?(cid, wid, alpha) ?? .failure
}

func SLSGetWindowOwner(_ cid: Int32, _ wid: UInt32, _ wcid: UnsafeMutablePointer<Int32>) -> CGError {
    return _SLSGetWindowOwner?(cid, wid, wcid) ?? .failure
}

func SLSWindowIsOrderedIn(_ cid: Int32, _ wid: UInt32, _ value: UnsafeMutablePointer<UInt8>) -> CGError {
    return _SLSWindowIsOrderedIn?(cid, wid, value) ?? .failure
}

func SLSGetWindowTransform(_ cid: Int32, _ wid: UInt32, _ transform: UnsafeMutablePointer<CGAffineTransform>) -> CGError {
    return _SLSGetWindowTransform?(cid, wid, transform) ?? .failure
}

func SLSConnectionGetPID(_ cid: Int32, _ pid: UnsafeMutablePointer<pid_t>) -> CGError {
    return _SLSConnectionGetPID?(cid, pid) ?? .failure
}

func SLSSpaceSetCompatID(_ cid: Int32, _ sid: UInt64, _ workspaceID: Int32) -> CGError {
    return _SLSSpaceSetCompatID?(cid, sid, workspaceID) ?? .failure
}

func SLSSetWindowListWorkspace(_ cid: Int32, _ windowList: UnsafePointer<UInt32>, _ count: Int32, _ workspaceID: Int32) -> CGError {
    return _SLSSetWindowListWorkspace?(cid, windowList, count, workspaceID) ?? .failure
}

func SLSMoveWindowsToManagedSpace(_ cid: Int32, _ windowList: CFArray, _ spaceID: UInt64) {
    _SLSMoveWindowsToManagedSpace?(cid, windowList, spaceID)
}

// MARK: - SLPS Focus API Wrappers

/// Get ProcessSerialNumber from PID (deprecated but still functional)
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus {
    _GetProcessForPID?(pid, psn) ?? -1
}

/// Set front process with window context (yabai-style)
func SLPSSetFrontProcessWithOptions(_ psn: UnsafePointer<ProcessSerialNumber>, _ wid: UInt32, _ mode: UInt32) -> CGError {
    _SLPSSetFrontProcessWithOptions?(psn, wid, mode) ?? .failure
}

/// Post event record to process for focus events (yabai-style)
func SLPSPostEventRecordTo(_ psn: UnsafePointer<ProcessSerialNumber>, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError {
    _SLPSPostEventRecordTo?(psn, bytes) ?? .failure
}

// MARK: - Event Type Constants

enum SLSEventType: UInt32 {
    case windowOrdered = 808
    case windowDestroyed = 804
    case missionControlEnter = 1204
    case missionControlExit = 1205
    case spaceCreated = 1327
    case spaceDestroyed = 1328
}

// MARK: - Space Type Enum

enum SpaceType: Int32 {
    case user = 0
    case system = 2
    case fullscreen = 4

    var description: String {
        switch self {
        case .user: return "user"
        case .system: return "system"
        case .fullscreen: return "fullscreen"
        }
    }
}

// MARK: - Helper Functions

extension CGError {
    var isSuccess: Bool {
        return self == .success
    }
}

// Helper to convert CFArray to Swift array
func cfArrayToSwiftArray<T>(_ cfArray: CFArray?) -> [T] {
    guard let cfArray = cfArray else { return [] }
    let count = CFArrayGetCount(cfArray)
    var result: [T] = []
    result.reserveCapacity(count)

    for i in 0..<count {
        if let value = CFArrayGetValueAtIndex(cfArray, i) {
            let retained = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
            if let typedValue = retained as? T {
                result.append(typedValue)
            }
        }
    }

    return result
}

// Helper to get app name from PID
func getAppNameForPID(_ pid: pid_t) -> String? {
    let runningApps = NSWorkspace.shared.runningApplications
    return runningApps.first(where: { $0.processIdentifier == pid })?.localizedName
}

// Helper to safely extract space ID from dictionary
func extractSpaceID(from dict: NSDictionary) -> UInt64? {
    // Try "ManagedSpaceID" first (older macOS)
    if let spaceID = dict["ManagedSpaceID"] as? NSNumber {
        return spaceID.uint64Value
    }
    // Try "id64" as fallback (macOS 13+)
    if let spaceID = dict["id64"] as? NSNumber {
        return spaceID.uint64Value
    }
    return nil
}

/// Create a CFArray of window IDs with proper CFNumber types for SkyLight API
/// This explicitly creates CFNumbers with kCFNumberSInt32Type, which is required
/// by SLSCopySpacesForWindows. Swift's automatic bridging doesn't guarantee the
/// correct type, causing the API to return empty arrays.
func createWindowIDArray(_ windowIDs: [UInt32]) -> CFArray {
    // Create CFNumber objects with explicit kCFNumberSInt32Type
    let cfNumbers: [CFNumber] = windowIDs.map { windowID in
        var mutableID = windowID
        return CFNumberCreate(nil, .sInt32Type, &mutableID)
    }

    // Create CFArray with proper callbacks
    // Note: CFArray retains the CFNumbers, so we don't need to manage their lifetime
    return cfNumbers as CFArray
}
