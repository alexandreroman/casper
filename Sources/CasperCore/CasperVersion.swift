/// The version `casper --version` reports when it runs unbundled.
///
/// The real version ships in `Casper.app`'s `Info.plist` as
/// `CFBundleShortVersionString`, which `Scripts/bundle-app.sh` substitutes at
/// packaging time. An unbundled binary — `swift run casper`, or the executable
/// invoked outside the app — has no Info.plist to read, and reports this instead.
public let casperFallbackVersion = "0.1.0"
