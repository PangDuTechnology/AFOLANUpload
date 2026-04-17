//
//  AFOLANUploadServer.m
//  AFOLANUpload
//

#import "AFOLANUploadServer.h"

#import <arpa/inet.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <unistd.h>

double AFOLANUploadVersionNumber = 0.0;
const unsigned char AFOLANUploadVersionString[] = "0.0.1";

@interface AFOLANUploadClientContext : NSObject
@property (nonatomic, assign) int clientFD;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, assign) BOOL headerParsed;
@property (nonatomic, assign) NSUInteger bodyOffset;
@property (nonatomic, assign) NSUInteger contentLength;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *requestPath;
@property (nonatomic, copy) NSString *query;
@end

@implementation AFOLANUploadClientContext
@end

@interface AFOLANUploadServer ()
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, copy, readwrite) NSString *serverURLString;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, assign) int listenFD;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_queue_t serverQueue;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, AFOLANUploadClientContext *> *clients;
@property (nonatomic, strong, nullable) NSNetService *bonjourService;
@end

@implementation AFOLANUploadServer

- (instancetype)initWithPort:(uint16_t)port {
    self = [super init];
    if (self) {
        _port = port;
        _listenFD = -1;
        _serverQueue = dispatch_queue_create("com.afo.lanupload.server", DISPATCH_QUEUE_SERIAL);
        _clients = [NSMutableDictionary dictionary];
        _uploadDirectoryPath = [self.class defaultUploadDirectory];
        _serverURLString = @"";
        _running = NO;
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    __block NSError *startError = nil;
    __block BOOL success = NO;
    dispatch_sync(self.serverQueue, ^{
        if (self.running) {
            success = YES;
            return;
        }
        success = [self startLocked:&startError];
    });
    if (!success && error) {
        *error = startError;
    }
    return success;
}

- (void)stop {
    dispatch_sync(self.serverQueue, ^{
        if (!self.running) {
            return;
        }
        [self stopLocked];
    });
}

#pragma mark - Private

- (BOOL)startLocked:(NSError **)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        return NO;
    }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    fcntl(fd, F_SETFL, O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(self.port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        close(fd);
        return NO;
    }

    if (listen(fd, 32) < 0) {
        if (error) {
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        }
        close(fd);
        return NO;
    }

    struct sockaddr_in actualAddr;
    socklen_t actualLen = sizeof(actualAddr);
    memset(&actualAddr, 0, sizeof(actualAddr));
    getsockname(fd, (struct sockaddr *)&actualAddr, &actualLen);
    self.port = ntohs(actualAddr.sin_port);
    self.listenFD = fd;

    __weak typeof(self) weakSelf = self;
    self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.serverQueue);
    dispatch_source_set_event_handler(self.acceptSource, ^{
        [weakSelf acceptClientsLocked];
    });
    dispatch_source_set_cancel_handler(self.acceptSource, ^{
        close(fd);
    });
    dispatch_resume(self.acceptSource);

    self.running = YES;
    self.serverURLString = [NSString stringWithFormat:@"http://%@:%hu", [self.class localIPAddress], self.port];
    [self log:[NSString stringWithFormat:@"AFOLANUpload started: %@", self.serverURLString]];

    // 发布 Bonjour 服务以触发 iOS 14+「本地网络」权限弹窗，并让设置-本地网络里出现开关。
    // 需要 Info.plist 配置 NSLocalNetworkUsageDescription + NSBonjourServices（_http._tcp）。
    self.bonjourService = [[NSNetService alloc] initWithDomain:@"local." type:@"_http._tcp." name:@"AFO LAN Upload" port:self.port];
    [self.bonjourService publish];
    return YES;
}

- (void)stopLocked {
    if (self.bonjourService) {
        [self.bonjourService stop];
        self.bonjourService = nil;
    }
    for (NSNumber *key in self.clients.allKeys) {
        AFOLANUploadClientContext *context = self.clients[key];
        if (context.readSource) {
            dispatch_source_cancel(context.readSource);
        } else if (context.clientFD >= 0) {
            close(context.clientFD);
        }
    }
    [self.clients removeAllObjects];

    if (self.acceptSource) {
        dispatch_source_cancel(self.acceptSource);
        self.acceptSource = nil;
    } else if (self.listenFD >= 0) {
        close(self.listenFD);
    }
    self.listenFD = -1;
    self.running = NO;
    self.serverURLString = @"";
    [self log:@"AFOLANUpload stopped"];
}

- (void)acceptClientsLocked {
    if (self.listenFD < 0) {
        return;
    }
    while (YES) {
        struct sockaddr_in peerAddr;
        socklen_t peerLen = sizeof(peerAddr);
        int clientFD = accept(self.listenFD, (struct sockaddr *)&peerAddr, &peerLen);
        if (clientFD < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break;
            }
            [self log:[NSString stringWithFormat:@"AFOLANUpload accept failed: %d", errno]];
            break;
        }
        [self setupClientLocked:clientFD];
    }
}

