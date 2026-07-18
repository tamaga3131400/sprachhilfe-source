cask "sprachhilfe" do
  version "1.5.3"
  sha256 "167e8ab7fb34669fc29394f3dd335251b626c0ed77f03f36696766781d95ebc3"

  url "https://github.com/tamaga3131400/sprachhilfe/releases/download/v#{version}/Sprachhilfe-#{version}.dmg",
      verified: "github.com/tamaga3131400/sprachhilfe/"
  name "Sprachhilfe"
  desc "Speech-to-text and AI text processing for macOS"
  homepage "https://github.com/tamaga3131400/sprachhilfe"

  depends_on macos: ">= :sonoma"

  app "Sprachhilfe.app"

  zap trash: [
    "~/Library/Application Support/Sprachhilfe",
    "~/Library/Preferences/com.sprachhilfe.mac.plist",
    "~/Library/Group Containers/ZV5A9C5S5J.com.sprachhilfe.mac",
    "~/Library/Caches/com.sprachhilfe.mac",
    "/usr/local/bin/sprachhilfe",
  ]
end
