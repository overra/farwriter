#!/usr/bin/env swift

import Foundation
import IOKit.hid

private let appleVendorID = 0x004c
private let modelName = CommandLine.arguments
    .first { $0.hasPrefix("--model=") }
    .map { String($0.dropFirst("--model=".count)) } ?? "a2540"
private let selectedModel: (productID: Int, confirmationFlag: String) = {
    switch modelName {
    case "a2540": return (0x0314, "--confirm-a2540-feature-write")
    case "a2854": return (0x0315, "--confirm-a2854-feature-write")
    default:
        fputs("usage-error\t--model must be a2540 or a2854\n", stderr)
        exit(2)
    }
}()
private let captureRawReports = CommandLine.arguments.contains("--raw-reports")
private let describeReports = CommandLine.arguments.contains("--describe-reports")
private let planActivation = CommandLine.arguments.contains("--plan-activation")
private let activateMicrophone = CommandLine.arguments.contains("--activate-mic")
private let activationConfirmed = CommandLine.arguments.contains(
    selectedModel.confirmationFlag
)
private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []

private func buttonKey(page: UInt32, usage: UInt32) -> UInt64 {
    UInt64(page) << 32 | UInt64(usage)
}

private let buttonNames: [UInt64: String] = [
    buttonKey(page: 0x01, usage: 0x40): "menu",
    buttonKey(page: 0x01, usage: 0x86): "menu",
    buttonKey(page: 0x09, usage: 0x01): "select",
    buttonKey(page: 0x0c, usage: 0x04): "siri",
    buttonKey(page: 0x0c, usage: 0x30): "power",
    buttonKey(page: 0x0c, usage: 0x40): "menu",
    buttonKey(page: 0x0c, usage: 0x41): "select",
    buttonKey(page: 0x0c, usage: 0x42): "ring-up",
    buttonKey(page: 0x0c, usage: 0x43): "ring-down",
    buttonKey(page: 0x0c, usage: 0x44): "ring-left",
    buttonKey(page: 0x0c, usage: 0x45): "ring-right",
    buttonKey(page: 0x0c, usage: 0x60): "tv",
    buttonKey(page: 0x0c, usage: 0x80): "select",
    buttonKey(page: 0x0c, usage: 0xb5): "next-track",
    buttonKey(page: 0x0c, usage: 0xb6): "previous-track",
    buttonKey(page: 0x0c, usage: 0xcd): "play-pause",
    buttonKey(page: 0x0c, usage: 0xe2): "mute",
    buttonKey(page: 0x0c, usage: 0xe9): "volume-up",
    buttonKey(page: 0x0c, usage: 0xea): "volume-down",
    buttonKey(page: 0x0c, usage: 0x223): "tv",
    buttonKey(page: 0x0c, usage: 0x224): "back"
]

private func buttonName(page: UInt32, usage: UInt32) -> String? {
    page == 0xff00 ? "siri" : buttonNames[buttonKey(page: page, usage: usage)]
}

private func inputValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess else { return }

    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let integerValue = IOHIDValueGetIntegerValue(value)
    let state = integerValue == 0 ? "released" : "pressed"
    let name = buttonName(page: page, usage: usage) ?? "unmapped"

    print(String(
        format: "event\t%@\t%@\tpage=0x%04x\tusage=0x%04x\tvalue=%lld",
        name,
        state,
        page,
        usage,
        integerValue
    ))
    fflush(stdout)
}

private func inputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard result == kIOReturnSuccess else { return }

    // Length and timing are enough to detect an audio-shaped stream. Deliberately
    // do not print or retain report bytes, which may contain microphone audio.
    print("report\ttype=\(type.rawValue)\tid=\(reportID)\tlength=\(reportLength)")
    fflush(stdout)
}

private func registerReportCapture(device: IOHIDDevice) {
    let capacity = 512
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    buffer.initialize(repeating: 0, count: capacity)
    reportBuffers.append(buffer)
    IOHIDDeviceRegisterInputReportCallback(
        device,
        buffer,
        capacity,
        inputReportCallback,
        nil
    )
}

