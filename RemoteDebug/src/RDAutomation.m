//
//  RDAutomation.m
//  触摸注入 + 控件定位
//
//  两条路：
//  1. IOHIDEventSystemClientDispatchEvent —— 注入真实触摸事件，等于手指按在屏幕上，
//     对 WebView / 游戏 / 自定义手势都有效。IOKit 私有符号，用 dlopen 拿，
//     拿不到就自动降级，不会影响 dylib 加载。
//  2. UIControl sendActionsForControlEvents —— 不依赖私有 API，精确命中按钮/开关，
//     副作用小，适合点标准控件。
//

#import "RD.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - IOKit 动态加载

typedef void *RDIOHIDEventRef;
typedef void *RDIOHIDClientRef;

static RDIOHIDEventRef (*fnCreateDigitizerEvent)(CFAllocatorRef, uint64_t, uint32_t,
                                                 uint32_t, uint32_t, uint32_t, uint32_t,
                                                 double, double, double, double, double,
                                                 int32_t, int32_t, uint32_t);
static RDIOHIDEventRef (*fnCreateFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                         uint32_t, double, double, double, double, double,
                                         int32_t, int32_t, uint32_t);
static void (*fnAppendEvent)(RDIOHIDEventRef, RDIOHIDEventRef);
static void (*fnDispatchEvent)(RDIOHIDClientRef, RDIOHIDEventRef);
static RDIOHIDClientRef (*fnClientCreate)(CFAllocatorRef);
static void (*fnSetInt)(RDIOHIDEventRef, uint32_t, long long);

static BOOL gHIDReady = NO;
static RDIOHIDClientRef gHIDClient = NULL;
static NSString *gHIDError = @"未尝试";

static void RDLoadHID(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) {
            gHIDError = @"IOKit 打不开";
            return;
        }
        fnCreateDigitizerEvent = (RDIOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t,
            uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
            int32_t, int32_t, uint32_t))dlsym(h, "IOHIDEventCreateDigitizerEvent");
        fnCreateFinger = (RDIOHIDEventRef (*)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
            uint32_t, double, double, double, double, double,
            int32_t, int32_t, uint32_t))dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        fnAppendEvent = (void (*)(RDIOHIDEventRef, RDIOHIDEventRef))
            dlsym(h, "IOHIDEventAppendEvent");
        fnDispatchEvent = (void (*)(RDIOHIDClientRef, RDIOHIDEventRef))
            dlsym(h, "IOHIDEventSystemClientDispatchEvent");
        fnClientCreate = (RDIOHIDClientRef (*)(CFAllocatorRef))
            dlsym(h, "IOHIDEventSystemClientCreate");
        fnSetInt = (void (*)(RDIOHIDEventRef, uint32_t, long long))
            dlsym(h, "IOHIDEventSetIntegerValue");

        if (!fnCreateDigitizerEvent || !fnCreateFinger || !fnAppendEvent ||
            !fnDispatchEvent || !fnClientCreate) {
            gHIDError = @"IOHID 符号缺失（系统版本受限）";
            return;
        }
        gHIDClient = fnClientCreate(kCFAllocatorDefault);
        if (!gHIDClient) {
            gHIDError = @"IOHIDEventSystemClientCreate 返回空";
            return;
        }
        gHIDReady = YES;
        gHIDError = @"可用";
    });
}

BOOL RDIsHIDReady(void) {
    RDLoadHID();
    return gHIDReady;
}

#pragma mark - 触摸注入

