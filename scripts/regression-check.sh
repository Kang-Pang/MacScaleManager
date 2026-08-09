#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
source_dir=${script_dir:h}
config_file=${source_dir}/config/app-adapters.json

jq empty "$config_file"

# Keep shortcut rules within the limits enforced by the app, so a hand-edited
# config cannot create an unexpectedly long or repeated shortcut sequence.
jq -e '
  all(.immediateAdapters[]?;
    (.bundleIdentifier | type == "string" and length > 0) and
    ((.desktopZoomSteps // 2) >= 1 and (.desktopZoomSteps // 2) <= 6) and
    ((.launchDelaySeconds // 2) >= 0.5 and (.launchDelaySeconds // 2) <= 10) and
    ((.shortcutIntervalSeconds // 0.25) >= 0.1 and (.shortcutIntervalSeconds // 0.25) <= 1)
  ) and
  all(.windowLayoutAdapters[]?;
    (.bundleIdentifier | type == "string" and length > 0) and
    ((.windowSizePercent // 75) >= 30 and (.windowSizePercent // 75) <= 100)
  )
' "$config_file" >/dev/null

swift build -c debug --package-path "$source_dir" >/dev/null
print 'MacScaleManager regression checks passed.'
