Pod::Spec.new do |s|
  s.name         = "AFOLANUpload"
  s.version      = "0.0.5"
  s.summary      = "Upload videos via LAN web page."
  s.description  = "A local HTTP upload component for AFOPlayer. It serves a browser page and receives selected video files over LAN."
  s.homepage     = "https://github.com/PangDuTechnology/AFOLANUpload.git"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "PangDu" => "xian312117@gmail.com" }
  s.platform     = :ios, "13.0"
  s.ios.deployment_target = "13.0"
  s.source       = { :git => "https://github.com/PangDuTechnology/AFOLANUpload.git", :tag => s.version.to_s }
  s.source_files = "AFOLANUpload/*.{h,m}"
  s.public_header_files = "AFOLANUpload/*.h"
  s.requires_arc = true
end