// down: 手指按下/抬起。坐标用屏幕点坐标。
static void RDPostHID(CGPoint p, BOOL down) {
    if (!gHIDReady) return;
    uint64_t t = mach_absolute_time();

    // kIOHIDDigitizerTransducerTypeHand = 3
    RDIOHIDEventRef hand = fnCreateDigitizerEvent(
        kCFAllocatorDefault, t, 3, 0, 0, 0, 0,
        0, 0, 0, 0, 0, down ? 1 : 0, down ? 1 : 0, 0);
    if (!hand) return;

    // mask: Position(4) | Range(1) | Touch(2)
    uint32_t mask = down ? 0x07 : 0x03;
    RDIOHIDEventRef finger = fnCreateFinger(
        kCFAllocatorDefault, t, 0, 2, mask,
        p.x, p.y, 0, down ? 1 : 0, 0, down ? 1 : 0, down ? 1 : 0, 0);

    if (finger) {
        fnAppendEvent(hand, finger);
        CFRelease(finger);
    }
    fnDispatchEvent(gHIDClient, hand);
    CFRelease(hand);
}

BOOL RDInjectTouch(CGPoint p, BOOL down) {
    RDLoadHID();
    if (!gHIDReady) return NO;
    RDPostHID(p, down);
    return YES;
}

BOOL RDTapPoint(CGPoint p) {
    RDLoadHID();
    if (!gHIDReady) return NO;
    RDPostHID(p, YES);
    usleep(35000);
    RDPostHID(p, NO);
    usleep(15000);
    return YES;
}

BOOL RDSwipe(CGPoint from, CGPoint to, NSTimeInterval duration) {
    RDLoadHID();
    if (!gHIDReady) return NO;
    if (duration <= 0) duration = 0.25;

    int steps = 12;
    RDPostHID(from, YES);
    for (int i = 1; i <= steps; i++) {
        double r = (double)i / steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * r,
                                from.y + (to.y - from.y) * r);
        RDPostHID(p, YES);
        usleep((useconds_t)(duration * 1000000.0 / steps));
    }
    RDPostHID(to, NO);
    usleep(15000);
    return YES;
}

#pragma mark - 控件定位

CGRect RDScreenRectOfView(UIView *v) {
    if (!v) return CGRectZero;
    UIWindow *w = v.window;
    CGRect r = [v convertRect:v.bounds toView:nil];
    if (w && w != (id)[NSNull null]) {
        r.origin.x += w.frame.origin.x;
        r.origin.y += w.frame.origin.y;
    }
    return r;
}

static void RDWalkViews(UIView *root, BOOL *stop, void (^visit)(UIView *)) {
    if (!root || *stop) return;
    visit(root);
    for (UIView *sub in root.subviews) {
        if (*stop) return;
        RDWalkViews(sub, stop, visit);
    }
}

static NSString *RDViewText(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) return ((UILabel *)v).text;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (!t.length) t = b.currentTitle;
        if (!t.length) t = b.accessibilityLabel;
        return t;
    }
    if ([v isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)v;
        return tf.text.length ? tf.text : tf.placeholder;
    }
    if ([v isKindOfClass:[UITextView class]]) return ((UITextView *)v).text;
    if ([v isKindOfClass:[UISwitch class]]) return @"switch";
    NSString *al = v.accessibilityLabel;
    if (al.length) return al;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img) return [NSString stringWithFormat:@"<img %.0fx%.0f>", img.size.width, img.size.height];
    }
    return nil;
}

UIView *RDFindViewByText(NSString *text, NSInteger index) {
    if (!text.length) return nil;
    if (index < 0) index = 0;
    __block UIView *found = nil;
    RDRunOnMain(^id{
        __block BOOL stop = NO;
        __block NSInteger n = 0;
        RDWalkViews(RDKeyWindow(), &stop, ^(UIView *v) {
            if (found) { stop = YES; return; }
            NSString *t = RDViewText(v);
            if (!t.length) return;
            if ([t rangeOfString:text options:NSCaseInsensitiveSearch].location == NSNotFound) return;
            if (n++ == index) { found = v; stop = YES; }
        });
        return (id)nil;
    });
    return found;
}

