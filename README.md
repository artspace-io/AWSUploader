# AWSUploader

`AWSUploader` provides cancellable Amazon S3 uploads backed by temporary credentials and optional adaptive JPEG compression.

## Installation

```ruby
pod 'AWSUploader', :git => 'git@github.com:artspace-io/AWSUploader.git', :tag => '1.0.0'
```

Install only the upload core when image processing is not needed:

```ruby
pod 'AWSUploader/Core', :git => 'git@github.com:artspace-io/AWSUploader.git', :tag => '1.0.0'
```

## Upload

```swift
import AWSUploader

let uploader = AWSUploader(
    configuration: AWSUploadConfiguration(
        bucket: "my-bucket",
        region: "ap-northeast-1"
    )
) {
    let response = try await fetchTemporaryCredentials()
    return AWSTemporaryCredentials(
        accessKey: response.accessKey,
        secretKey: response.secretKey,
        sessionToken: response.sessionToken,
        expiration: response.expiration,
        keyPrefix: response.keyPrefix
    )
}

let task = uploader.upload(
    data: data,
    objectName: "photo.jpeg",
    contentType: "image/jpeg"
)
let result = try await task.value()
```

`value()` returns only after the S3 transfer completion handler reports success.

## Compress an image

```swift
let compressed = try await AWSImageCompressor().compress(image)
```

The default profile normalizes orientation, removes metadata, fills transparency with white, limits the long edge to 2048 pixels, and targets a JPEG size of 2 MB.

## Compress and upload

```swift
let task = uploader.upload(
    image: image,
    objectName: "photo.jpeg"
)
let result = try await task.value()
```

Retain the returned task to observe `progress` or call `cancel()`.

## Background URL session events

Forward background URL session events from the application delegate:

```swift
func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
) {
    AWSUploader.handleEvents(
        application: application,
        identifier: identifier,
        completionHandler: completionHandler
    )
}
```

Version 1 does not restore application-level upload task handles after the process is relaunched.