- (void)setupClientLocked:(int)clientFD {
    fcntl(clientFD, F_SETFL, O_NONBLOCK);
    AFOLANUploadClientContext *context = [AFOLANUploadClientContext new];
    context.clientFD = clientFD;
    context.buffer = [NSMutableData data];
    context.headerParsed = NO;
    context.bodyOffset = 0;
    context.contentLength = 0;

    NSNumber *key = @(clientFD);
    __weak typeof(self) weakSelf = self;
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)clientFD, 0, self.serverQueue);
    context.readSource = source;

    dispatch_source_set_event_handler(source, ^{
        [weakSelf readClientLocked:key];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(clientFD);
    });
    self.clients[key] = context;
    dispatch_resume(source);
}

- (void)readClientLocked:(NSNumber *)key {
    AFOLANUploadClientContext *context = self.clients[key];
    if (!context) {
        return;
    }

    uint8_t chunk[8192];
    while (YES) {
        ssize_t bytes = recv(context.clientFD, chunk, sizeof(chunk), 0);
        if (bytes > 0) {
            [context.buffer appendBytes:chunk length:(NSUInteger)bytes];
            if ([self tryHandleClientLocked:context]) {
                [self closeClientLocked:key];
                return;
            }
            continue;
        }
        if (bytes == 0) {
            [self closeClientLocked:key];
            return;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return;
        }
        [self closeClientLocked:key];
        return;
    }
}