UIView *RDFindViewByIdent(NSString *ident, NSInteger index) {
    if (!ident.length) return nil;
    if (index < 0) index = 0;
    __block UIView *found = nil;
    RDRunOnMain(^id{
        __block BOOL stop = NO;
        __block NSInteger n = 0;
        RDWalkViews(RDKeyWindow(), &stop, ^(UIView *v) {
            if (found) { stop = YES; return; }
            NSString *aid = v.accessibilityIdentifier;
            if (aid.length && [aid isEqualToString:ident]) {
                if (n++ == index) { found = v; stop = YES; }
            }
        });
        return (id)nil;
    });
    return found;
}

UIView *RDFindTextField(NSInteger index) {
    if (index < 0) index = 0;
    __block UIView *found = nil;
    RDRunOnMain(^id{
        __block BOOL stop = NO;
        __block NSInteger n = 0;
        RDWalkViews(RDKeyWindow(), &stop, ^(UIView *v) {
            if (found) { stop = YES; return; }
            if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) {
                if (n++ == index) { found = v; stop = YES; }
            }
        });
        return (id)nil;
    });
    return found;
}

BOOL RDTapView(UIView *v) {
    if (!v) return NO;

    __block BOOL ok = NO;
    RDRunOnMain(^id{
        // 1. 往上找最近的可响应控件
        UIView *c = v;
        while (c && ![c isKindOfClass:[UIControl class]]) c = c.superview;

        if ([c isKindOfClass:[UISwitch class]]) {
            UISwitch *sw = (UISwitch *)c;
            [sw setOn:!sw.isOn animated:YES];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];
            ok = YES;
            return (id)nil;
        }

        if (c) {
            UIControl *ctl = (UIControl *)c;
            [ctl sendActionsForControlEvents:UIControlEventTouchDown];
            [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
            [ctl sendActionsForControlEvents:UIControlEventTouchUpOutside];
            ok = YES;
        }

        // 2. 再用真实触摸补一发（手势 / WebView / 自定义视图靠这个）
        if (RDIsHIDReady()) {
            CGRect r = RDScreenRectOfView(v);
            CGPoint center = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
            RDTapPoint(center);
            ok = YES;
        }
        return (id)nil;
    });
    return ok;
}




#pragma mark - dump 所有窗口（诊断广告遮罩用）

static void RDRecDump(UIView *v, NSMutableString *out, int depth) {
    if (!v || depth > 24) return;
    UIColor *bg = v.backgroundColor;
    CGFloat white = -1, alpha = -1;
    NSString *bgDesc = @"-";
    if (bg && [bg getWhite:&white alpha:&alpha]) {
        bgDesc = [NSString stringWithFormat:@"w=%.2f a=%.2f", white, alpha];
    }
    NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2)
                                      withString:@" " startingAtIndex:0];
    [out appendFormat:@"%@%@ <%p> f=(%.0f,%.0f,%.0f,%.0f) hid=%d a=%.2f bg=%@\n",
        pad, NSStringFromClass([v class]), (__bridge void *)v,
        v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
        v.hidden, v.alpha, bgDesc];
    for (UIView *sub in v.subviews) {
        RDRecDump(sub, out, depth + 1);
    }
}

NSString *RDDumpAllWindows(void) {
    __block NSMutableString *out = [NSMutableString string];
    RDRunOnMain(^id{
        NSArray *ws = [UIApplication sharedApplication].windows;
        for (UIWindow *w in ws) {
            [out appendFormat:@"\n== window <%p> level=%.0f hid=%d key=%d ==\n",
                (__bridge void *)w, w.windowLevel, w.hidden, w.isKeyWindow];
            RDRecDump(w, out, 1);
        }
        return (id)nil;
    });
    return out;
}

#pragma mark - Accessibility 兜底（SwiftUI 专用）

// SwiftUI 的卡片既不是 UIControl 也没有独立 UIView，
// 但它会生成 accessibility 元素。这条路不依赖 IOHID，也不碰系统类。

