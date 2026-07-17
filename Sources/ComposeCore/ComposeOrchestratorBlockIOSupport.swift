//===----------------------------------------------------------------------===//
// Copyright © 2026 container-compose project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import ContainerizationOCI
import Foundation

extension ComposeOrchestrator {
    /// Converts Compose `blkio_config` into typed OCI block I/O runtime data.
    func runtimeBlockIO(service: ComposeService) throws -> LinuxBlockIO? {
        guard let blkio = service.blkioConfig else {
            return nil
        }

        return try LinuxBlockIO(
            weight: runtimeBlockIOWeight(blkio, serviceName: service.name),
            leafWeight: nil,
            weightDevice: runtimeBlockIOWeightDevices(blkio, serviceName: service.name),
            throttleReadBpsDevice: blockIOThrottleDevices(
                blkio.deviceReadBps,
                field: "blkio_config.device_read_bps",
                serviceName: service.name,
                parseRate: blockIOByteRate,
            ),
            throttleWriteBpsDevice: blockIOThrottleDevices(
                blkio.deviceWriteBps,
                field: "blkio_config.device_write_bps",
                serviceName: service.name,
                parseRate: blockIOByteRate,
            ),
            throttleReadIOPSDevice: blockIOThrottleDevices(
                blkio.deviceReadIOps,
                field: "blkio_config.device_read_iops",
                serviceName: service.name,
                parseRate: blockIOIntegerRate,
            ),
            throttleWriteIOPSDevice: blockIOThrottleDevices(
                blkio.deviceWriteIOps,
                field: "blkio_config.device_write_iops",
                serviceName: service.name,
                parseRate: blockIOIntegerRate,
            ),
        )
    }

    private func runtimeBlockIOWeight(
        _ blkio: ComposeBlkioConfig,
        serviceName: String,
    ) throws -> UInt16? {
        guard let rawWeight = blkio.weight else {
            return nil
        }
        try validateBlockIOWeight(rawWeight, serviceName: serviceName, field: "blkio_config.weight")
        return UInt16(rawWeight)
    }

    private func runtimeBlockIOWeightDevices(
        _ blkio: ComposeBlkioConfig,
        serviceName: String,
    ) throws -> [LinuxWeightDevice] {
        try (blkio.weightDevice ?? []).map { device in
            try validateBlockIODevicePath(
                device.path,
                serviceName: serviceName,
                field: "blkio_config.weight_device.path",
            )
            try validateBlockIOWeight(
                device.weight,
                serviceName: serviceName,
                field: "blkio_config.weight_device.weight",
            )
            let id = try blockIODeviceID(device.path, serviceName: serviceName)
            return LinuxWeightDevice(
                major: id.major,
                minor: id.minor,
                weight: UInt16(device.weight),
                leafWeight: nil,
            )
        }
    }

    func blockIOThrottleDevices(
        _ devices: [ComposeBlkioThrottleDevice]?,
        field: String,
        serviceName: String,
        parseRate: (String, String, String) throws -> UInt64,
    ) throws -> [LinuxThrottleDevice] {
        try (devices ?? []).map { device in
            try validateBlockIODevicePath(device.path, serviceName: serviceName, field: "\(field).path")
            let id = try blockIODeviceID(device.path, serviceName: serviceName)
            let rate = try parseRate(device.rate, "\(field).rate", serviceName)
            return LinuxThrottleDevice(major: id.major, minor: id.minor, rate: rate)
        }
    }

    func blockIODeviceID(_ value: String, serviceName: String) throws -> (major: Int64, minor: Int64) {
        if value.hasPrefix("/") {
            var info = stat()
            guard stat(value, &info) == 0 else {
                throw ComposeError.invalidProject(
                    "service '\(serviceName)' uses blkio_config device path '\(value)', but the path could not be statted",
                )
            }
            let rawDevice = UInt32(bitPattern: info.st_rdev)
            return (Int64((rawDevice >> 24) & 0xFF), Int64(rawDevice & 0x00FF_FFFF))
        }

        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let major = Int64(parts[0]), let minor = Int64(parts[1]) else {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses blkio_config device '\(value)'; "
                    + "device must be an absolute path or '<major>:<minor>'",
            )
        }
        return (major, minor)
    }

    func blockIOByteRate(_ value: String, field: String, serviceName: String) throws -> UInt64 {
        let bytes: Double
        do {
            bytes = try Measurement<UnitInformationStorage>.parse(parsing: value).converted(to: .bytes).value
        } catch {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses \(field) '\(value)'; block I/O byte rates must be sizes",
            )
        }
        guard bytes.isFinite, bytes >= 0, bytes <= Double(UInt64.max) else {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses \(field) '\(value)'; block I/O byte rate is outside the supported range",
            )
        }
        return UInt64(bytes)
    }

    func blockIOIntegerRate(_ value: String, field: String, serviceName: String) throws -> UInt64 {
        guard let rate = UInt64(value) else {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses \(field) '\(value)'; "
                    + "block I/O throttle rates must be non-negative integers",
            )
        }
        return rate
    }

    func appendThrottleArguments(
        _ devices: [ComposeBlkioThrottleDevice]?,
        key: String,
        field: String,
        serviceName: String,
        to result: inout [String],
    ) throws {
        for device in devices ?? [] {
            try validateBlockIODevicePath(device.path, serviceName: serviceName, field: "\(field).path")
            guard UInt64(device.rate) != nil else {
                throw ComposeError.invalidProject(
                    "service '\(serviceName)' uses \(field).rate '\(device.rate)'; "
                        + "block I/O throttle rates must be non-negative integers",
                )
            }
            result.append("device=\(device.path),\(key)=\(device.rate)")
        }
    }

    func validateBlockIOWeight(_ weight: Int, serviceName: String, field: String) throws {
        guard (10 ... 1000).contains(weight) else {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses \(field) \(weight); block I/O weight must be between 10 and 1000",
            )
        }
    }

    func validateBlockIODevicePath(_ path: String, serviceName: String, field: String) throws {
        guard !path.isEmpty else {
            throw ComposeError.invalidProject("service '\(serviceName)' uses \(field) with an empty device path")
        }
        if path.contains(",") {
            throw ComposeError.invalidProject(
                "service '\(serviceName)' uses \(field) '\(path)'; "
                    + "block I/O device paths must not contain commas",
            )
        }
    }
}
