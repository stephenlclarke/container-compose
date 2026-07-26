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

func structuredTemplateLower(_ value: String) -> String {
    structuredTemplateMapScalars(value, with: structuredTemplateLowerScalar)
}

func structuredTemplateUpper(_ value: String) -> String {
    structuredTemplateMapScalars(value, with: structuredTemplateUpperScalar)
}

private func structuredTemplateMapScalars(
    _ value: String,
    with transform: (UnicodeScalar) -> UnicodeScalar,
) -> String {
    var output = ""
    for scalar in value.unicodeScalars {
        output.unicodeScalars.append(transform(scalar))
    }
    return output
}

private func structuredTemplateLowerScalar(
    _ scalar: UnicodeScalar,
) -> UnicodeScalar {
    if scalar.value == 0x0130 {
        return "i"
    }
    return structuredTemplateSimpleMapping(
        scalar,
        mapping: scalar.properties.lowercaseMapping,
    )
}

private func structuredTemplateUpperScalar(
    _ scalar: UnicodeScalar,
) -> UnicodeScalar {
    switch scalar.value {
    case 0x1F80 ... 0x1F87, 0x1F90 ... 0x1F97, 0x1FA0 ... 0x1FA7:
        UnicodeScalar(scalar.value + 8) ?? scalar
    case 0x1FB3, 0x1FC3, 0x1FF3:
        UnicodeScalar(scalar.value + 9) ?? scalar
    default:
        structuredTemplateSimpleMapping(
            scalar,
            mapping: scalar.properties.uppercaseMapping,
        )
    }
}

private func structuredTemplateSimpleMapping(
    _ scalar: UnicodeScalar,
    mapping: String,
) -> UnicodeScalar {
    let mappedScalars = mapping.unicodeScalars
    guard mappedScalars.count == 1, let mapped = mappedScalars.first else {
        return scalar
    }
    return mapped
}
