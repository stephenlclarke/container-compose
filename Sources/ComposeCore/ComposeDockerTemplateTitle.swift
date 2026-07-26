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

func structuredTemplateTitle(_ value: String) -> String {
    var output = ""
    var previous: UnicodeScalar = " "
    for scalar in value.unicodeScalars {
        let mapped = structuredTemplateIsTitleSeparator(previous)
            ? structuredTemplateTitleScalar(scalar)
            : scalar
        output.unicodeScalars.append(mapped)
        previous = scalar
    }
    return output
}

private func structuredTemplateTitleScalar(
    _ scalar: UnicodeScalar,
) -> UnicodeScalar {
    let mapping = scalar.properties.titlecaseMapping.unicodeScalars
    guard mapping.count == 1, let mapped = mapping.first else {
        return scalar
    }
    return mapped
}

private func structuredTemplateIsTitleSeparator(
    _ scalar: UnicodeScalar,
) -> Bool {
    if scalar.value <= 0x7F {
        return !structuredTemplateIsASCIIWordScalar(scalar)
    }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
         .modifierLetter, .otherLetter, .decimalNumber:
        return false
    default:
        return scalar.properties.isWhitespace
    }
}

private func structuredTemplateIsASCIIWordScalar(
    _ scalar: UnicodeScalar,
) -> Bool {
    switch scalar.value {
    case 0x30 ... 0x39, 0x41 ... 0x5A, 0x5F, 0x61 ... 0x7A:
        true
    default:
        false
    }
}
