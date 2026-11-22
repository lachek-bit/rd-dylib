//
//  RDFloat.m
//  悬浮球：点一下把调试地址复制到剪贴板，方便直接连
//  长按 3 秒隐藏（免得挡视线）
//
//  重要：必须挂在 app 自己的 keyWindow 上，不能用独立 UIWindow。
//  iOS 在 window 之间不做 hitTest 穿透 —— 透明的全屏 window 会把所有触摸吃掉，
//  表现就是「界面还在但点不动」。
//

#import "RD.h"
#import "RDIcon.h"
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <math.h>

#pragma mark - 取本机 WiFi IP

NSString *RDLocalIP(void) {
    NSString *addr = nil;
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return nil;

    const char *prefer[] = {"en0", "en1"};
    for (size_t k = 0; k < sizeof(prefer) / sizeof(prefer[0]) && !addr; k++) {
        for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
            const char *nm = p->ifa_name;
            if (!nm || strcmp(nm, prefer[k]) != 0) continue;
            char buf[INET_ADDRSTRLEN] = {0};
            struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
            if (inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) {
                NSString *s = @(buf);
                if (s.length && ![s hasPrefix:@"127."]) { addr = s; break; }
            }
        }
    }
    freeifaddrs(ifa);
    return addr;
}

#pragma mark - 空白处穿透的容器

@interface RDPassthroughView : UIView
@end

@implementation RDPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    // 没点中任何子视图就返回 nil —— 同一个 window 内 UIKit 会继续问下面的兄弟视图，
    // 所以 app 的界面照常响应
    return (v == self) ? nil : v;
}
@end

#pragma mark - 状态

static UIView    *gFloatHost = nil;
static UIView    *gFloatBtn = nil;
static UILabel   *gToast = nil;
static NSTimer   *gToastTimer = nil;
static NSTimer   *gKeepTopTimer = nil;

static NSString *const kRDFloatX = @"rd.float.x";
static NSString *const kRDFloatY = @"rd.float.y";
static NSString *const kRDFloatOff = @"rd.float.off";

// 保证浮层还在 keyWindow 最上层（app 换页/加视图时可能被盖住）
static void RDAttachFloatHost(void) {
    if (!gFloatHost) return;
    UIWindow *w = RDKeyWindow();
    if (!w) return;

    if (gFloatHost.superview != w) {
        [gFloatHost removeFromSuperview];
        gFloatHost.frame = w.bounds;
        [w addSubview:gFloatHost];
    } else if (w.subviews.lastObject != gFloatHost) {
        [w bringSubviewToFront:gFloatHost];
    }
}

static void RDShowToast(NSString *text) {
    if (!gFloatHost || !gToast) return;
    RDAttachFloatHost();

    gToast.text = text;
    CGFloat maxW = gFloatHost.bounds.size.width - 64;
    CGSize sz = [gToast sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
    CGFloat w = MIN(sz.width + 28, maxW);
    CGFloat h = sz.height + 22;
    gToast.frame = CGRectMake((gFloatHost.bounds.size.width - w) / 2.0,
                              gFloatHost.bounds.size.height * 0.40,
                              w, h);
    [gFloatHost bringSubviewToFront:gToast];

    [UIView animateWithDuration:0.15 animations:^{ gToast.alpha = 1.0; }];
    [gToastTimer invalidate];
    gToastTimer = [NSTimer scheduledTimerWithTimeInterval:2.8
                                                  repeats:NO
                                                    block:^(NSTimer *t) {
        [UIView animateWithDuration:0.4 animations:^{
            gToast.alpha = 0.0;
        }];
    }];
}

static void RDFloatTap(void) {
    NSString *ip = RDLocalIP();
    int port = RDCurrentPortPub();
    if (ip.length) {
        NSString *url = [NSString stringWithFormat:@"http://%@:%d", ip, port];
        [UIPasteboard generalPasteboard].string = url;
        RDShowToast([NSString stringWithFormat:@"已复制\n%@", url]);
        RDLogAppend([NSString stringWithFormat:@"[FLOAT] 已复制 %@", url]);
    } else {
        RDShowToast([NSString stringWithFormat:@"未取到 WiFi IP\n端口 %d", port]);
        RDLogAppend(@"[FLOAT] 未取到 WiFi IP");
    }
}

static void RDFloatLongPress(void) {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kRDFloatOff];
    [gKeepTopTimer invalidate];
    [UIView animateWithDuration:0.2 animations:^{
        gFloatHost.alpha = 0.0;
    } completion:^(BOOL f) {
        [gFloatHost removeFromSuperview];
        gFloatHost = nil;
        gFloatBtn = nil;
    }];
    RDLogAppend(@"[FLOAT] 已隐藏（重开 app 恢复）");
}

#pragma mark - 手势

@interface RDFloatController : NSObject
@end

@implementation RDFloatController {
    CGPoint _panStart;
}

