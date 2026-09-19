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

import ComposeCore
import ComposeRuntimeSPI

extension EngineServiceCreateRequest {
    static func mountConfiguration(_ resolved: ComposeResolvedMount) throws -> EngineCreateValue {
        let mount = resolved.definition
        guard let target = mount.target, target.hasPrefix("/"), mount.unsupportedFields?.isEmpty != false else {
            throw ComposeError.invalidProject("Gateway mount requires a normalized absolute target")
        }
        guard mount.fileOwnerUID == nil, mount.fileOwnerGID == nil else {
            throw ComposeError.unsupported("Gateway mount ownership requires a native extension")
        }
        let type = mount.type == "external-volume" ? "volume" : mount.type ?? "volume"
        var value: [String: EngineCreateValue] = [
            "Type": .string(type), "Target": .string(target), "ReadOnly": .boolean(mount.readOnly ?? false),
        ]
        value["Source"] = resolved.source.map(EngineCreateValue.string)
        switch type {
        case "bind":
            guard resolved.source?.hasPrefix("/") == true else {
                throw ComposeError.invalidProject("Prepared bind source must be absolute")
            }
            var bind: [String: EngineCreateValue] = [:]
            bind["Propagation"] = mount.bindPropagation.map(EngineCreateValue.string)
            bind["CreateMountpoint"] = mount.bindCreateHostPath.map(EngineCreateValue.boolean)
            value["BindOptions"] = .object(bind)
        case "volume":
            guard resolved.source?.isEmpty == false else {
                throw ComposeError.invalidProject("Prepared volume requires its allocated name")
            }
            var volume: [String: EngineCreateValue] = [:]
            volume["NoCopy"] = mount.volumeNoCopy.map(EngineCreateValue.boolean)
            volume["Subpath"] = mount.volumeSubpath.map(EngineCreateValue.string)
            volume["Labels"] = mount.volumeLabels.map(EngineCreateValue.dictionary)
            value["VolumeOptions"] = .object(volume)
        case "tmpfs":
            value["TmpfsOptions"] = try tmpfsConfiguration(mount)
        case "image":
            guard resolved.source?.isEmpty == false else {
                throw ComposeError.invalidProject("Prepared image mount requires its image source")
            }
            value["ReadOnly"] = .boolean(true)
            var image: [String: EngineCreateValue] = [:]
            image["Subpath"] = mount.imageSubpath.map(EngineCreateValue.string)
            value["ImageOptions"] = .object(image)
        default:
            throw ComposeError.unsupported("Unsupported prepared mount type \(type)")
        }
        return .object(value)
    }

    private static func tmpfsConfiguration(_ mount: ComposeMount) throws -> EngineCreateValue {
        var tmpfs: [String: EngineCreateValue] = [:]
        if let size = mount.tmpfsSize { tmpfs["SizeBytes"] = .integer(try byteQuantity(size)) }
        if let mode = mount.tmpfsMode {
            guard let parsed = Int64(mode, radix: 8), (0...0o7777).contains(parsed) else {
                throw ComposeError.invalidProject("Invalid tmpfs mode")
            }
            tmpfs["Mode"] = .integer(parsed)
        }
        return .object(tmpfs)
    }
}