- (BOOL)tryHandleClientLocked:(AFOLANUploadClientContext *)context {
    if (!context.headerParsed) {
        NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange range = [context.buffer rangeOfData:separator options:0 range:NSMakeRange(0, context.buffer.length)];
        if (range.location == NSNotFound) {
            return NO;
        }

        NSData *headerData = [context.buffer subdataWithRange:NSMakeRange(0, range.location)];
        NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
        if (headerText.length == 0) {
            [self writeResponseWithStatus:400 contentType:@"text/plain; charset=utf-8" body:[@"Bad Request" dataUsingEncoding:NSUTF8StringEncoding] clientFD:context.clientFD];
            return YES;
        }

        NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
        if (lines.count == 0) {
            [self writeResponseWithStatus:400 contentType:@"text/plain; charset=utf-8" body:[@"Bad Request" dataUsingEncoding:NSUTF8StringEncoding] clientFD:context.clientFD];
            return YES;
        }

        NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
        if (requestLine.count < 2) {
            [self writeResponseWithStatus:400 contentType:@"text/plain; charset=utf-8" body:[@"Bad Request" dataUsingEncoding:NSUTF8StringEncoding] clientFD:context.clientFD];
            return YES;
        }
        context.method = [requestLine[0] uppercaseString];
        NSString *parsedPath = nil;
        NSString *parsedQuery = nil;
        [self parseTarget:requestLine[1] requestPath:&parsedPath query:&parsedQuery];
        context.requestPath = parsedPath;
        context.query = parsedQuery;

        NSUInteger contentLength = 0;
        for (NSUInteger idx = 1; idx < lines.count; idx++) {
            NSString *line = lines[idx];
            NSRange colonRange = [line rangeOfString:@":"];
            if (colonRange.location == NSNotFound) {
                continue;
            }
            NSString *name = [[line substringToIndex:colonRange.location] lowercaseString];
            NSString *value = [[line substringFromIndex:colonRange.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([name isEqualToString:@"content-length"]) {
                contentLength = (NSUInteger)MAX(0, value.integerValue);
            }
        }

        context.contentLength = contentLength;
        context.bodyOffset = range.location + range.length;
        context.headerParsed = YES;
    }

    if (context.buffer.length < context.bodyOffset + context.contentLength) {
        return NO;
    }
    NSData *body = [context.buffer subdataWithRange:NSMakeRange(context.bodyOffset, context.contentLength)];
    [self handleRequestMethod:context.method requestPath:context.requestPath query:context.query body:body clientFD:context.clientFD];
    return YES;
}

- (void)handleRequestMethod:(NSString *)method
                requestPath:(NSString *)requestPath
                      query:(NSString *)query
                       body:(NSData *)body
                   clientFD:(int)clientFD {
    if ([method isEqualToString:@"GET"] && ([requestPath isEqualToString:@"/"] || [requestPath isEqualToString:@"/index.html"])) {
        NSData *htmlData = [[self indexHTML] dataUsingEncoding:NSUTF8StringEncoding];
        [self writeResponseWithStatus:200 contentType:@"text/html; charset=utf-8" body:htmlData clientFD:clientFD];
        return;
    }

    if ([method isEqualToString:@"PUT"] && [requestPath isEqualToString:@"/upload"]) {
        NSString *filename = [self.class parseQueryString:query][@"filename"];
        if (filename.length == 0) {
            [self writeResponseWithStatus:400 contentType:@"application/json; charset=utf-8" body:[@"{\"message\":\"filename is required\"}" dataUsingEncoding:NSUTF8StringEncoding] clientFD:clientFD];
            return;
        }
        [self handleUploadForFilename:filename body:body clientFD:clientFD];
        return;
    }

    [self writeResponseWithStatus:404 contentType:@"text/plain; charset=utf-8" body:[@"Not Found" dataUsingEncoding:NSUTF8StringEncoding] clientFD:clientFD];
}

- (void)handleUploadForFilename:(NSString *)filename body:(NSData *)body clientFD:(int)clientFD {
    NSString *safeFilename = [self.class sanitizedFilename:filename];
    if (safeFilename.length == 0) {
        safeFilename = [NSString stringWithFormat:@"upload_%@.bin", @((long long)(NSDate.date.timeIntervalSince1970 * 1000))];
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *dirError = nil;
    [manager createDirectoryAtPath:self.uploadDirectoryPath withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        [self writeResponseWithStatus:500 contentType:@"application/json; charset=utf-8" body:[@"{\"message\":\"failed to create upload directory\"}" dataUsingEncoding:NSUTF8StringEncoding] clientFD:clientFD];
        return;
    }

    NSString *destination = [self uniquePathForFilename:safeFilename baseDirectory:self.uploadDirectoryPath];
    BOOL success = [body writeToFile:destination options:NSDataWritingAtomic error:nil];
    if (!success) {
        [self writeResponseWithStatus:500 contentType:@"application/json; charset=utf-8" body:[@"{\"message\":\"failed to save file\"}" dataUsingEncoding:NSUTF8StringEncoding] clientFD:clientFD];
        return;
    }

    NSDictionary *json = @{
        @"message": @"upload success",
        @"path": destination ?: @"",
        @"size": @(body.length)
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    [self writeResponseWithStatus:200 contentType:@"application/json; charset=utf-8" body:jsonData clientFD:clientFD];
    [self log:[NSString stringWithFormat:@"AFOLANUpload saved: %@ (%@ bytes)", destination.lastPathComponent, @(body.length)]];
}

- (void)writeResponseWithStatus:(NSInteger)status
                    contentType:(NSString *)contentType
                           body:(NSData *)body
                       clientFD:(int)clientFD {
    NSString *statusLine = [self.class statusLineForCode:status];
    NSMutableString *header = [NSMutableString stringWithFormat:@"HTTP/1.1 %@\r\n", statusLine];
    [header appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [header appendFormat:@"Content-Type: %@\r\n", contentType];
    [header appendString:@"Connection: close\r\n"];
    [header appendString:@"Access-Control-Allow-Origin: *\r\n"];
    [header appendString:@"\r\n"];

    NSMutableData *payload = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [payload appendData:body];
    [self.class writeAllData:payload toFD:clientFD];
}

- (NSString *)uniquePathForFilename:(NSString *)filename baseDirectory:(NSString *)directory {
    NSString *candidate = [directory stringByAppendingPathComponent:filename];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) {
        return candidate;
    }
    NSString *stem = filename.stringByDeletingPathExtension;
    NSString *ext = filename.pathExtension;
    NSInteger idx = 1;
    while (YES) {
        NSString *nextName = ext.length > 0 ? [NSString stringWithFormat:@"%@_%ld.%@", stem, (long)idx, ext] : [NSString stringWithFormat:@"%@_%ld", stem, (long)idx];
        NSString *nextPath = [directory stringByAppendingPathComponent:nextName];
        if (![NSFileManager.defaultManager fileExistsAtPath:nextPath]) {
            return nextPath;
        }
        idx += 1;
    }
}

- (void)parseTarget:(NSString *)target requestPath:(NSString * _Nullable __autoreleasing *)requestPath query:(NSString * _Nullable __autoreleasing *)query {
    NSRange range = [target rangeOfString:@"?"];
    if (range.location == NSNotFound) {
        if (requestPath) {
            *requestPath = target ?: @"/";
        }
        if (query) {
            *query = @"";
        }
        return;
    }
    if (requestPath) {
        *requestPath = [target substringToIndex:range.location];
    }
    if (query) {
        *query = [target substringFromIndex:range.location + 1];
    }
}

- (void)closeClientLocked:(NSNumber *)key {
    AFOLANUploadClientContext *context = self.clients[key];
    if (!context) {
        return;
    }
    [self.clients removeObjectForKey:key];
    if (context.readSource) {
        dispatch_source_cancel(context.readSource);
    } else if (context.clientFD >= 0) {
        close(context.clientFD);
    }
}

- (NSString *)indexHTML {
    return @"<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>AFO LAN Upload</title><style>body{font-family:-apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif;margin:24px;}button{padding:8px 14px;}#log{margin-top:12px;white-space:pre-wrap;color:#333;background:#f6f8fa;padding:10px;border-radius:8px;}</style></head><body><h2>AFO LAN Upload</h2><p>选择视频后点击上传，文件会保存到 App 沙盒目录。</p><input id=\"file\" type=\"file\" accept=\"video/*\"/><button id=\"upload\">上传</button><div id=\"log\"></div><script>const logEl=document.getElementById('log');function log(msg){logEl.textContent=msg;}document.getElementById('upload').addEventListener('click',()=>{const file=document.getElementById('file').files[0];if(!file){log('请先选择文件');return;}const xhr=new XMLHttpRequest();xhr.open('PUT','/upload?filename='+encodeURIComponent(file.name),true);xhr.upload.onprogress=(e)=>{if(e.lengthComputable){log('上传中: '+Math.round(e.loaded/e.total*100)+'%');}};xhr.onreadystatechange=()=>{if(xhr.readyState===4){log('状态: '+xhr.status+'\\n'+xhr.responseText);}};xhr.send(file);});</script></body></html>";
}

- (void)log:(NSString *)message {
    if (!self.logHandler) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.logHandler(message);
    });
}

#pragma mark - Class Helpers

+ (NSString *)defaultUploadDirectory {
    NSString *document = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: NSTemporaryDirectory();
    return [document stringByAppendingPathComponent:@"AFOLANUpload"];
}

+ (NSString *)statusLineForCode:(NSInteger)statusCode {
    switch (statusCode) {
        case 200: return @"200 OK";
        case 400: return @"400 Bad Request";
        case 404: return @"404 Not Found";
        case 500: return @"500 Internal Server Error";
        default: return [NSString stringWithFormat:@"%ld OK", (long)statusCode];
    }
}

+ (NSDictionary<NSString *, NSString *> *)parseQueryString:(NSString *)query {
    if (query.length == 0) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    NSArray<NSString *> *pairs = [query componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSRange equalRange = [pair rangeOfString:@"="];
        if (equalRange.location == NSNotFound) {
            continue;
        }
        NSString *rawKey = [pair substringToIndex:equalRange.location];
        NSString *rawValue = [pair substringFromIndex:equalRange.location + 1];
        NSString *key = [self decodedString:rawKey];
        NSString *value = [self decodedString:rawValue];
        if (key.length > 0) {
            result[key] = value ?: @"";
        }
    }
    return result;
}

+ (NSString *)decodedString:(NSString *)raw {
    NSString *spaceDecoded = [raw stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    return [spaceDecoded stringByRemovingPercentEncoding] ?: raw;
}

+ (NSString *)sanitizedFilename:(NSString *)filename {
    NSMutableCharacterSet *forbidden = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:\n\r\t"];
    [forbidden formUnionWithCharacterSet:NSCharacterSet.controlCharacterSet];
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:forbidden];
    NSString *joined = [parts componentsJoinedByString:@"_"];
    return [joined stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)localIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *en0Address = nil;
    NSString *fallbackAddress = @"127.0.0.1";
    if (getifaddrs(&interfaces) != 0) {
        return fallbackAddress;
    }
    for (struct ifaddrs *node = interfaces; node != NULL; node = node->ifa_next) {
        if (!node->ifa_addr || node->ifa_addr->sa_family != AF_INET) {
            continue;
        }
        if (node->ifa_flags & IFF_LOOPBACK) {
            continue;
        }
        char host[INET_ADDRSTRLEN] = {0};
        const struct sockaddr_in *addr = (const struct sockaddr_in *)node->ifa_addr;
        if (!inet_ntop(AF_INET, &addr->sin_addr, host, sizeof(host))) {
            continue;
        }
        NSString *ip = [NSString stringWithUTF8String:host];
        if (!ip.length) {
            continue;
        }
        NSString *name = node->ifa_name ? [NSString stringWithUTF8String:node->ifa_name] : @"";
        if ([name isEqualToString:@"en0"]) {
            en0Address = ip;
            break;
        }
        fallbackAddress = ip;
    }
    freeifaddrs(interfaces);
    return en0Address ?: fallbackAddress;
}

+ (void)writeAllData:(NSData *)data toFD:(int)fd {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = send(fd, bytes, remaining, 0);
        if (written <= 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        bytes += written;
        remaining -= (NSUInteger)written;
    }
}

@end
