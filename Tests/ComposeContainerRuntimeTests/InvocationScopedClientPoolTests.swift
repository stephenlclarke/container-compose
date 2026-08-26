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

@testable import ComposeContainerRuntime
import Foundation
import Synchronization
import Testing

@Suite("Invocation-scoped Container clients")
struct InvocationScopedClientPoolTests {
    @Test
    func `concurrent control requests construct one shared client`() async {
        let constructions = Mutex(0)
        let pool = InvocationScopedClientPool {
            constructions.withLock { $0 += 1 }
            return UUID()
        }

        let values = await withTaskGroup(of: UUID.self, returning: [UUID].self) { group in
            for _ in 0 ..< 100 {
                group.addTask { pool.control() }
            }
            var values = [UUID]()
            for await value in group {
                values.append(value)
            }
            return values
        }

        #expect(Set(values).count == 1)
        #expect(constructions.withLock { $0 } == 1)
    }

    @Test
    func `session clients remain connection isolated`() {
        let pool = InvocationScopedClientPool(create: UUID.init)

        let control = pool.control()
        #expect(pool.control() == control)
        #expect(pool.session() != control)
        #expect(pool.session() != pool.session())
    }

    @Test
    func `dependency construction does not activate an XPC client`() {
        let constructions = Mutex(0)

        _ = ComposeContainerRuntime.dependencies(makeContainerClient: {
            constructions.withLock { $0 += 1 }
            fatalError("the Container client must remain lazy")
        })

        #expect(constructions.withLock { $0 } == 0)
    }
}
