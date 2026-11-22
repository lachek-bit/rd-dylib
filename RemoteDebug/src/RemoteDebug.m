//
//  RemoteDebug.m
//  局域网远程调试 dylib —— 注入任意 IPA 后，设备上开一个 HTTP 服务
//  电脑同网用浏览器即可：看实时日志 / 执行任意 ObjC 表达式 / dump UI / 截图 / 读文件
//
//  适配: iOS 14+ / arm64 / TrollStore 注入
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <stdlib.h>
#import <dirent.h>
#import <errno.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <execinfo.h>
#import <signal.h>

#import "RD.h"

#pragma mark - 可配置项

// 默认端口，被占用会自动 +1 顺延（最多试 10 个）
#define RD_DEFAULT_PORT   8899

// 访问口令。留空 = 不校验（仅限可信局域网）。
// 填上之后浏览器访问 http://ip:8899/?k=口令 才会放行。
#define RD_TOKEN          ""

// 日志环形缓冲条数
#define RD_MAX_LOGS       3000

#pragma mark - 日志存储

static NSMutableArray<NSDictionary *> *gLogs = nil;
static NSUInteger gLogSeq = 0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static int gLogFD = -1;
static dispatch_queue_t gLogQueue = nil;

// 日志同时落盘，崩溃后还能看到死之前的最后几步
static void RDLogWriteToFile(NSString *s) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLogQueue = dispatch_queue_create("com.rd.logwriter", DISPATCH_QUEUE_SERIAL);
    });
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                      [[NSDate date] timeIntervalSince1970], s];
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length) return;
    dispatch_async(gLogQueue, ^{
        if (gLogFD < 0) {
            NSString *p = [RDDataDir() stringByAppendingPathComponent:@"last.log"];
            gLogFD = open([p fileSystemRepresentation], O_WRONLY | O_CREAT | O_APPEND, 0644);
        }
        if (gLogFD >= 0) (void)!write(gLogFD, d.bytes, d.length);
    });
}

void RDLogAppend(NSString *s) {
    if (s.length == 0) return;
    pthread_mutex_lock(&gLogLock);
    if (!gLogs) gLogs = [NSMutableArray array];
    gLogSeq++;
    [gLogs addObject:@{@"i": @(gLogSeq),
                       @"t": @([[NSDate date] timeIntervalSince1970]),
                       @"s": s}];
    while (gLogs.count > RD_MAX_LOGS) [gLogs removeObjectAtIndex:0];
    pthread_mutex_unlock(&gLogLock);
    RDLogWriteToFile(s);
}

void RDLogClear(void) {
    pthread_mutex_lock(&gLogLock);
    [gLogs removeAllObjects];
    pthread_mutex_unlock(&gLogLock);
}

NSArray *RDLogsSince(NSUInteger since, NSUInteger *nextOut) {
    pthread_mutex_lock(&gLogLock);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in gLogs) {
        if ([d[@"i"] unsignedIntegerValue] > since) [out addObject:d];
    }
    NSUInteger cur = gLogSeq;
    pthread_mutex_unlock(&gLogLock);
    if (nextOut) *nextOut = cur;
    return out;
}

#pragma mark - stderr 捕获（NSLog / printf 全收）

static int gOrigStderr = -1;

static void RDStderrLoop(int rfd) {
    char buf[8192];
    NSMutableData *acc = [NSMutableData data];
    for (;;) {
        ssize_t n = read(rfd, buf, sizeof(buf));
        if (n <= 0) break;
        // 原样转发回真实 stderr，保留 Xcode / 系统日志
        if (gOrigStderr >= 0) (void)!write(gOrigStderr, buf, (size_t)n);
        [acc appendBytes:buf length:(NSUInteger)n];

        const uint8_t *bytes = acc.bytes;
        NSUInteger len = acc.length, start = 0;
        for (NSUInteger i = 0; i < len; i++) {
            if (bytes[i] != '\n') continue;
            NSUInteger l = i - start;
            NSString *line = [[NSString alloc] initWithBytes:bytes + start
                                                      length:l
                                                    encoding:NSUTF8StringEncoding];
            if (!line) line = [[NSString alloc] initWithBytes:bytes + start
                                                       length:l
                                                     encoding:NSISOLatin1StringEncoding];
            if (line.length) RDLogAppend(line);
            start = i + 1;
        }
        if (start > 0) [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
}

static void RDStartStderrCapture(void) {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    int fds[2];
    if (pipe(fds) != 0) return;
    gOrigStderr = dup(STDERR_FILENO);
    dup2(fds[1], STDERR_FILENO);

    int rfd = fds[0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        RDStderrLoop(rfd);
    });
}

#pragma mark - 主线程桥

id RDRunOnMain(id (^blk)(void)) {
    if ([NSThread isMainThread]) return blk();
    __block id r = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{ r = blk(); });
    return r;
}

UIWindow *RDKeyWindow(void) {
    __block UIWindow *w = nil;
    RDRunOnMain(^{
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                UIWindowScene *ws = (UIWindowScene *)sc;
                if (ws.activationState != UISceneActivationStateForegroundActive &&
                    ws.activationState != UISceneActivationStateForegroundInactive) continue;
                for (UIWindow *cand in ws.windows) {
                    if (cand.isKeyWindow) { w = cand; break; }
                }
                if (!w && ws.windows.count) w = ws.windows.firstObject;
                if (w) break;
            }
        }
        if (!w) {
            for (UIWindow *cand in [UIApplication sharedApplication].windows) {
                if (cand.isKeyWindow) { w = cand; break; }
            }
        }
        if (!w) w = [UIApplication sharedApplication].windows.firstObject;
        return (id)nil;
    });
    return w;
}

#pragma mark - UI 层级 dump