+ (instancetype)shared {
    static RDFloatController *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RDFloatController new]; });
    return s;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *btn = g.view;
    UIView *host = btn.superview;
    if (!btn || !host) return;

    if (g.state == UIGestureRecognizerStateBegan) _panStart = btn.center;

    CGPoint t = [g translationInView:host];
    btn.center = CGPointMake(_panStart.x + t.x, _panStart.y + t.y);

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {

        CGFloat half = btn.bounds.size.width / 2.0;
        CGFloat sx = MIN(MAX(btn.center.x, half + 6), host.bounds.size.width - half - 6);
        CGFloat sy = MIN(MAX(btn.center.y, half + 50), host.bounds.size.height - half - 40);

        [UIView animateWithDuration:0.12 animations:^{
            btn.center = CGPointMake(sx, sy);
        }];

        [[NSUserDefaults standardUserDefaults] setDouble:sx forKey:kRDFloatX];
        [[NSUserDefaults standardUserDefaults] setDouble:sy forKey:kRDFloatY];

        if (fabs(t.x) < 9 && fabs(t.y) < 9) RDFloatTap();
    }
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) RDFloatLongPress();
}

@end

#pragma mark - 安装

void RDInstallFloatButton(void) {
    RDRunOnMain(^id{
        if (gFloatHost) { RDAttachFloatHost(); return (id)nil; }
        if ([[NSUserDefaults standardUserDefaults] boolForKey:kRDFloatOff]) {
            RDLogAppend(@"[FLOAT] 之前被长按隐藏，本次不显示");
            return (id)nil;
        }

        UIWindow *w = RDKeyWindow();
        if (!w) return (id)nil;

        CGRect bounds = w.bounds;

        RDPassthroughView *host = [[RDPassthroughView alloc] initWithFrame:bounds];
        host.backgroundColor = [UIColor clearColor];
        host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // ---- 球
        CGFloat side = 58;
        CGFloat x = [[NSUserDefaults standardUserDefaults] doubleForKey:kRDFloatX];
        CGFloat y = [[NSUserDefaults standardUserDefaults] doubleForKey:kRDFloatY];
        if (x <= 0 || y <= 0) {
            x = bounds.size.width - side / 2 - 14;
            y = bounds.size.height * 0.42;
        }

        UIView *btn = [[UIView alloc] initWithFrame:
                       CGRectMake(x - side / 2, y - side / 2, side, side)];
        btn.layer.cornerRadius = side / 2;
        btn.layer.shadowColor = [UIColor blackColor].CGColor;
        btn.layer.shadowOpacity = 0.28;
        btn.layer.shadowRadius = 8;
        btn.layer.shadowOffset = CGSizeMake(0, 3);
        btn.userInteractionEnabled = YES;

        NSData *png = [[NSData alloc] initWithBase64EncodedString:@(kRDFloatIconPNGBase64)
                                                          options:0];
        UIImage *icon = png ? [UIImage imageWithData:png] : nil;
        if (icon) {
            UIImageView *iv = [[UIImageView alloc] initWithFrame:btn.bounds];
            iv.image = icon;
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.layer.cornerRadius = side / 2;
            iv.clipsToBounds = YES;
            iv.userInteractionEnabled = NO;
            [btn addSubview:iv];
        } else {
            btn.backgroundColor = [UIColor colorWithRed:0.55 green:0.47 blue:0.85 alpha:1.0];
            UILabel *l = [[UILabel alloc] initWithFrame:btn.bounds];
            l.text = @"RD";
            l.textColor = [UIColor whiteColor];
            l.font = [UIFont boldSystemFontOfSize:18];
            l.textAlignment = NSTextAlignmentCenter;
            l.userInteractionEnabled = NO;
            [btn addSubview:l];
        }

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:[RDFloatController shared]
                                                    action:@selector(onPan:)];
        [btn addGestureRecognizer:pan];

        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:[RDFloatController shared]
                                                          action:@selector(onLongPress:)];
        lp.minimumPressDuration = 3.0;
        [btn addGestureRecognizer:lp];

        [host addSubview:btn];

        // ---- toast
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
        t.numberOfLines = 0;
        t.textAlignment = NSTextAlignmentCenter;
        t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        t.textColor = [UIColor whiteColor];
        t.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.86];
        t.layer.cornerRadius = 11;
        t.clipsToBounds = YES;
        t.alpha = 0.0;
        t.userInteractionEnabled = NO;
        [host addSubview:t];

        [w addSubview:host];

        gFloatHost = host;
        gFloatBtn = btn;
        gToast = t;

        // 定期确保还在最上层（app 内部可能频繁重建视图）
        gKeepTopTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                        repeats:YES
                                                          block:^(NSTimer *tm) {
            if (!gFloatHost) { [tm invalidate]; return; }
            RDAttachFloatHost();
        }];

        RDLogAppend([NSString stringWithFormat:@"[FLOAT] 悬浮球已挂到 keyWindow  ip=%@",
                     RDLocalIP() ?: @"?"]);
        return (id)nil;
    });
}
