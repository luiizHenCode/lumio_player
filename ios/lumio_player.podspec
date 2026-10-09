#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint lumio_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'lumio_player'
  s.version          = '0.1.0'
  s.summary          = 'Native AVPlayer playback and Flutter textures for iOS.'
  s.description      = <<-DESC
Direct AVPlayer audio/video playback with shared state events, diagnostics,
Flutter textures, and network, file, and bundled Flutter asset sources.
                       DESC

  s.license          = { :file => '../LICENSE' }
  s.author           = 'Lumio Player maintainers'
  s.source           = { :path => '.' }
  s.source_files = 'lumio_player/Sources/lumio_player/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.frameworks = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'QuartzCore', 'UIKit'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'lumio_player_privacy' => ['lumio_player/Sources/lumio_player/PrivacyInfo.xcprivacy']}
end