static void RDAppendViewNode(UIView *v, int depth, NSMutableString *out) {
    if (depth > 48) return;
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    CGRect f = v.frame;
    NSMutableString *extra = [NSMutableString string];

    if (v.tag) [extra appendFormat:@" tag=%ld", (long)v.tag];
    if (v.isHidden) [extra appendString:@" hidden"];
    if (v.alpha < 0.99) [extra appendFormat:@" alpha=%.2f", v.alpha];
    NSString *aid = v.accessibilityIdentifier;
    if (aid.length) [extra appendFormat:@" id=\"%@\"", aid];

    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) [extra appendFormat:@" text=\"%@\"", t];
    } else if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)v) titleForState:UIControlStateNormal];
        if (t.length) [extra appendFormat:@" title=\"%@\"", t];
    } else if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        if (tf.text.length) [extra appendFormat:@" text=\"%@\"", tf.text];
        if (tf.placeholder.length) [extra appendFormat:@" ph=\"%@\"", tf.placeholder];
    } else if ([v isKindOfClass:[UITextView class]]) {
        NSString *t = ((UITextView *)v).text;
        if (t.length) [extra appendFormat:@" text=\"%@\"", [t substringToIndex:MIN(t.length, (NSUInteger)80)]];
    } else if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img) [extra appendFormat:@" image=%.0fx%.0f", img.size.width, img.size.height];
    } else if ([v isKindOfClass:[UIScrollView class]]) {
        UIScrollView *sv = (UIScrollView *)v;
        [extra appendFormat:@" content=%.0f,%.0f offset=%.0f,%.0f",
            sv.contentSize.width, sv.contentSize.height,
            sv.contentOffset.x, sv.contentOffset.y];
    }

    [out appendFormat:@"%@%@ (%.0f,%.0f,%.0f,%.0f)%@\n%@#%p\n",
        pad, NSStringFromClass([v class]),
        f.origin.x, f.origin.y, f.size.width, f.size.height,
        extra, pad, (void *)v];

    for (UIView *sub in v.subviews) RDAppendViewNode(sub, depth + 1, out);
}

NSString *RDUIDump(void) {
    return RDRunOnMain(^id{
        NSMutableString *out = [NSMutableString string];
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)@"<no key window>";
        [out appendFormat:@"=== keyWindow: %@  %@\n", NSStringFromClass([w class]),
            NSStringFromCGRect(w.bounds)];
        RDAppendViewNode(w, 0, out);
        return (id)out;
    });
}

NSString *RDUIDumpVC(void) {
    return RDRunOnMain(^id{
        NSMutableString *out = [NSMutableString string];
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)@"<no key window>";
        UIViewController *vc = w.rootViewController;
        NSMutableArray *stack = [NSMutableArray array];
        while (vc) {
            [stack addObject:vc];
            if ([vc isKindOfClass:[UINavigationController class]])
                vc = ((UINavigationController *)vc).topViewController;
            else if ([vc isKindOfClass:[UITabBarController class]])
                vc = ((UITabBarController *)vc).selectedViewController;
            else if (vc.presentedViewController)
                vc = vc.presentedViewController;
            else break;
        }
        for (UIViewController *item in stack) {
            [out appendFormat:@"%@  <%p>  title=%@\n",
                NSStringFromClass([item class]), (void *)item, item.title ?: @"-"];
        }
        return (id)out;
    });
}

#pragma mark - 截图

NSData *RDScreenshotJPEG(CGFloat quality) {
    return RDRunOnMain(^id{
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = [UIScreen mainScreen].scale;
        UIGraphicsImageRenderer *r =
            [[UIGraphicsImageRenderer alloc] initWithBounds:w.bounds format:fmt];
        UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [w drawViewHierarchyInRect:w.bounds afterScreenUpdates:NO];
        }];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSData *d = UIImageJPEGRepresentation(img, quality);
#pragma clang diagnostic pop
        return (id)d;
    });
}

#pragma mark - JS 执行环境

static JSContext *gJS = nil;
static NSString *gJSLastError = nil;

static NSArray<NSString *> *RDAllClassNames(void) {
    // 血泪：在 Swift app 里枚举类不能碰 Class 对象。
    // objc_getClassList / objc_copyClassList 都会走到 class_getName，
    // 而某些 Swift 类的元数据是懒加载的，class_getName 会触发
    // swift_getSingletonMetadata 实例化 —— 递归或半初始化状态直接 SIGSEGV。
    // （crash.log 里同时看到 objc_getClassList+80 和 swift_getSingletonMetadata 两帧）
    //
    // 改用 objc_copyImageNames + objc_copyClassNamesForImage：
    // 它只返回名字字符串，不构造 Class，完全不碰元数据。
    static pthread_mutex_t cacheLock = PTHREAD_MUTEX_INITIALIZER;
    static NSArray *cache = nil;
    static NSTimeInterval cacheAt = 0;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    pthread_mutex_lock(&cacheLock);
    if (cache && now - cacheAt < 15.0) {
        NSArray *hit = cache;
        pthread_mutex_unlock(&cacheLock);
        return hit;
    }
    pthread_mutex_unlock(&cacheLock);

    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:4096];

    unsigned int imgCount = 0;
    const char **images = objc_copyImageNames(&imgCount);
    if (images) {
        for (unsigned int i = 0; i < imgCount; i++) {
            if (!images[i]) continue;
            unsigned int clsCount = 0;
            const char **names = NULL;
            @try {
                names = objc_copyClassNamesForImage(images[i], &clsCount);
            } @catch (NSException *e) {
                names = NULL;
            }
            if (!names) continue;
            for (unsigned int j = 0; j < clsCount; j++) {
                if (!names[j]) continue;
                @try {
                    NSString *s = [NSString stringWithUTF8String:names[j]];
                    if (!s.length) {
                        s = [[NSString alloc] initWithBytes:names[j]
                                                     length:strlen(names[j])
                                                   encoding:NSISOLatin1StringEncoding];
                    }
                    if (s.length) [arr addObject:s];
                } @catch (NSException *e) {
                    (void)e;
                }
            }
            free(names);
        }
        free(images);
    }

    pthread_mutex_lock(&cacheLock);
    cache = arr;
    cacheAt = now;
    pthread_mutex_unlock(&cacheLock);
    return arr;
}

