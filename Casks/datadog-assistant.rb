# Homebrew cask so `brew install --cask` works straight from this repo:
#
#   brew tap mxnyawi/datadog-assistant https://github.com/mxnyawi/datadog-assistant
#   brew install --cask datadog-assistant
#
# Tracks the latest GitHub release asset built by .github/workflows/release.yml.
cask "datadog-assistant" do
  version :latest
  sha256 :no_check

  url "https://github.com/mxnyawi/datadog-assistant/releases/latest/download/Datadog-Assistant.zip"
  name "Datadog Assistant"
  desc "Datadog monitors, incidents, and deploys in the macOS menu bar"
  homepage "https://github.com/mxnyawi/datadog-assistant"

  app "Datadog Assistant.app"

  zap trash: [
    "~/Library/Application Support/DatadogAssistant",
    "~/Library/Preferences/com.mxnyawi.datadog-assistant.plist",
  ]
end
