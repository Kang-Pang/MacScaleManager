#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
source_dir=${script_dir:h}
config_file=${source_dir}/config/app-adapters.json

jq empty "$config_file"

# Keep shortcut rules within the limits enforced by the app, so a hand-edited
# config cannot create an unexpectedly long or repeated shortcut sequence.
jq -e '
  ((.automaticScreenScaling // {"applications": false, "dock": false}) | (.applications | type == "boolean") and (.dock | type == "boolean")) and
  ((.managedApplicationRequiresQuit // {}) | all(.[]; type == "boolean")) and
  all(.immediateAdapters[]?;
    (.bundleIdentifier | type == "string" and length > 0) and
    ((.desktopZoomSteps // 2) >= 1 and (.desktopZoomSteps // 2) <= 6) and
    ((.launchDelaySeconds // 2) >= 0.5 and (.launchDelaySeconds // 2) <= 10) and
    ((.shortcutIntervalSeconds // 0.25) >= 0.1 and (.shortcutIntervalSeconds // 0.25) <= 1)
  ) and
  all(.windowLayoutAdapters[]?;
    (.bundleIdentifier | type == "string" and length > 0) and
    ((.windowSizePercent // 75) >= 30 and (.windowSizePercent // 75) <= 100) and
    ((.layoutStyle // "centered") | . == "centered" or . == "fillWithLeftGap") and
    ((.leftGapPercent // 10) >= 0 and (.leftGapPercent // 10) <= 40)
  )
' "$config_file" >/dev/null

swift build -c debug --package-path "$source_dir" >/dev/null
test_dir=${source_dir}/work/regression-tests
mkdir -p "$test_dir"
swiftc "$source_dir/Sources/MacScaleManager/WindowLayoutGeometry.swift" \
  "$source_dir/Sources/MacScaleManager/ConfigurationQuitPolicy.swift" \
  "$script_dir/tests/window-layout/main.swift" -o "$test_dir/layout-tests"
"$test_dir/layout-tests"
swiftc "$source_dir/Sources/MacScaleManager/ScreenScalingPolicy.swift" \
  "$script_dir/tests/screen-scaling/main.swift" -o "$test_dir/screen-tests"
"$test_dir/screen-tests"
swiftc "$source_dir/Sources/MacScaleManager/ScreenScalingPolicy.swift" \
  "$script_dir/tests/polling/main.swift" -o "$test_dir/polling-tests"
"$test_dir/polling-tests"
swiftc "$source_dir/Sources/MacScaleManager/ScreenScalingPolicy.swift" \
  "$source_dir/Sources/MacScaleManager/AutomaticWindowLayoutPolicy.swift" \
  "$source_dir/Sources/MacScaleManager/DockWorkAreaGeometry.swift" \
  "$script_dir/tests/window-following/main.swift" -o "$test_dir/window-following-tests"
"$test_dir/window-following-tests"
print 'MacScaleManager regression checks passed.'
