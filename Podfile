platform :ios, '16.0'
use_frameworks!
inhibit_all_warnings!

def firebase_pods
  pod 'FirebaseAuth', '~> 11.0'
  pod 'FirebaseFirestore', '~> 11.0'
  pod 'FirebaseStorage', '~> 11.0'
  pod 'FirebaseFunctions', '~> 11.0'
  pod 'FirebaseAnalytics', '~> 11.0'
  pod 'FirebaseAppCheck', '~> 11.0'
end

target 'Somewhere' do
  firebase_pods
  pod 'GoogleSignIn', '~> 8.0'
  pod 'GooglePlaces', '~> 9.0'
  pod 'SDWebImageSwiftUI', '~> 3.0'
end

target 'SomewhereTests' do
  inherit! :search_paths
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      config.build_settings['SWIFT_VERSION'] = '5.9'
      config.build_settings['BUILD_LIBRARY_FOR_DISTRIBUTION'] = 'NO'
    end

    # Fix unsupported '-O' flag in all pods (BoringSSL, abseil, leveldb) for Xcode 15+
    next unless target.respond_to?(:source_build_phase)
    target.source_build_phase.files.each do |file|
      if file.settings && file.settings['COMPILER_FLAGS']
        flags = file.settings['COMPILER_FLAGS'].split
        flags.reject! { |flag| flag == '-O' }
        file.settings['COMPILER_FLAGS'] = flags.join(' ')
      end
    end
  end
end
