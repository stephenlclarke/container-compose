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

func structuredTemplateStringLiteral(
    _ token: String,
) -> DockerTemplateData? {
    let source = Array(token.utf8)
    guard source.count >= 2 else {
        return nil
    }
    if source.first == 0x60, source.last == 0x60 {
        let content = source.dropFirst().dropLast()
        guard !content.contains(0x60) else {
            return nil
        }
        return .byteString(content.filter { $0 != 0x0D })
    }
    guard source.first == 0x22, source.last == 0x22,
          let value = structuredTemplateInterpretedStringBytes(source)
    else {
        return nil
    }
    return .byteString(value)
}

private func structuredTemplateInterpretedStringBytes(
    _ source: [UInt8],
) -> [UInt8]? {
    var decoder = StructuredTemplateStringDecoder(source: source)
    return decoder.decode()
}

private struct StructuredTemplateStringDecoder {
    let source: [UInt8]
    let end: Int
    var output: [UInt8] = []
    var index = 1

    init(source: [UInt8]) {
        self.source = source
        end = source.count - 1
    }

    mutating func decode() -> [UInt8]? {
        while index < end {
            let byte = source[index]
            guard byte != 0x0A, byte != 0x0D, byte != 0x22 else {
                return nil
            }
            if byte == 0x5C {
                guard decodeEscape() else {
                    return nil
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private mutating func decodeEscape() -> Bool {
        guard index + 1 < end else {
            return false
        }
        let escape = source[index + 1]
        if let value = structuredTemplateSimpleEscapes[escape] {
            output.append(value)
            index += 2
            return true
        }
        if (0x30 ... 0x37).contains(escape) {
            return appendByteEscape(offset: 1, count: 3, radix: 8)
        }
        return switch escape {
        case 0x78:
            appendByteEscape(offset: 2, count: 2, radix: 16)
        case 0x75:
            appendUnicodeEscape(count: 4)
        case 0x55:
            appendUnicodeEscape(count: 8)
        default:
            false
        }
    }

    private mutating func appendByteEscape(
        offset: Int,
        count: Int,
        radix: UInt32,
    ) -> Bool {
        let start = index + offset
        let finish = start + count
        guard finish <= end,
              let value = structuredTemplateRadixValue(
                  source[start ..< finish],
                  radix: radix,
              ),
              value <= UInt8.max
        else {
            return false
        }
        output.append(UInt8(value))
        index = finish
        return true
    }

    private mutating func appendUnicodeEscape(
        count: Int,
    ) -> Bool {
        let start = index + 2
        let finish = start + count
        guard finish <= end,
              let value = structuredTemplateUnicodeEscape(
                  source[start ..< finish],
              )
        else {
            return false
        }
        output.append(contentsOf: value)
        index = finish
        return true
    }
}

private let structuredTemplateSimpleEscapes: [UInt8: UInt8] = [
    0x22: 0x22,
    0x5C: 0x5C,
    0x61: 0x07,
    0x62: 0x08,
    0x66: 0x0C,
    0x6E: 0x0A,
    0x72: 0x0D,
    0x74: 0x09,
    0x76: 0x0B,
]

private func structuredTemplateUnicodeEscape(
    _ digits: ArraySlice<UInt8>,
) -> [UInt8]? {
    guard let value = structuredTemplateRadixValue(digits, radix: 16),
          let scalar = UnicodeScalar(value)
    else {
        return nil
    }
    return Array(String(scalar).utf8)
}

private func structuredTemplateRadixValue(
    _ digits: ArraySlice<UInt8>,
    radix: UInt32,
) -> UInt32? {
    var value: UInt32 = 0
    for digit in digits {
        let component: UInt32
        switch digit {
        case 0x30 ... 0x39:
            component = UInt32(digit - 0x30)
        case 0x41 ... 0x46:
            component = UInt32(digit - 0x41 + 10)
        case 0x61 ... 0x66:
            component = UInt32(digit - 0x61 + 10)
        default:
            return nil
        }
        guard component < radix else {
            return nil
        }
        value = value * radix + component
    }
    return value
}
