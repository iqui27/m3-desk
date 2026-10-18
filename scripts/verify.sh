#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# CLT macOS 27 ships Testing but swiftbuild may not auto-discover its macro plugin.
compiler=$(xcrun --find swift)
plugin="$(dirname "$compiler")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=()
if [[ -f "$plugin" ]]; then flags=(-Xswiftc -load-plugin-library -Xswiftc "$plugin"); fi
swift test --build-system swiftbuild --scratch-path "${M3_DESK_BUILD_DIR:-.build}" --enable-swift-testing --disable-xctest "${flags[@]}"
swift run --build-system swiftbuild --scratch-path "${M3_DESK_BUILD_DIR:-.build}" M3DeskSmoke
