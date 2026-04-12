platform :ios, '16.0'
use_frameworks!
inhibit_all_warnings!

def firebase_pods
  pod 'FirebaseAuth', '~> 10.0'
  pod 'FirebaseFirestore', '~> 10.0'
  pod 'FirebaseStorage', '~> 10.0'
  pod 'FirebaseFunctions', '~> 10.0'
  pod 'FirebaseAnalytics', '~> 10.0'
  pod 'FirebaseAppCheck', '~> 10.0'
end

target 'Somewhere' do
  firebase_pods
  pod 'GoogleSignIn', '~> 7.0'
  pod 'GooglePlaces', '~> 8.0'
  pod 'SDWebImageSwiftUI', '~> 2.0'
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
  end
end