// 用 NSInvocation 调方法，参数与返回值都按对象处理。
// 不依赖 JSC 的 selector 名字转换，支持 "foo:bar:" 这种标准写法。
static id RDInvoke(id target, NSString *selName, NSArray *args) {
    if (!target || !selName.length) return nil;
    SEL sel = NSSelectorFromString(selName);
    if (!sel) return nil;

    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;

    NSUInteger total = sig.numberOfArguments;
    NSUInteger given = args.count;
    for (NSUInteger i = 2; i < total; i++) {
        __unsafe_unretained id a = (i - 2) < given ? args[i - 2] : nil;
        if (a == [NSNull null]) a = nil;
        const char *t = [sig getArgumentTypeAtIndex:i];
        if (t && t[0] == '@') {
            [inv setArgument:&a atIndex:i];
        }
    }
    [inv invoke];

    if (sig.methodReturnLength > 0) {
        const char *rt = sig.methodReturnType;
        if (!rt) return nil;
        switch (rt[0]) {
            case '@': {
                __unsafe_unretained id ret = nil;
                [inv getReturnValue:&ret];
                return ret;
            }
            case 'B': {
                BOOL v = NO;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'c': {
                char v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 's': {
                short v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'i': {
                int v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'l': {
                long v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'q': {
                long long v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            // 无符号版本，NSUInteger / count / length 都走这里
            case 'C': {
                unsigned char v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'S': {
                unsigned short v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'I': {
                unsigned int v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'L': {
                unsigned long v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'Q': {
                unsigned long long v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'f': {
                float v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            case 'd': {
                double v = 0;
                [inv getReturnValue:&v];
                return @(v);
            }
            default:
                break;
        }
    }
    return nil;
}

static void RDJSBootstrap(void) {
    if (gJS) return;
    gJS = [[JSContext alloc] init];
    gJS.exceptionHandler = ^(JSContext *ctx, JSValue *ex) {
        gJSLastError = [ex toString];
    };

    // 常用类直接挂成全局，省得写 ObjC.classes.XXX
    NSArray *names = @[
        @"UIApplication", @"UIWindow", @"UIView", @"UIViewController", @"UILabel",
        @"UIButton", @"UIImage", @"UIColor", @"UIFont", @"UIScreen", @"UIDevice",
        @"UINavigationController", @"UITabBarController", @"UIAlertController",
        @"NSBundle", @"NSFileManager", @"NSString", @"NSMutableString", @"NSArray",
        @"NSMutableArray", @"NSDictionary", @"NSMutableDictionary", @"NSNumber",
        @"NSUserDefaults", @"NSURL", @"NSURLRequest", @"NSURLSession", @"NSData",
        @"NSDate", @"NSNotificationCenter", @"NSThread", @"NSProcessInfo"
    ];
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        @try { gJS[n] = c; } @catch (NSException *e) { (void)e; }
    }

    id (^keyWindow)(void) = ^id{ return RDKeyWindow(); };
    id (^app)(void) = ^id{ return [UIApplication sharedApplication]; };
    NSString * (^uiDump)(void) = ^NSString *{ return RDUIDump(); };
    NSArray * (^allClasses)(void) = ^NSArray *{ return RDAllClassNames(); };
    id (^clsByName)(NSString *n) = ^id(NSString *nm) { return NSClassFromString(nm); };
    void (^log)(id) = ^(id s){ RDLogAppend([s description]); };
    id (^callCls)(NSString *, NSString *, NSArray *) =
        ^id(NSString *cls, NSString *sel, NSArray *args) {
            return RDInvoke(NSClassFromString(cls), sel, args ?: @[]);
        };
    id (^callInst)(id, NSString *, NSArray *) =
        ^id(id obj, NSString *sel, NSArray *args) {
            return RDInvoke(obj, sel, args ?: @[]);
        };
    id (^ptrFn)(NSString *) = ^id(NSString *hex) {
        if (!hex.length) return nil;
        unsigned long long v = 0;
        sscanf(hex.UTF8String, "%llx", &v);
        return (__bridge id)(void *)(uintptr_t)v;
    };
    NSString * (^descFn)(id) = ^NSString *(id o) { return RDDescribeObject(o); };
    BOOL (^hookFn)(NSString *, NSString *, NSString *, id) =
        ^BOOL(NSString *c, NSString *s, NSString *m, id v) {
            NSString *e = nil;
            BOOL ok = RDHookInstall(c, s, m, v, &e);
            if (ok) RDHookPersist();
            else RDLogAppend([NSString stringWithFormat:@"[HOOK!] %@", e ?: @"安装失败"]);
            return ok;
        };
    void (^unhookFn)(NSString *, NSString *) = ^(NSString *c, NSString *s) {
        RDHookRemove(c, s);
        RDHookPersist();
    };
    NSArray * (^hooksFn)(void) = ^NSArray *{ return RDHookList(); };
    NSArray * (^toolsFn)(void) = ^NSArray *{ return RDToolList(); };
    id (^toolFn)(NSString *, NSDictionary *) =
        ^id(NSString *n, NSDictionary *a) {
            NSString *e = nil;
            id r = RDCallTool(n, a ?: @{}, &e);
            return e ? @{@"error": e} : (r ?: [NSNull null]);
        };

    gJS[@"_rd"] = @{
        @"app":        app,
        @"keyWindow":  keyWindow,
        @"uiDump":     uiDump,
        @"classes":    allClasses,
        @"cls":        clsByName,
        @"call":       callCls,     // _rd.call('UIApplication', 'sharedApplication', [])
        @"inst":       callInst,    // _rd.inst(obj, 'setText:', ['hi'])
        @"ptr":        ptrFn,       // _rd.ptr('0x104...') 指针转对象
        @"desc":       descFn,
        @"hook":       hookFn,      // _rd.hook('Cls','sel:','force',1)
        @"unhook":     unhookFn,
        @"hooks":      hooksFn,
        @"tools":      toolsFn,     // _rd.tools()
        @"tool":       toolFn,      // _rd.tool('ui.tapText', {text:'确定'})
        @"log":        log,
        @"version":    @"1.2",
    };
}

// 返回结果字符串；出错返回以 "ERROR: " 开头
NSString *RDEvalSource(NSString *code) {
    __block NSString *result = nil;
    RDRunOnMain(^id{
        RDJSBootstrap();
        gJSLastError = nil;
        JSValue *v = [gJS evaluateScript:code];
        if (gJSLastError) {
            result = [@"ERROR: " stringByAppendingString:gJSLastError];
            gJSLastError = nil;
        } else if (!v || v.isUndefined) {
            result = @"undefined";
        } else if (v.isNull) {
            result = @"null";
        } else {
            result = [v toString];
        }
        return (id)nil;
    });
    return result ?: @"ERROR: no result";
}

#pragma mark - HTTP 基础设施

static int RDCurrentPort(void);

@interface RDResp : NSObject
@property (nonatomic) int status;
@property (nonatomic, copy) NSString *ctype;
@property (nonatomic, strong) NSData *body;
@end

@implementation RDResp
+ (instancetype)json:(id)obj {
    RDResp *r = [RDResp new];
    r.status = 200;
    r.ctype = @"application/json; charset=utf-8";
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&e];
    if (!d) d = [[NSString stringWithFormat:@"{\"ok\":false,\"error\":\"json: %@\"}",
                  e.localizedDescription] dataUsingEncoding:NSUTF8StringEncoding];
    r.body = d;
    return r;
}
+ (instancetype)text:(NSString *)s status:(int)st {
    RDResp *r = [RDResp new];
    r.status = st;
    r.ctype = @"text/plain; charset=utf-8";
    r.body = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}
+ (instancetype)html:(NSString *)s {
    RDResp *r = [RDResp new];
    r.status = 200;
    r.ctype = @"text/html; charset=utf-8";
    r.body = [s dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}
+ (instancetype)data:(NSData *)d ctype:(NSString *)c {
    RDResp *r = [RDResp new];
    r.status = 200;
    r.ctype = c ?: @"application/octet-stream";
    r.body = d ?: [NSData data];
    return r;
}
@end

NSString *RDIndexHTML(void);   // 定义在 RDIndexHTML.m

static void RDSendAll(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, p + off, len - off, 0);
        if (n <= 0) break;
        off += (size_t)n;
    }
}

static NSString *RDURLDecode(NSString *s) {
    if (!s.length) return @"";
    return [s stringByRemovingPercentEncoding] ?: s;
}

static NSDictionary *RDParseQuery(NSString *q) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *pair in [q componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) { d[RDURLDecode(pair)] = @""; continue; }
        NSString *k = RDURLDecode([pair substringToIndex:eq.location]);
        NSString *v = RDURLDecode([pair substringFromIndex:eq.location + 1]);
        if (k.length) d[k] = v;
    }
    return d;
}

// 把 URL 里的 value 参数转成合适的 NSNumber / NSString / nil
static id RDParseValue(NSString *s) {
    if (!s) return nil;
    if ([s isEqualToString:@"nil"] || [s isEqualToString:@"null"]) return nil;
    if ([s isEqualToString:@"true"] || [s isEqualToString:@"YES"]) return @YES;
    if ([s isEqualToString:@"false"] || [s isEqualToString:@"NO"]) return @NO;
    if ([s hasPrefix:@"s:"]) return [s substringFromIndex:2];
    NSScanner *sc = [NSScanner scannerWithString:s];
    double d = 0;
    if ([sc scanDouble:&d] && sc.isAtEnd) return @(d);
    return s;
}

#pragma mark - 请求处理

static NSString *RDDeviceModel(void) {
    static NSString *model = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = 0;
        sysctlbyname("hw.machine", NULL, &size, NULL, 0);
        if (size > 0) {
            char *buf = (char *)malloc(size);
            if (buf) {
                if (sysctlbyname("hw.machine", buf, &size, NULL, 0) == 0) {
                    model = @(buf);
                }
                free(buf);
            }
        }
        if (!model) model = [[UIDevice currentDevice] model];
    });
    return model;
}

static void RDAppendDirListing(NSString *path, NSMutableArray *out) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:&err];
    if (!items) return;
    for (NSString *name in [items sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *full = [path stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        BOOL isDir = [attrs[NSFileType] isEqual:NSFileTypeDirectory];
        [out addObject:@{
            @"name": name,
            @"dir":  @(isDir),
            @"size": attrs[NSFileSize] ?: @0,
            @"mtime": @([attrs[NSFileModificationDate] timeIntervalSince1970])
        }];
    }
}

static void RDWriteResponse(int fd, RDResp *r) {
    const char *st = r.status == 200 ? "OK"
                   : r.status == 404 ? "Not Found"
                   : r.status == 500 ? "Internal Server Error"
                   : "Error";
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %d %s\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Access-Control-Allow-Headers: *\r\n"
        @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        @"Cache-Control: no-store\r\n"
        @"Connection: close\r\n\r\n",
        r.status, st, r.ctype, (unsigned long)r.body.length];

    NSMutableData *out = [NSMutableData data];
    [out appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:r.body];
    RDSendAll(fd, out.bytes, out.length);
}

static RDResp *RDHandle(NSString *method, NSString *path, NSDictionary *q, NSData *body) {
    if ([method isEqualToString:@"OPTIONS"]) {
        RDResp *r = [RDResp text:@"" status:200];
        return r;
    }

    // ---- 首页
    if ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"]) {
        return [RDResp html:RDIndexHTML()];
    }

    // ---- 存活探测
    if ([path isEqualToString:@"/api/ping"]) {
        return [RDResp json:@{@"ok": @YES, @"ver": @"1.0", @"pid": @(getpid())}];
    }

    // ---- 进程 / 设备信息
    if ([path isEqualToString:@"/api/info"]) {
        NSBundle *b = [NSBundle mainBundle];
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        NSMutableDictionary *d = [@{
            @"app_name":   (b.infoDictionary[@"CFBundleDisplayName"] ?: b.infoDictionary[@"CFBundleName"] ?: @"-"),
            @"bundle_id":  b.bundleIdentifier ?: @"-",
            @"version":    b.infoDictionary[@"CFBundleShortVersionString"] ?: @"-",
            @"build":      b.infoDictionary[@"CFBundleVersion"] ?: @"-",
            @"executable": b.infoDictionary[@"CFBundleExecutable"] ?: @"-",
            @"device":     RDDeviceModel(),
            @"ios":        [[UIDevice currentDevice] systemVersion],
            @"pid":        @(getpid()),
            @"uid":        @(getuid()),
            @"port":       @(RDCurrentPort()),
            @"home":       NSHomeDirectory(),
            @"bundle_path": [b bundlePath] ?: @"-",
            @"started":    @(pi.systemUptime),
            @"locale":     [[NSLocale currentLocale] localeIdentifier] ?: @"-",
        } mutableCopy];
        d[@"exec_path"] = NSProcessInfo.processInfo.arguments.firstObject ?: @"-";
        return [RDResp json:d];
    }

    // ---- 日志增量拉取
    if ([path isEqualToString:@"/api/logs"]) {
        NSUInteger since = (NSUInteger)[q[@"since"] integerValue];
        NSUInteger next = 0;
        NSArray *lines = RDLogsSince(since, &next);
        return [RDResp json:@{@"ok": @YES, @"next": @(next), @"lines": lines}];
    }

    // ---- 清空日志
    if ([path isEqualToString:@"/api/clear"]) {
        pthread_mutex_lock(&gLogLock);
        [gLogs removeAllObjects];
        pthread_mutex_unlock(&gLogLock);
        return [RDResp json:@{@"ok": @YES}];
    }

    // ---- 执行 JS（ObjC 桥）
    if ([path isEqualToString:@"/api/eval"]) {
        NSString *code = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!code.length) code = q[@"code"];
        if (!code.length) return [RDResp json:@{@"ok": @NO, @"error": @"empty code"}];
        NSString *r = RDEvalSource(code);
        BOOL bad = [r hasPrefix:@"ERROR: "];
        return [RDResp json:@{@"ok": @(!bad),
                              @"result": bad ? [r substringFromIndex:7] : r}];
    }

    // ---- 动态 hook：装 / 卸 / 列表
    if ([path isEqualToString:@"/api/hook"]) {
        NSString *cls = q[@"cls"];
        NSString *sel = q[@"sel"];
        if (!cls.length || !sel.length) {
            return [RDResp json:@{@"ok": @NO, @"error": @"需要 cls 和 sel"}];
        }
        // arg1=xxx 匹配第 1 个参数，arg2=xxx 匹配第 2 个（比如 setObject:forKey: 的 key）
        NSString *am = q[@"argMatch"];
        NSInteger ai = (NSInteger)[q[@"argIndex"] integerValue];
        if (!am.length && q[@"arg1"]) { am = q[@"arg1"]; ai = 0; }
        if (!am.length && q[@"arg2"]) { am = q[@"arg2"]; ai = 1; }

        NSString *err = nil;
        BOOL ok = RDHookInstallFull(cls, sel, q[@"mode"], RDParseValue(q[@"value"]),
                                    am, ai, &err);
        // 默认不落盘：调试期的 hook 重启即失效，避免把自己锁死在崩溃循环里。
        // 需要长期生效再加 persist=1
        BOOL persist = (q[@"persist"] != nil);
        if (ok && persist) RDHookPersist();
        return [RDResp json:@{@"ok": @(ok), @"error": err ?: @"", @"saved": @(persist)}];
    }

    if ([path isEqualToString:@"/api/unhook"]) {
        BOOL ok = RDHookRemove(q[@"cls"], q[@"sel"]);
        RDHookPersist();
        return [RDResp json:@{@"ok": @(ok)}];
    }

    if ([path isEqualToString:@"/api/hooks"]) {
        return [RDResp json:@{@"ok": @YES, @"items": RDHookList()}];
    }

    if ([path isEqualToString:@"/api/hookclear"]) {
        RDHookResetAll();
        RDHookPersist();
        return [RDResp json:@{@"ok": @YES}];
    }

    // ---- 反射
    if ([path isEqualToString:@"/api/methods"]) {
        NSString *cls = q[@"cls"];
        if (!cls.length) return [RDResp json:@{@"ok": @NO, @"error": @"需要 cls"}];
        NSArray *items = RDClassMethods(cls, q[@"all"] != nil);
        return [RDResp json:@{@"ok": @YES, @"count": @(items.count), @"items": items}];
    }

    if ([path isEqualToString:@"/api/props"]) {
        NSString *cls = q[@"cls"];
        if (!cls.length) return [RDResp json:@{@"ok": @NO, @"error": @"需要 cls"}];
        return [RDResp json:@{@"ok": @YES, @"items": RDClassProperties(cls, q[@"all"] != nil)}];
    }

    if ([path isEqualToString:@"/api/ivars"]) {
        NSString *cls = q[@"cls"];
        if (!cls.length) return [RDResp json:@{@"ok": @NO, @"error": @"需要 cls"}];
        return [RDResp json:@{@"ok": @YES, @"items": RDClassIvars(cls)}];
    }

    if ([path isEqualToString:@"/api/find"]) {
        NSString *cls = q[@"cls"];
        if (!cls.length) return [RDResp json:@{@"ok": @NO, @"error": @"需要 cls"}];
        NSUInteger limit = (NSUInteger)[q[@"limit"] integerValue];
        NSArray *items = RDFindInstances(cls, limit);
        return [RDResp json:@{@"ok": @YES, @"count": @(items.count), @"items": items}];
    }

    // ---- 热更新：上传新 dylib 到沙盒 stage 目录
    if ([path isEqualToString:@"/api/deploy"]) {
        if (!body.length) return [RDResp json:@{@"ok": @NO, @"error": @"空 body"}];

        NSString *dir = [RDDataDir() stringByAppendingPathComponent:@"stage"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *tmp = [dir stringByAppendingPathComponent:@"RemoteDebug.dylib.tmp"];
        NSString *dst = [dir stringByAppendingPathComponent:@"RemoteDebug.dylib"];

        NSError *e = nil;
        if (![body writeToFile:tmp options:NSDataWritingAtomic error:&e]) {
            return [RDResp json:@{@"ok": @NO,
                                  @"error": e.localizedDescription ?: @"写入失败"}];
        }
        [fm removeItemAtPath:dst error:nil];
        if (![fm moveItemAtPath:tmp toPath:dst error:&e]) {
            return [RDResp json:@{@"ok": @NO,
                                  @"error": e.localizedDescription ?: @"重命名失败"}];
        }
        // 新的 stage 就位，清掉上次的失败标记
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"failed"] error:nil];

        RDLogAppend([NSString stringWithFormat:@"[DEPLOY] 已收到新 dylib %lu 字节 -> %@",
                     (unsigned long)body.length, dst]);
        return [RDResp json:@{@"ok": @YES,
                              @"size": @(body.length),
                              @"path": dst,
                              @"hint": @"调用 deploy.test 验证能否加载"}];
    }

    if ([path isEqualToString:@"/api/deploy/status"]) {
        NSString *dir = [RDDataDir() stringByAppendingPathComponent:@"stage"];
        NSString *dst = [dir stringByAppendingPathComponent:@"RemoteDebug.dylib"];
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:dst error:nil];
        BOOL staged = (attrs != nil);
        BOOL failed = [[NSFileManager defaultManager]
                       fileExistsAtPath:[dir stringByAppendingPathComponent:@"failed"]];
        return [RDResp json:@{@"ok": @YES,
                              @"staged": @(staged),
                              @"size": attrs[NSFileSize] ?: @0,
                              @"mtime": attrs[NSFileModificationDate] ? @([attrs[NSFileModificationDate] timeIntervalSince1970]) : @0,
                              @"last_failed": @(failed),
                              @"dir": dir ?: @""}];
    }

    // ---- 工具：列表 / 调用 / 注册 / 删除
    if ([path isEqualToString:@"/api/tools"]) {
        return [RDResp json:@{@"ok": @YES, @"tools": RDToolList()}];
    }

    if ([path isEqualToString:@"/api/tool"]) {
        NSString *name = q[@"name"];
        NSMutableDictionary *args = [NSMutableDictionary dictionary];

        if ([method isEqualToString:@"POST"] && body.length) {
            id j = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            if ([j isKindOfClass:[NSDictionary class]]) {
                if (!name.length) name = j[@"name"];
                id a = j[@"args"];
                if ([a isKindOfClass:[NSDictionary class]]) [args addEntriesFromDictionary:a];
                else {
                    // 也允许 {"name":"x","x":1,"y":2} 这种平铺写法
                    for (NSString *k in j) {
                        if ([k isEqualToString:@"name"] || [k isEqualToString:@"args"]) continue;
                        args[k] = j[k];
                    }
                }
            }
        }
        if (!name.length) return [RDResp json:@{@"ok": @NO, @"error": @"需要 name"}];
        for (NSString *k in q) {
            if ([k isEqualToString:@"name"] || [k isEqualToString:@"k"]) continue;
            args[k] = q[k];
        }

        NSString *err = nil;
        id r = RDCallTool(name, args, &err);
        if (err) return [RDResp json:@{@"ok": @NO, @"error": err}];
        if (r && [NSJSONSerialization isValidJSONObject:r]) {
            return [RDResp json:@{@"ok": @YES, @"result": r}];
        }
        return [RDResp json:@{@"ok": @YES, @"result": r ? [r description] : [NSNull null]}];
    }

    if ([path isEqualToString:@"/api/tooldef"]) {
        id j = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:nil] : nil;
        if (![j isKindOfClass:[NSDictionary class]]) {
            return [RDResp json:@{@"ok": @NO, @"error": @"body 要是 JSON 对象"}];
        }
        NSString *err = nil;
        BOOL ok = RDDefineJSTool(j, &err);
        return [RDResp json:@{@"ok": @(ok), @"error": ok ? @"" : (err ?: @"注册失败")}];
    }

    if ([path isEqualToString:@"/api/toolrm"]) {
        BOOL ok = RDDeleteTool(q[@"name"]);
        return [RDResp json:@{@"ok": @(ok)}];
    }

    // ---- UI 层级
    if ([path isEqualToString:@"/api/ui"]) {
        NSString *s = q[@"vc"] ? RDUIDumpVC() : RDUIDump();
        return [RDResp text:s status:200];
    }

    // ---- 截图
    if ([path isEqualToString:@"/api/screenshot.jpg"] || [path isEqualToString:@"/api/shot"]) {
        CGFloat quality = q[@"q"] ? [q[@"q"] doubleValue] : 0.7;
        NSData *d = RDScreenshotJPEG(MAX(0.1, MIN(1.0, quality)));
        if (!d) return [RDResp text:@"no window" status:500];
        return [RDResp data:d ctype:@"image/jpeg"];
    }

    // ---- 类名搜索
    if ([path isEqualToString:@"/api/classes"]) {
        NSString *kw = q[@"q"] ?: @"";
        NSArray *all = RDAllClassNames();
        NSMutableArray *hit = [NSMutableArray array];
        if (!kw.length) {
            [hit addObjectsFromArray:[all subarrayWithRange:
                NSMakeRange(0, MIN(all.count, (NSUInteger)200))]];
        } else {
            for (NSString *n in all) {
                if ([n rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [hit addObject:n];
                    if (hit.count >= 500) break;
                }
            }
        }
        return [RDResp json:@{@"ok": @YES, @"count": @(all.count), @"items": hit}];
    }

    // ---- 文件浏览 / 下载
    if ([path isEqualToString:@"/api/fs"]) {
        NSString *p = q[@"path"];
        if (!p.length) p = NSHomeDirectory();
        p = [p stringByExpandingTildeInPath];
        NSMutableArray *items = [NSMutableArray array];
        RDAppendDirListing(p, items);
        return [RDResp json:@{@"ok": @YES, @"path": p, @"items": items}];
    }
    if ([path isEqualToString:@"/api/file"]) {
        NSString *p = q[@"path"];
        if (!p.length) return [RDResp json:@{@"ok": @NO, @"error": @"need path"}];
        NSData *d = [NSData dataWithContentsOfFile:[p stringByExpandingTildeInPath]];
        if (!d) return [RDResp json:@{@"ok": @NO, @"error": @"read failed"}];
        return [RDResp data:d ctype:@"application/octet-stream"];
    }

    // ---- NSUserDefaults
    if ([path isEqualToString:@"/api/defaults"]) {
        NSString *dom = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!dom.length) dom = q[@"domain"];
        NSUserDefaults *ud = dom.length ? [[NSUserDefaults alloc] initWithSuiteName:dom]
                                        : [NSUserDefaults standardUserDefaults];
        NSDictionary *raw = [ud dictionaryRepresentation] ?: @{};
        // UserDefaults 里常混着 NSData（token、缓存），直接序列化会抛异常。
        // 把不可序列化的值换成一句说明，保证整体能返回结构化 JSON。
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:raw.count];
        for (id k in raw) {
            id v = raw[k];
            if ([v isKindOfClass:[NSData class]]) {
                clean[k] = [NSString stringWithFormat:@"<data %lu bytes>",
                            (unsigned long)[(NSData *)v length]];
            } else if ([v isKindOfClass:[NSDate class]]) {
                clean[k] = [NSString stringWithFormat:@"<date %.0f>", [(NSDate *)v timeIntervalSince1970]];
            } else if ([v isKindOfClass:[NSNumber class]] ||
                       [v isKindOfClass:[NSString class]] ||
                       [v isKindOfClass:[NSArray class]] ||
                       [v isKindOfClass:[NSDictionary class]]) {
                clean[k] = v;
            } else if (v) {
                clean[k] = [v description];
            }
        }
        @try {
            NSError *e = nil;
            NSData *jd = [NSJSONSerialization dataWithJSONObject:clean options:0 error:&e];
            if (jd) {
                RDResp *r = [RDResp new];
                r.status = 200;
                r.ctype = @"application/json; charset=utf-8";
                r.body = jd;
                return r;
            }
        } @catch (NSException *ex) {
            (void)ex;
        }
        return [RDResp text:[clean description] status:200];
    }

    // ---- 沙盒内写文件（方便推配置/脚本进去）
    if ([path isEqualToString:@"/api/write"]) {
        NSString *p = q[@"path"];
        if (!p.length) return [RDResp json:@{@"ok": @NO, @"error": @"need path"}];
        p = [p stringByExpandingTildeInPath];
        NSError *e = nil;
        BOOL ok = [body writeToFile:p options:NSDataWritingAtomic error:&e];
        return [RDResp json:@{@"ok": @(ok),
                              @"path": p,
                              @"error": ok ? @"" : (e.localizedDescription ?: @"write failed")}];
    }

    return [RDResp text:@"404 not found" status:404];
}