private func printReportDescriptors(
    page: Int,
    usage: Int,
    elements: [IOHIDElement]
) {
    var descriptors: Set<String> = []
    for element in elements {
        let type = IOHIDElementGetType(element).rawValue
        let reportID = IOHIDElementGetReportID(element)
        let bits = IOHIDElementGetReportSize(element)
            * IOHIDElementGetReportCount(element)
        descriptors.insert("type=\(type) id=\(reportID) bytes=\((bits + 7) / 8)")
    }
    for descriptor in descriptors.sorted() {
        print("descriptor\tpage=\(page)\tusage=\(usage)\t\(descriptor)")
    }
}

private func hasActivationFeature(elements: [IOHIDElement]) -> Bool {
    elements.contains { element in
        IOHIDElementGetType(element) == kIOHIDElementTypeFeature
            && IOHIDElementGetReportID(element) == 0xff
            && IOHIDElementGetReportSize(element)
                * IOHIDElementGetReportCount(element) >= 8
    }
}

private func scheduleActivationWrite(device: IOHIDDevice, page: Int, usage: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        var enable: UInt8 = 0xaf
        let writeResult = withUnsafeMutablePointer(to: &enable) { pointer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                0xff,
                pointer,
                1
            )
        }
        print(String(
            format: "activation-result\tpage=0x%04x\tusage=0x%04x"
                + "\tstatus=0x%08x",
            page,
            usage,
            writeResult
        ))
        fflush(stdout)
    }
}

private func handleActivation(
    device: IOHIDDevice,
    page: Int,
    usage: Int,
    elements: [IOHIDElement]
) {
    guard planActivation || activateMicrophone,
          hasActivationFeature(elements: elements) else { return }

    print(String(
        format: "activation-target\tpage=0x%04x\tusage=0x%04x"
            + "\treport=0xff\tbytes=1\tvalue=0xaf\tmode=%@",
        page,
        usage,
        activateMicrophone ? "live" : "dry-run"
    ))
    if activateMicrophone {
        scheduleActivationWrite(device: device, page: page, usage: usage)
    }
}

private func deviceMatchedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess else { return }

    let page = IOHIDDeviceGetProperty(
        device,
        kIOHIDPrimaryUsagePageKey as CFString
    ) as? Int ?? -1
    let usage = IOHIDDeviceGetProperty(
        device,
        kIOHIDPrimaryUsageKey as CFString
    ) as? Int ?? -1
    let elements = IOHIDDeviceCopyMatchingElements(
        device,
        nil,
        IOOptionBits(kIOHIDOptionsTypeNone)
    ) as? [IOHIDElement] ?? []

    print(String(format: "interface\tpage=0x%04x\tusage=0x%04x", page, usage))
    if captureRawReports || activateMicrophone {
        registerReportCapture(device: device)
    }
    if describeReports {
        printReportDescriptors(page: page, usage: usage, elements: elements)
    }
    handleActivation(device: device, page: page, usage: usage, elements: elements)
    fflush(stdout)
}

if activateMicrophone && !activationConfirmed {
    fputs(
        "activation-error\tmissing \(selectedModel.confirmationFlag)\n",
        stderr
    )
    exit(2)
}

let seconds = CommandLine.arguments.dropFirst().compactMap(Double.init).first ?? 20
let manager = IOHIDManagerCreate(
    kCFAllocatorDefault,
    IOOptionBits(kIOHIDOptionsTypeNone)
)

let matching: [String: Any] = [
    kIOHIDVendorIDKey as String: appleVendorID,
    kIOHIDProductIDKey as String: selectedModel.productID
]

IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, nil)
IOHIDManagerRegisterInputValueCallback(manager, inputValueCallback, nil)
IOHIDManagerScheduleWithRunLoop(
    manager,
    CFRunLoopGetCurrent(),
    CFRunLoopMode.defaultMode.rawValue
)

let openResult = IOHIDManagerOpen(
    manager,
    IOOptionBits(kIOHIDOptionsTypeNone)
)

guard openResult == kIOReturnSuccess else {
    fputs(String(format: "open-error\t0x%08x\n", openResult), stderr)
    exit(1)
}

print("ready\tmodel=\(modelName)\tseconds=\(seconds)")
fflush(stdout)

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    CFRunLoopStop(CFRunLoopGetMain())
}

CFRunLoopRun()
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("done")
