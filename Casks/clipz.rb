cask "clipz" do
  version "1.0.1"
  sha256 :no_check

  url "https://github.com/DuarteFaria/clipz/releases/download/v#{version}/Clipz.dmg"
  name "Clipz"
  desc "macOS clipboard manager"
  homepage "https://github.com/DuarteFaria/clipz"

  depends_on macos: ">= :ventura"

  app "Clipz.app"

  zap trash: "~/.clipz_history.json"
end