#pragma mark - 连接处理

static BOOL RDReadRequest(int fd, NSMutableData *headOut, NSMutableData *bodyOut) {
    uint8_t tmp[4096];
    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrRange = NSMakeRange(NSNotFound, 0);
    headOut.length = 0;

    while (hdrRange.location == NSNotFound) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n <= 0) return NO;
        [headOut appendBytes:tmp length:(NSUInteger)n];
        hdrRange = [headOut rangeOfData:sep options:0
                                  range:NSMakeRange(0, headOut.length)];
        if (headOut.length > 1024 * 1024) return NO;   // 头太大
    }

    NSString *head = [[NSString alloc] initWithData:
        [headOut subdataWithRange:NSMakeRange(0, hdrRange.location)]
                                            encoding:NSUTF8StringEncoding];
    if (!head) return NO;

    NSInteger contentLength = 0;
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:c.location]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![key.lowercaseString isEqualToString:@"content-length"]) continue;
        contentLength = [[line substringFromIndex:c.location + 1]
                            integerValue];
    }

    NSUInteger hdrTotal = NSMaxRange(hdrRange);
    NSUInteger got = headOut.length - hdrTotal;
    while (got < (NSUInteger)contentLength) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n <= 0) break;
        [headOut appendBytes:tmp length:(NSUInteger)n];
        got += (NSUInteger)n;
    }
    if (contentLength > 0) {
        NSUInteger avail = headOut.length - hdrTotal;
        NSUInteger take = MIN((NSUInteger)contentLength, avail);
        [bodyOut setData:[headOut subdataWithRange:NSMakeRange(hdrTotal, take)]];
    }
    return YES;
}

