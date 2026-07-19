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

extension ComposeOrchestrator {
    /// Returns Docker-compatible security options backed by generic runtime
    /// primitives. Unconfined seccomp/AppArmor and disabled SELinux labels are
    /// intentionally consumed here: guest workloads already run without those
    /// profiles or a SELinux label, so forwarding Docker-shaped no-ops to the
    /// generic runtime would add no enforcement. Unconfined system paths map
    /// to the generic guest path control. Other profiles remain rejected until
    /// the runtime can enforce them.
    func runtimeSecurityOptionArguments(service: ComposeService) throws -> [String] {
        let options = service.securityOpt ?? []
        let noNewPrivilegesOptions = Set([
            "no-new-privileges:true",
            "no-new-privileges:false",
            "no-new-privileges=true",
            "no-new-privileges=false",
        ])
        let noNewPrivilegesEnabledOption = "no-new-privileges"
        let unconfinedProfileOptions = Set([
            "seccomp=unconfined",
            "seccomp:unconfined",
            "apparmor=unconfined",
            "apparmor:unconfined",
        ])
        let disabledSELinuxLabelOptions = Set([
            "label=disable",
            "label:disable",
        ])
        let unconfinedSystemPathOptions = Set([
            "systempaths=unconfined",
            "systempaths:unconfined",
        ])
        var runtimeOptions: [String] = []

        for option in options where !option.isEmpty {
            if noNewPrivilegesOptions.contains(option) {
                runtimeOptions.append(option)
            } else if option == noNewPrivilegesEnabledOption {
                runtimeOptions.append("no-new-privileges:true")
            } else if unconfinedSystemPathOptions.contains(option) {
                runtimeOptions.append("systempaths=unconfined")
            } else if !(unconfinedProfileOptions.contains(option) || disabledSELinuxLabelOptions.contains(option)) {
                throw ComposeError.unsupported(
                    "service '\(service.name)' uses security_opt '\(option)'; only no-new-privileges (with optional :true|false or =true|false), systempaths=unconfined|systempaths:unconfined, seccomp=unconfined|seccomp:unconfined, apparmor=unconfined|apparmor:unconfined, or label=disable|label:disable is supported",
                )
            }
        }
        return runtimeOptions
    }
}
