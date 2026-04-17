# AFOLANUpload

AFOLANUpload is a lightweight local HTTP upload component for iOS apps.

## Usage

```objc
#import <AFOLANUpload/AFOLANUpload.h>

@property (nonatomic, strong) AFOLANUploadServer *uploadServer;

- (void)startUploadServer {
    self.uploadServer = [[AFOLANUploadServer alloc] initWithPort:8080];
    self.uploadServer.logHandler = ^(NSString *message) {
        NSLog(@"%@", message);
    };
    NSError *error = nil;
    if (![self.uploadServer start:&error]) {
        NSLog(@"AFOLANUpload start failed: %@", error);
        return;
    }
    NSLog(@"Open in browser: %@", self.uploadServer.serverURLString);
}
```

After starting, open the `serverURLString` in a browser on the same LAN, choose a video, and upload.
