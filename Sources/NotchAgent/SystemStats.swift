import Darwin
import Foundation
import IOKit
import IOKit.ps
import SwiftUI

/// CPU, GPU, memory, disk, battery and thermal state, sampled every two
/// seconds while the Stats page is open. Everything here is public API or
/// public IOKit registry properties; fan speed and temperatures need the
/// SMC and are left out.
@MainActor
final class SystemStats: ObservableObject {
    struct Snapshot {
        var cpu: Double = 0
        var gpu: Double?
        var memoryUsed: UInt64 = 0
        var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
        var diskFree: Int64 = 0
        var diskTotal: Int64 = 0
        var battery: (level: Double, charging: Bool)?
        var thermal: ProcessInfo.ThermalState = .nominal
    }

    @Published private(set) var snapshot = Snapshot()
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample() {
        var next = snapshot
        if let ticks = Self.cpuTicks() {
            if let previous = previousTicks, ticks.total > previous.total {
                next.cpu = Double(ticks.busy - previous.busy) / Double(ticks.total - previous.total)
            }
            previousTicks = ticks
        }
        next.gpu = Self.gpuUtilization()
        next.memoryUsed = Self.memoryUsed()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            next.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            next.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        next.battery = Self.battery()
        next.thermal = ProcessInfo.processInfo.thermalState
        snapshot = next
    }

    private static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        return (busy, total)
    }

    private static func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        // What Activity Monitor calls "Memory Used": app + wired + compressed.
        let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
        return (app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// The GPU driver publishes its own utilization in the IORegistry.
    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let stats = dictionary["PerformanceStatistics"] as? [String: Any],
                  let percent = stats["Device Utilization %"] as? NSNumber else { continue }
            best = max(best ?? 0, percent.doubleValue / 100)
        }
        return best
    }

    private static func battery() -> (level: Double, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (Double(current) / Double(maximum), description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
}

struct StatsView: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        let snapshot = stats.snapshot
        VStack(spacing: 10) {
            StatRow(icon: "cpu", label: "CPU", fraction: snapshot.cpu, value: percent(snapshot.cpu))
            if let gpu = snapshot.gpu {
                StatRow(icon: "square.stack.3d.up", label: "GPU", fraction: gpu, value: percent(gpu))
            }
            StatRow(icon: "memorychip", label: "Memory",
                    fraction: Double(snapshot.memoryUsed) / Double(max(1, snapshot.memoryTotal)),
                    value: "\(bytes(Int64(snapshot.memoryUsed))) of \(bytes(Int64(snapshot.memoryTotal)))")
            if let battery = snapshot.battery {
                StatRow(icon: battery.charging ? "battery.100.bolt" : "battery.75", label: "Battery",
                        fraction: battery.level, value: percent(battery.level) + (battery.charging ? " · charging" : ""))
            }
            Divider().overlay(.white.opacity(0.1))
            StatRow(icon: "internaldrive", label: "Macintosh HD",
                    fraction: 1 - Double(snapshot.diskFree) / Double(max(1, snapshot.diskTotal)),
                    value: "\(bytes(snapshot.diskFree)) free")
            HStack(spacing: 10) {
                Image(systemName: "thermometer.medium").frame(width: 18).foregroundStyle(Palette.mute)
                Text("Thermal").frame(width: 92, alignment: .leading)
                Spacer()
                Text(thermalLabel(snapshot.thermal)).foregroundStyle(thermalColor(snapshot.thermal))
            }
            .font(.system(size: 12.5, weight: .medium))
        }
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    private func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Cool"
        case .fair: "Warm"
        case .serious: "Hot, slowing down"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    private func thermalColor(_ state: ProcessInfo.ThermalState) -> Color {
        switch state {
        case .nominal: Palette.ok
        case .fair: Palette.warn
        default: .red
        }
    }
}

private struct StatRow: View {
    let icon: String
    let label: String
    let fraction: Double
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Palette.mute)
            Text(label).frame(width: 92, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule().fill(Palette.accent)
                        .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                        .animation(Motion.calm, value: fraction)
                }
            }
            .frame(height: 5)
            Text(value)
                .monospacedDigit()
                .frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .medium))
    }
}
