//
//  AFOLANUploadServer.h
//  AFOLANUpload
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void(^AFOLANUploadLogHandler)(NSString *message);

@interface AFOLANUploadServer : NSObject

@property (nonatomic, copy, readonly) NSString *serverURLString;
@property (nonatomic, copy) NSString *uploadDirectoryPath;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
@property (nonatomic, copy, nullable) AFOLANUploadLogHandler logHandler;

- (instancetype)initWithPort:(uint16_t)port;
- (BOOL)start:(NSError * _Nullable * _Nullable)error;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
