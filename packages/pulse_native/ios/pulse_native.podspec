#
# Local plugin for Pulse. Not published; consumed by path dependency.
#
Pod::Spec.new do |s|
  s.name             = 'pulse_native'
  s.version          = '0.0.1'
  s.summary          = 'Keychain token storage and NWPathMonitor reachability for Pulse.'
  s.description      = <<-DESC
Two platform channels: a MethodChannel backing the auth token with the iOS
Keychain, and an EventChannel streaming NWPathMonitor reachability changes.
                       DESC
  s.homepage         = 'https://example.com/pulse'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Pulse' => 'pulse@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