static void RDHandleConnection(int fd) {
    struct timeval tv = {8, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    NSMutableData *head = [NSMutableData data];
    NSMutableData *body = [NSMutableData data];
    if (!RDReadRequest(fd, head, body)) { close(fd); return; }

    NSData *sep = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange hdrRange = [head rangeOfData:sep options:0 range:NSMakeRange(0, head.length)];
    if (hdrRange.location == NSNotFound) { close(fd); return; }

    NSString *headStr = [[NSString alloc] initWithData:
        [head subdataWithRange:NSMakeRange(0, hdrRange.location)]
                                              encoding:NSUTF8StringEncoding];
    NSString *reqLine = [[headStr componentsSeparatedByString:@"\r\n"] firstObject] ?: @"";

    NSArray *parts = [reqLine componentsSeparatedByString:@" "];
    NSString *method = parts.count > 0 ? parts[0] : @"GET";
    NSString *target = parts.count > 1 ? parts[1] : @"/";

    NSString *path = target, *queryStr = @"";
    NSRange qr = [target rangeOfString:@"?"];
    if (qr.location != NSNotFound) {
        path = [target substringToIndex:qr.location];
        queryStr = [target substringFromIndex:qr.location + 1];
    }
    NSDictionary *query = RDParseQuery(queryStr);

    // 口令校验
    if (strlen(RD_TOKEN) > 0) {
        NSString *k = query[@"k"];
        if (![k isEqualToString:@(RD_TOKEN)]) {
            RDWriteResponse(fd, [RDResp text:@"unauthorized" status:403]);
            close(fd);
            return;
        }
    }

    RDResp *resp = nil;
    @try {
        resp = RDHandle(method, path, query, body);
    } @catch (NSException *e) {
        resp = [RDResp json:@{@"ok": @NO,
                              @"error": [NSString stringWithFormat:@"%@: %@",
                                          e.name, e.reason ?: @""]}];
    }
    if (!resp) resp = [RDResp text:@"500" status:500];
    RDWriteResponse(fd, resp);
    close(fd);
}

#pragma mark - 服务启动

static int gPort = 0;

static int RDCurrentPort(void) { return gPort; }
int RDCurrentPortPub(void) { return gPort; }

static int RDBindPort(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    if (listen(fd, 32) != 0) { close(fd); return -1; }
    return fd;
}

static void RDStartServer(void) {
    if (gPort > 0) return;
    RDStartStderrCapture();

    int fd = -1, port = RD_DEFAULT_PORT;
    for (int i = 0; i < 10; i++) {
        fd = RDBindPort(RD_DEFAULT_PORT + i);
        if (fd >= 0) { port = RD_DEFAULT_PORT + i; break; }
    }
    if (fd < 0) {
        RDLogAppend(@"[RemoteDebug] 所有端口都绑定失败, 服务未启动");
        return;
    }
    gPort = port;

    // 内置工具 + 自定义工具（后者从 tools.json 恢复）
    RDRegisterBuiltinTools();
    RDToolLoadPersisted();

    // 恢复上次落盘的 hook 规则 —— 这一步让改动在重启 app 后依然生效
    RDHookLoadPersisted();
    // 目标类可能是懒加载的，过一会儿再补两次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RDHookLoadPersisted(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(13 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RDHookLoadPersisted(); });

    RDLogAppend([NSString stringWithFormat:
        @"[RemoteDebug] 已启动  http://<本机局域网IP>:%d/   pid=%d", port, getpid()]);

    // 悬浮球等界面稳定后再挂上去
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RDInstallFloatButton();
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (;;) {
            struct sockaddr_in cli;
            socklen_t cl = sizeof(cli);
            int c = accept(fd, (struct sockaddr *)&cli, &cl);
            if (c < 0) {
                if (errno == EINTR) continue;
                usleep(50000);
                continue;
            }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                RDHandleConnection(c);
            });
        }
    });
}