static void RDCollectAX(id obj, int depth, NSMutableArray *out) {
    if (!obj || depth > 40 || out.count >= 300) return;

    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger n = (NSInteger)[obj accessibilityElementCount];
        for (NSInteger i = 0; i < n && out.count < 300; i++) {
            id el = nil;
            @try {
                el = [obj accessibilityElementAtIndex:i];
            } @catch (NSException *e) {
                el = nil;
            }
            if (!el) continue;

            NSString *label = nil;
            CGRect frame = CGRectZero;
            uintptr_t ptr = (uintptr_t)(__bridge void *)el;
            @try {
                if ([el respondsToSelector:@selector(accessibilityLabel)])
                    label = [el accessibilityLabel];
                if ([el respondsToSelector:@selector(accessibilityFrame)])
                    frame = [el accessibilityFrame];
            } @catch (NSException *e) {
                (void)e;
            }

            if (label.length || !CGRectIsEmpty(frame)) {
                [out addObject:@{
                    @"label": label ?: @"",
                    @"frame": NSStringFromCGRect(frame),
                    @"ptr": [NSString stringWithFormat:@"0x%lx", (unsigned long)ptr],
                    @"traits": @([el respondsToSelector:@selector(accessibilityTraits)]
                                 ? (long long)[el accessibilityTraits] : 0)
                }];
            }
            RDCollectAX(el, depth + 1, out);
        }
    }

    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in ((UIView *)obj).subviews) {
            RDCollectAX(sub, depth + 1, out);
        }
    }
}

NSArray *RDAXElements(void) {
    NSMutableArray *out = [NSMutableArray array];
    RDRunOnMain(^id{
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;
        // 有些 SwiftUI 视图要触发一次屏幕变化通知才会把 accessibility 树建出来
        @try {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
        } @catch (NSException *e) { (void)e; }
        RDCollectAX(w, 0, out);
        return (id)nil;
    });
    return out;
}

// 按 label 包含匹配，index 选第几个，直接 accessibilityActivate
BOOL RDAXTapLabel(NSString *label, NSInteger index) {
    if (!label.length) return NO;
    __block BOOL ok = NO;
    RDRunOnMain(^id{
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;

        @try {
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);
        } @catch (NSException *e) { (void)e; }

        NSMutableArray *hits = [NSMutableArray array];
        NSMutableArray *all = [NSMutableArray array];
        RDCollectAX(w, 0, all);
        for (NSDictionary *d in all) {
            NSString *l = d[@"label"];
            if (l.length && [l rangeOfString:label
                                     options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:d];
            }
        }
        if (hits.count == 0) return (id)nil;
        NSInteger i = MAX(0, MIN(index, (NSInteger)hits.count - 1));
        NSDictionary *d = hits[(NSUInteger)i];

        void *raw = NULL;
        sscanf([d[@"ptr"] UTF8String], "%p", &raw);
        id el = (__bridge id)raw;
        if (!el || ![el respondsToSelector:@selector(accessibilityActivate)]) return (id)nil;

        @try {
            ok = [el accessibilityActivate];
        } @catch (NSException *e) {
            (void)e;
            ok = NO;
        }
        RDLogAppend([NSString stringWithFormat:@"[AX] activate \"%@\" -> %d", d[@"label"], ok]);
        return (id)nil;
    });
    return ok;
}

#pragma mark - 诊断 / 可调参数注入

NSDictionary *RDhidDiagnose(void) {
    RDLoadHID();
    return @{
        @"ready":      @(gHIDReady),
        @"error":      gHIDError ?: @"",
        @"client":     @(gHIDClient != NULL),
        @"fn_event":   @(fnCreateDigitizerEvent != NULL),
        @"fn_finger":  @(fnCreateFinger != NULL),
        @"fn_append":  @(fnAppendEvent != NULL),
        @"fn_dispatch": @(fnDispatchEvent != NULL),
        @"fn_client":  @(fnClientCreate != NULL),
        @"fn_setint":  @(fnSetInt != NULL),
    };
}

