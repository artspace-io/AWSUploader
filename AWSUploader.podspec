Pod::Spec.new do |spec|
  spec.name = 'AWSUploader'
  spec.version = '1.0.0'
  spec.summary = 'S3 uploads with temporary credentials and adaptive image compression.'
  spec.description = <<-DESC
    AWSUploader wraps AWSS3TransferUtility with async temporary credential refresh,
    cancellable uploads, progress reporting, and optional adaptive JPEG compression.
  DESC
  spec.homepage = 'https://github.com/artspace-io/AWSUploader'
  spec.license = { :type => 'Commercial', :text => 'Copyright artspace-io. All rights reserved.' }
  spec.author = { 'artspace-io' => 'ios@artspace.io' }
  spec.source = { :git => 'git@github.com:artspace-io/AWSUploader.git', :tag => spec.version.to_s }
  spec.platform = :ios, '16.0'
  spec.swift_version = '5.0'
  spec.default_subspecs = 'Core', 'Image'

  spec.subspec 'Core' do |core|
    core.source_files = 'Sources/Core/**/*.swift'
    core.dependency 'AWSS3', '~> 2.41.0'
  end

  spec.subspec 'Image' do |image|
    image.source_files = 'Sources/Image/**/*.swift'
    image.dependency 'AWSUploader/Core'
    image.frameworks = 'UIKit', 'ImageIO', 'CoreGraphics'
  end

  spec.test_spec 'Tests' do |tests|
    tests.source_files = 'Tests/**/*.swift'
    tests.dependency 'AWSUploader/Core'
    tests.dependency 'AWSUploader/Image'
  end
end
