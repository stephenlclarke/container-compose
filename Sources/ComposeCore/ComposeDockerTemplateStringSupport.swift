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

func structuredTemplateGoStringBytes(
    _ value: DockerTemplateData,
) -> [UInt8]? {
    switch value {
    case let .byteString(bytes):
        bytes
    case let .lookupObject(_, display):
        Array(display.utf8)
    case let .string(string):
        Array(string.utf8)
    case .array, .boolean, .integer, .null, .object, .record:
        nil
    }
}

func structuredTemplateUTF8Sequences(
    _ value: [UInt8],
) -> [[UInt8]] {
    var sequences: [[UInt8]] = []
    var index = 0
    while index < value.count {
        let length = structuredTemplateUTF8SequenceLength(value, at: index)
        sequences.append(Array(value[index ..< index + length]))
        index += length
    }
    return sequences
}

private func structuredTemplateUTF8SequenceLength(
    _ value: [UInt8],
    at index: Int,
) -> Int {
    let first = value[index]
    func continuation(_ offset: Int, in range: ClosedRange<UInt8> = 0x80 ... 0xBF) -> Bool {
        let position = index + offset
        return position < value.count && range.contains(value[position])
    }
    switch first {
    case 0x00 ... 0x7F:
        return 1
    case 0xC2 ... 0xDF where continuation(1):
        return 2
    case 0xE0 where continuation(1, in: 0xA0 ... 0xBF) && continuation(2),
         0xE1 ... 0xEC where continuation(1) && continuation(2),
         0xED where continuation(1, in: 0x80 ... 0x9F) && continuation(2),
         0xEE ... 0xEF where continuation(1) && continuation(2):
        return 3
    case 0xF0 where continuation(1, in: 0x90 ... 0xBF) && continuation(2) && continuation(3),
         0xF1 ... 0xF3 where continuation(1) && continuation(2) && continuation(3),
         0xF4 where continuation(1, in: 0x80 ... 0x8F) && continuation(2) && continuation(3):
        return 4
    default:
        return 1
    }
}

func structuredTemplateSeparatorIndex(
    in value: [UInt8],
    separator: [UInt8],
    from start: Int,
) -> Int? {
    guard start <= value.count - separator.count else {
        return nil
    }
    for index in start ... value.count - separator.count
        where value[index ..< index + separator.count].elementsEqual(separator)
    {
        return index
    }
    return nil
}