// scale: 坐标放大倍数（1 = 点，3 = 像素，iPhone 14 Pro 是 3x）
// integrated: 是否设置 IsDisplayIntegrated 字段
BOOL RDTapPointScaled(CGPoint p, double scale, BOOL integrated) {
    RDLoadHID();
    if (!gHIDReady) return NO;
    if (scale <= 0) scale = 1.0;

    CGPoint q = CGPointMake(p.x * scale, p.y * scale);
    uint64_t t = mach_absolute_time();

    RDIOHIDEventRef hand = fnCreateDigitizerEvent(
        kCFAllocatorDefault, t, 3, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 1, 1, 0);
    if (!hand) return NO;

    RDIOHIDEventRef finger = fnCreateFinger(
        kCFAllocatorDefault, t, 0, 2, 0x07,
        q.x, q.y, 0, 1, 0, 1, 1, 0);
    if (finger) {
        fnAppendEvent(hand, finger);
        CFRelease(finger);
    }

    if (integrated && fnSetInt) {
        // kIOHIDEventFieldDigitizerIsDisplayIntegrated ≈ 0x000B0019
        fnSetInt(hand, 0x000B0019, 1);
    }

    fnDispatchEvent(gHIDClient, hand);
    CFRelease(hand);
    usleep(40000);

    // 抬手
    uint64_t t2 = mach_absolute_time();
    RDIOHIDEventRef hand2 = fnCreateDigitizerEvent(
        kCFAllocatorDefault, t2, 3, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0);
    if (hand2) {
        RDIOHIDEventRef f2 = fnCreateFinger(
            kCFAllocatorDefault, t2, 0, 2, 0x03,
            q.x, q.y, 0, 0, 0, 0, 0, 0);
        if (f2) { fnAppendEvent(hand2, f2); CFRelease(f2); }
        if (integrated && fnSetInt) {
            fnSetInt(hand2, 0x000B0019, 1);
        }
        fnDispatchEvent(gHIDClient, hand2);
        CFRelease(hand2);
    }
    usleep(20000);
    return YES;
}

#pragma mark - 精简可交互元素表

NSArray *RDInteractiveTree(void) {
    NSMutableArray *out = [NSMutableArray array];
    RDRunOnMain(^id{
        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;

        __block BOOL stop = NO;
        __block NSInteger idx = 0;
        RDWalkViews(w, &stop, ^(UIView *v) {
            if (out.count >= 200) { stop = YES; return; }
            if (v.isHidden || v.alpha < 0.05) return;
            if (CGRectIsEmpty(v.bounds)) return;

            BOOL interactive = [v isKindOfClass:[UIControl class]]
                || v.gestureRecognizers.count > 0
                || (v.isUserInteractionEnabled && v.isAccessibilityElement);
            NSString *text = RDViewText(v);

            // 非交互但带文字的也留着，方便按文字定位
            if (!interactive && !text.length) return;

            // 纯容器跳过
            if (!interactive && [v isKindOfClass:[UIView class]] && v.subviews.count > 0) return;

            CGRect r = RDScreenRectOfView(v);
            NSMutableDictionary *d = [@{
                @"i": @(idx++),
                @"cls": NSStringFromClass([v class]) ?: @"",
                @"tap": @(interactive),
                @"cx": @(round(CGRectGetMidX(r))),
                @"cy": @(round(CGRectGetMidY(r))),
                @"w": @(round(r.size.width)),
                @"h": @(round(r.size.height))
            } mutableCopy];
            if (text.length) {
                d[@"text"] = text.length > 60 ? [text substringToIndex:60] : text;
            }
            NSString *aid = v.accessibilityIdentifier;
            if (aid.length) d[@"id"] = aid;
            [out addObject:d];
        });
        return (id)nil;
    });
    return out;
}