#pragma mark - 崩溃栈记录

static char gCrashLogPath[600] = {0};

static void RDCrashHandler(int sig, siginfo_t *info, void *uap) {
    (void)uap;
    int fd = gCrashLogPath[0] ? open(gCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644) : -1;
    if (fd >= 0) {
        char head[256];
        int len = snprintf(head, sizeof(head),
                           "\n===== CRASH signal=%d addr=%p time=%ld =====\n",
                           sig, info ? info->si_addr : NULL, (long)time(NULL));
        if (len > 0) (void)!write(fd, head, (size_t)len);
        void *frames[64];
        int n = backtrace(frames, 64);
        if (n > 0) backtrace_symbols_fd(frames, n, fd);
        (void)!write(fd, "===== END =====\n", 16);
        close(fd);
    }
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

static void RDInstallCrashHandler(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;

    @try {
        NSString *dir = RDDataDir();
        NSString *logPath = [dir stringByAppendingPathComponent:@"last.log"];
        NSString *crashPath = [dir stringByAppendingPathComponent:@"crash.log"];

        // last.log 超过 1MB 就清掉，防止无限增长
        NSDictionary *attrs = [[NSFileManager defaultManager]
                               attributesOfItemAtPath:logPath error:nil];
        if ([attrs[NSFileSize] unsignedLongLongValue] > 1024ULL * 1024ULL) {
            [[NSData data] writeToFile:logPath atomically:YES];
        }

        const char *cp = [crashPath fileSystemRepresentation];
        if (cp) strncpy(gCrashLogPath, cp, sizeof(gCrashLogPath) - 1);
    } @catch (NSException *e) {
        (void)e;
    }

    int sigs[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGTRAP};
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = RDCrashHandler;
    sa.sa_flags = SA_SIGINFO;
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
    RDLogAppend(@"[RemoteDebug] 崩溃捕获已装");
}

#pragma mark - 注入入口

__attribute__((constructor))
static void RDConstructor(void) {
    @autoreleasepool {
        // 被 dlopen 热加载进来的副本：只加载，不做任何初始化，
        // 否则会和已经在跑的旧版本抢端口、重复接管 stderr
        if (getenv("RD_STAGED")) return;

        // 立刻接管 stderr，越早越好
        RDStartStderrCapture();
        RDInstallCrashHandler();
        RDBootCheck();
        RDLogAppend(@"[RemoteDebug] dylib 已加载");

        // 尽早把 hook 装回去。app 启动阶段就会读 UserDefaults，
        // 等到 1.5 秒后再装就晚了 —— 那时界面早锁定了。
        RDHookLoadPersisted();

        // 等 app 起来再开服务（UIKit / 网络栈就绪）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RDStartServer();
        });
    }
}
